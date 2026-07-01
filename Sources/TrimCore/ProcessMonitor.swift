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
    /// processes) by phys_footprint, plus an agent-only projection. Heavy work is
    /// done synchronously here; Task 8 calls this from the 1 s sampler. (A future
    /// optimization can move collection to a utility queue; v1 keeps it simple but
    /// gates frequency in Task 8.)
    public func sample(limit: Int = 8, agentsEnabled: Bool = true) {
        let procs = AgentSessionMonitor.enumerateUserProcesses()   // same-uid only
        let pidToApp = Self.appsByPid()                            // pid -> (name, bundleID)

        // Footprint floor so the bare-process view isn't daemon noise.
        let floor: UInt64 = 200 * 1024 * 1024   // 200 MB

        var raws: [RawProc] = []
        var agentRaws: [RawProc] = []
        for pr in procs {
            guard let fp = Self.physFootprint(pr.pid) else { continue }

            // App?
            if let app = pidToApp[pr.pid] {
                raws.append(RawProc(pid: pr.pid, name: app.name, bundleID: app.bundleID, kind: .app, footprint: fp))
                continue
            }
            // Agent? (classify only plausible candidates to stay cheap)
            let lc = pr.comm.lowercased()
            let candidate = lc == "claude" || lc == "codex" || lc == "node" || lc == "deno" || lc == "bun"
                || lc.contains("claude") || lc.contains("codex")
            if agentsEnabled, candidate,
               let kind = AgentSessionMonitor.classify(comm: pr.comm, argv: AgentSessionMonitor.processArgs(pr.pid)) {
                let raw = RawProc(pid: pr.pid, name: kind.displayName, bundleID: nil, kind: .agent, footprint: fp)
                raws.append(raw); agentRaws.append(raw)
                continue
            }
            // Bare user process: only if notable and not obvious daemon noise.
            if fp >= floor, !Self.isNoiseDaemon(pr.comm) {
                raws.append(RawProc(pid: pr.pid, name: pr.comm, bundleID: nil, kind: .process, footprint: fp))
            }
        }

        top = Self.topN(Self.aggregate(raws), limit: limit)
        agentSessions = Self.aggregate(agentRaws).sorted { $0.footprint > $1.footprint }
    }

    /// Maps each GUI app's pid to its display name + bundleID (regular & accessory apps).
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
