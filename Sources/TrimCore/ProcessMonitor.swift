import Foundation
import AppKit
import Darwin

public enum ProcessKind: Sendable, Equatable { case app, agent, process }

public struct ProcessUsage: Identifiable, Sendable, Equatable {
    public let id: String        // "bundle:<bundleID>" for apps, "pid:<n>" for agents/processes
    public let displayName: String
    public let bundleID: String?
    public let kind: ProcessKind
    public let footprint: UInt64 // phys_footprint bytes (NOT summed resident_size)
    public let cpu: Int
    public init(id: String, displayName: String, bundleID: String?,
                kind: ProcessKind, footprint: UInt64, cpu: Int) {
        self.id = id; self.displayName = displayName; self.bundleID = bundleID
        self.kind = kind; self.footprint = footprint; self.cpu = cpu
    }
}

extension ProcessMonitor {
    public struct RawProc: Sendable {
        public let pid: Int32
        public let name: String
        public let bundleID: String?
        public let kind: ProcessKind
        public let footprint: UInt64
        public init(pid: Int32, name: String, bundleID: String?, kind: ProcessKind, footprint: UInt64) {
            self.pid = pid; self.name = name; self.bundleID = bundleID; self.kind = kind; self.footprint = footprint
        }
    }

    /// Apps fold together by bundleID (sum helper footprints); agents and bare
    /// processes stay individual (keyed by pid).
    nonisolated public static func aggregate(_ procs: [RawProc]) -> [ProcessUsage] {
        var byKey: [String: ProcessUsage] = [:]
        var order: [String] = []
        for p in procs {
            let key: String
            if p.kind == .app, let bundle = p.bundleID { key = "bundle:\(bundle)" }
            else { key = "pid:\(p.pid)" }
            if let existing = byKey[key] {
                byKey[key] = ProcessUsage(id: existing.id, displayName: existing.displayName,
                                          bundleID: existing.bundleID, kind: existing.kind,
                                          footprint: existing.footprint + p.footprint, cpu: existing.cpu)
            } else {
                let id = p.bundleID.map { "bundle:\($0)" } ?? "pid:\(p.pid)"
                byKey[key] = ProcessUsage(id: id, displayName: p.name, bundleID: p.bundleID,
                                          kind: p.kind, footprint: p.footprint, cpu: 0)
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    nonisolated public static func topN(_ usages: [ProcessUsage], limit: Int) -> [ProcessUsage] {
        Array(usages.sorted {
            $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.displayName < $1.displayName
        }.prefix(limit))
    }

    nonisolated public static func isNoiseDaemon(_ comm: String) -> Bool {
        let known: Set<String> = [
            "cfprefsd", "distnoted", "pboard", "UserEventAgent", "launchd",
            "logd", "mds", "mds_stores", "mdworker", "trustd", "secd", "nsurlsessiond",
        ]
        return known.contains(comm)
    }
}

@MainActor
public final class ProcessMonitor: ObservableObject {
    @Published public private(set) var top: [ProcessUsage] = []
    @Published public private(set) var agentSessions: [ProcessUsage] = []
    public init() {}
}

extension ProcessMonitor {
    /// Minimal record used by `aggregateAgentTrees` — mirrors `AgentSessionMonitor.ProcRecord`
    /// but carries `footprint` instead of CPU/RSS so the helper stays view-only.
    struct AgentRecord: Sendable {
        let pid: Int32
        let ppid: Int32
        let kind: AgentKind?  // non-nil marks an agent root
        let footprint: UInt64
    }

    /// Aggregates agent process subtrees into one `ProcessUsage` per root, summing
    /// `footprint` over the subtree and cutting the traversal where a nested agent root
    /// begins (its resources will appear under its own entry instead).
    /// Returns sessions sorted by footprint descending.
    nonisolated static func aggregateAgentTrees(_ records: [AgentRecord]) -> [ProcessUsage] {
        var byPid: [Int32: AgentRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        for r in records {
            byPid[r.pid] = r
            children[r.ppid, default: []].append(r.pid)
        }
        let rootSet = Set(records.compactMap { $0.kind == nil ? nil : $0.pid })

        var sessions: [ProcessUsage] = []
        for root in rootSet {
            guard let rootRec = byPid[root], let kind = rootRec.kind else { continue }
            var footprint: UInt64 = 0
            var stack = [root]
            var seen = Set<Int32>()
            while let pid = stack.popLast() {
                guard !seen.contains(pid), let rec = byPid[pid] else { continue }
                seen.insert(pid)
                footprint &+= rec.footprint
                for child in children[pid] ?? [] where !rootSet.contains(child) {
                    stack.append(child)
                }
            }
            sessions.append(ProcessUsage(id: "pid:\(root)", displayName: kind.displayName,
                                         bundleID: nil, kind: .agent,
                                         footprint: footprint, cpu: 0))
        }
        return sessions.sorted { $0.footprint > $1.footprint }
    }
}

extension ProcessMonitor {
    /// phys_footprint (matches Activity Monitor's Memory column) for a same-uid pid.
    nonisolated public static func physFootprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reb in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, reb)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// Single enumeration pass. Builds top consumers (apps + agents + notable bare
    /// processes) by phys_footprint, plus an agent-only projection. Agent sessions are
    /// aggregated as one row per root process (subtree footprint summed, cut at nested
    /// agent roots). Heavy work is done synchronously here; the 1 s sampler gates
    /// frequency via `sampleTick % 3`.
    public func sample(limit: Int = 8, agentsEnabled: Bool = true) {
        let procs = AgentSessionMonitor.enumerateUserProcesses()   // same-uid only
        let pidToApp = Self.appsByPid()                            // pid -> (name, bundleID)
        let floor: UInt64 = 200 * 1024 * 1024                     // 200 MB bare-process floor

        // Build parent-child maps needed for agent subtree walk.
        var ppidByPid: [Int32: Int32] = [:]
        var childrenByPid: [Int32: [Int32]] = [:]
        for pr in procs {
            ppidByPid[pr.pid] = pr.ppid
            childrenByPid[pr.ppid, default: []].append(pr.pid)
        }

        // Detect agent roots (same candidate filter as before — stays cheap).
        var kindByPid: [Int32: AgentKind] = [:]
        if agentsEnabled {
            for pr in procs {
                let lc = pr.comm.lowercased()
                let candidate = lc == "claude" || lc == "codex" || lc == "node" || lc == "deno" || lc == "bun"
                    || lc.contains("claude") || lc.contains("codex")
                guard candidate else { continue }
                let isNamed = lc == "claude" || lc == "codex"
                let argv = isNamed ? [] : AgentSessionMonitor.processArgs(pr.pid)
                if let kind = AgentSessionMonitor.classify(comm: pr.comm, argv: argv) {
                    kindByPid[pr.pid] = kind
                }
            }
        }

        let rootSet = Set(kindByPid.keys)

        // Collect all pids belonging to any agent subtree (cut at nested roots).
        var agentMembers = Set<Int32>()
        for root in rootSet {
            var stack = [root]
            while let pid = stack.popLast() {
                guard !agentMembers.contains(pid) else { continue }
                agentMembers.insert(pid)
                for child in childrenByPid[pid] ?? [] where !rootSet.contains(child) {
                    stack.append(child)
                }
            }
        }

        // Build AgentRecord list and aggregate into one ProcessUsage per session root.
        var agentRecords: [AgentRecord] = []
        for pid in agentMembers {
            guard let fp = Self.physFootprint(pid) else { continue }
            agentRecords.append(AgentRecord(pid: pid, ppid: ppidByPid[pid] ?? 0,
                                            kind: kindByPid[pid], footprint: fp))
        }
        let aggregatedAgents = Self.aggregateAgentTrees(agentRecords)

        // Build top list: one row per aggregated agent session + apps + bare processes.
        // Agent subtree members are excluded from the app/process pass to avoid double-counting.
        var raws: [RawProc] = []
        for session in aggregatedAgents {
            // id format is "pid:<n>"; parse the root pid for the RawProc entry.
            let rootPid = Int32(String(session.id.dropFirst(4))) ?? 0
            raws.append(RawProc(pid: rootPid, name: session.displayName, bundleID: nil,
                                kind: .agent, footprint: session.footprint))
        }
        for pr in procs {
            guard !agentMembers.contains(pr.pid) else { continue }   // already counted above
            guard let fp = Self.physFootprint(pr.pid) else { continue }
            if let app = pidToApp[pr.pid] {
                raws.append(RawProc(pid: pr.pid, name: app.name, bundleID: app.bundleID,
                                    kind: .app, footprint: fp))
                continue
            }
            if fp >= floor, !Self.isNoiseDaemon(pr.comm) {
                raws.append(RawProc(pid: pr.pid, name: pr.comm, bundleID: nil,
                                    kind: .process, footprint: fp))
            }
        }

        top = Self.topN(Self.aggregate(raws), limit: limit)
        agentSessions = aggregatedAgents
    }

    /// Maps each GUI app's pid to its display name + bundleID (regular apps only).
    nonisolated static func appsByPid() -> [Int32: (name: String, bundleID: String?)] {
        var out: [Int32: (String, String?)] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            out[pid] = (app.localizedName ?? app.bundleIdentifier ?? "App", app.bundleIdentifier)
        }
        return out
    }
}
