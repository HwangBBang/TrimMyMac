import Foundation
import Darwin

/// Agentic-AI CLI we recognise in the process table.
public enum AgentKind: String, Sendable, CaseIterable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

/// One detected agent session = a root agent process plus its descendant tree
/// (cut where another agent root begins). CPU is percent of a single core
/// (Activity Monitor style; can exceed 100); memory is summed resident bytes.
public struct AgentSession: Sendable, Identifiable {
    public let id: Int32          // root pid
    public let kind: AgentKind
    public let pid: Int32
    public let cpu: Int
    public let memory: UInt64

    public init(id: Int32, kind: AgentKind, pid: Int32, cpu: Int, memory: UInt64) {
        self.id = id
        self.kind = kind
        self.pid = pid
        self.cpu = cpu
        self.memory = memory
    }
}

/// Samples per-session CPU/RAM for agentic AI CLIs (Claude Code, Codex). CPU is
/// delta-based, so this monitor is stateful and MUST be driven by a single sampler.
@MainActor
public final class AgentSessionMonitor: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []

    private var prevCPU: [Int32: UInt64] = [:]   // pid -> cumulative cpu ns at last sample
    private var prevTime: TimeInterval?

    public init() {}

    // MARK: - Pure, testable helpers

    struct ProcRecord: Equatable {
        let pid: Int32
        let ppid: Int32
        let kind: AgentKind?
        let cpu: Double
        let rss: UInt64
    }

    /// Classifies a process as an agent CLI from its short name (`comm`) and full
    /// argv. Handles native binaries (`claude`, `codex`) and interpreter launches
    /// (`node …/claude-code/cli.js`). Returns nil for anything else.
    nonisolated static func classify(comm: String, argv: [String]) -> AgentKind? {
        let lcComm = comm.lowercased()
        func tokenMatches(_ needle: String) -> Bool {
            if lcComm == needle || lcComm.hasPrefix(needle) { return true }
            for arg in argv {
                let base = (arg as NSString).lastPathComponent.lowercased()
                if base == needle || base.hasPrefix(needle) { return true }
            }
            return false
        }
        let hay = ([comm] + argv).joined(separator: " ").lowercased()

        // Codex first (a codex process never looks like claude).
        if tokenMatches("codex") { return .codex }
        if tokenMatches("claude") { return .claudeCode }
        if hay.contains("claude-code") || hay.contains("/claude/") || hay.contains("claude/cli") {
            return .claudeCode
        }
        return nil
    }

    /// CPU as percent of a SINGLE core (Activity Monitor style): a busy multi-threaded
    /// session can exceed 100. Dividing by core count instead makes per-session usage
    /// round to ~0 (one session rarely uses a big fraction of ALL cores), which reads
    /// as "not tracking". Returns 0 if no time elapsed (first sample).
    nonisolated static func cpuPercentOfCore(deltaCpuNs: Double, elapsedNs: Double) -> Double {
        guard elapsedNs > 0 else { return 0 }
        return max(0, deltaCpuNs / elapsedNs * 100)
    }

    /// Sums each agent root's process subtree (cpu + rss), cutting the traversal
    /// where a nested agent root begins so its resources aren't double-counted.
    nonisolated static func aggregate(_ records: [ProcRecord]) -> [AgentSession] {
        var byPid: [Int32: ProcRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        for r in records {
            byPid[r.pid] = r
            children[r.ppid, default: []].append(r.pid)
        }
        let rootSet = Set(records.compactMap { $0.kind == nil ? nil : $0.pid })

        var sessions: [AgentSession] = []
        for root in rootSet {
            guard let rootRec = byPid[root], let kind = rootRec.kind else { continue }
            var cpu = 0.0
            var memory: UInt64 = 0
            var stack = [root]
            var seen = Set<Int32>()
            while let pid = stack.popLast() {
                guard !seen.contains(pid), let rec = byPid[pid] else { continue }
                seen.insert(pid)
                cpu += rec.cpu
                memory &+= rec.rss
                for child in children[pid] ?? [] where !rootSet.contains(child) {
                    stack.append(child)
                }
            }
            sessions.append(AgentSession(id: root, kind: kind, pid: root,
                                         cpu: Int(cpu.rounded()), memory: memory))
        }
        // CPU desc, then memory desc (idle sessions read 0% CPU → memory is the
        // useful secondary key), then pid for a stable order.
        return sessions.sorted {
            if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
            if $0.memory != $1.memory { return $0.memory > $1.memory }
            return $0.pid < $1.pid
        }
    }

    // MARK: - Live process enumeration (nonisolated; no shared state)

    nonisolated static func enumerateUserProcesses() -> [(pid: Int32, ppid: Int32, comm: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 1)
        var got = buffer.count * stride
        let rc = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, 4, raw.baseAddress, &got, nil, 0)
        }
        guard rc == 0 else { return [] }
        let count = got / stride
        let myUid = getuid()
        var out: [(Int32, Int32, String)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var proc = buffer[i]
            guard proc.kp_eproc.e_ucred.cr_uid == myUid else { continue }
            let pid = proc.kp_proc.p_pid
            let ppid = proc.kp_eproc.e_ppid
            let comm = withUnsafeBytes(of: &proc.kp_proc.p_comm) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            out.append((pid, ppid, comm))
        }
        return out
    }

    /// Full argv for a pid via KERN_PROCARGS2. Empty on failure (same-uid processes only).
    nonisolated static func processArgs(_ pid: Int32) -> [String] {
        var argmax: Int32 = 262144
        var mibMax: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var maxSize = MemoryLayout<Int32>.size
        _ = sysctl(&mibMax, 2, &argmax, &maxSize, nil, 0)
        if argmax <= 0 { argmax = 262144 }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argmax)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyBytes(from: src.prefix(MemoryLayout<Int32>.size))
            }
        }

        return buffer.withUnsafeBufferPointer { ptr -> [String] in
            guard let base = ptr.baseAddress else { return [] }
            let end = base + size
            var p = base + MemoryLayout<Int32>.size

            // Skip the executable path string.
            while p < end && p.pointee != 0 { p += 1 }
            // Skip the NUL padding between exec path and argv[0].
            while p < end && p.pointee == 0 { p += 1 }

            var args: [String] = []
            var n: Int32 = 0
            while n < argc && p < end {
                let start = p
                while p < end && p.pointee != 0 { p += 1 }
                guard p < end else { break }   // unterminated tail → stop
                args.append(String(cString: start))
                p += 1
                n += 1
            }
            return args
        }
    }

    /// Cumulative CPU time (ns) and resident size (bytes) for a pid, or nil if gone.
    nonisolated static func taskInfo(_ pid: Int32) -> (cpuNs: UInt64, rss: UInt64)? {
        var info = proc_taskinfo()
        let expected = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, expected)
        guard rc == expected else { return nil }
        return (info.pti_total_user + info.pti_total_system, info.pti_resident_size)
    }

    // MARK: - Live sampling

    /// Samples agent sessions. First call establishes a CPU baseline (0% CPU,
    /// correct memory); later calls report CPU since the previous call.
    public func sample(enabled: Set<AgentKind> = Set(AgentKind.allCases)) {
        let now = Date().timeIntervalSinceReferenceDate
        let elapsedNs = prevTime.map { (now - $0) * 1_000_000_000 } ?? 0

        let procs = Self.enumerateUserProcesses()
        var ppidByPid: [Int32: Int32] = [:]
        var children: [Int32: [Int32]] = [:]
        for pr in procs {
            ppidByPid[pr.pid] = pr.ppid
            children[pr.ppid, default: []].append(pr.pid)
        }

        // Detect agent roots. Fetch argv only for plausible candidates to stay cheap.
        var kindByPid: [Int32: AgentKind] = [:]
        for pr in procs {
            let lc = pr.comm.lowercased()
            let isNamed = lc == "claude" || lc == "codex"
            let isInterpreter = lc == "node" || lc == "deno" || lc == "bun"
                || lc.contains("claude") || lc.contains("codex")
            guard isNamed || isInterpreter else { continue }
            let argv = isNamed ? [] : Self.processArgs(pr.pid)
            if let kind = Self.classify(comm: pr.comm, argv: argv), enabled.contains(kind) {
                kindByPid[pr.pid] = kind
            }
        }

        let rootSet = Set(kindByPid.keys)
        guard !rootSet.isEmpty else {
            sessions = []
            prevCPU.removeAll()
            prevTime = now
            return
        }

        // Member pids = every root's subtree, cut where another root begins.
        var members = Set<Int32>()
        for root in rootSet {
            var stack = [root]
            while let pid = stack.popLast() {
                guard !members.contains(pid) else { continue }
                members.insert(pid)
                for child in children[pid] ?? [] where !rootSet.contains(child) {
                    stack.append(child)
                }
            }
        }

        var records: [ProcRecord] = []
        var newPrev: [Int32: UInt64] = [:]
        for pid in members {
            guard let info = Self.taskInfo(pid) else { continue }
            newPrev[pid] = info.cpuNs
            let deltaNs: Double
            if let prev = prevCPU[pid], info.cpuNs >= prev {
                deltaNs = Double(info.cpuNs - prev)
            } else {
                deltaNs = 0   // first sighting or counter reset → no CPU this round
            }
            let cpu = Self.cpuPercentOfCore(deltaCpuNs: deltaNs, elapsedNs: elapsedNs)
            records.append(ProcRecord(pid: pid, ppid: ppidByPid[pid] ?? 0,
                                      kind: kindByPid[pid], cpu: cpu, rss: info.rss))
        }

        sessions = Self.aggregate(records)
        prevCPU = newPrev
        prevTime = now
    }
}
