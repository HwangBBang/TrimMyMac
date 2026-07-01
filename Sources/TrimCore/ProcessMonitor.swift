import Foundation

public enum ProcessKind: Sendable, Equatable { case app, agent, process }

public struct ProcessUsage: Identifiable, Sendable, Equatable {
    public let id: String        // app=bundleID, agent/process="pid:<n>"
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

import AppKit

@MainActor
public final class ProcessMonitor: ObservableObject {
    @Published public private(set) var top: [ProcessUsage] = []
    @Published public private(set) var agentSessions: [ProcessUsage] = []
    public init() {}
}
