import Testing
import Foundation
@testable import TrimCore

@Suite("ProcessMonitor")
struct ProcessMonitorTests {
    typealias Raw = ProcessMonitor.RawProc

    @Test func aggregateGroupsAppsByBundleID() {
        let procs = [
            Raw(pid: 10, name: "Google Chrome", bundleID: "com.google.Chrome", kind: .app, footprint: 1000),
            Raw(pid: 11, name: "Google Chrome Helper", bundleID: "com.google.Chrome", kind: .app, footprint: 2000),
            Raw(pid: 20, name: "Xcode", bundleID: "com.apple.dt.Xcode", kind: .app, footprint: 4000),
        ]
        let usages = ProcessMonitor.aggregate(procs)
        #expect(usages.count == 2)
        let chrome = usages.first { $0.bundleID == "com.google.Chrome" }!
        #expect(chrome.footprint == 3000)            // helpers summed under the app
        #expect(chrome.displayName == "Google Chrome")
    }

    @Test func aggregateKeepsAgentsAndProcessesSeparate() {
        let procs = [
            Raw(pid: 100, name: "Claude Code", bundleID: nil, kind: .agent, footprint: 8000),
            Raw(pid: 200, name: "node",        bundleID: nil, kind: .process, footprint: 1500),
            Raw(pid: 201, name: "node",        bundleID: nil, kind: .process, footprint: 1200),
        ]
        let usages = ProcessMonitor.aggregate(procs)
        #expect(usages.count == 3)                   // not merged by name; keyed by pid
    }

    @Test func topNSortsByFootprintThenName() {
        let usages = [
            ProcessUsage(id: "a", displayName: "Zed", bundleID: nil, kind: .process, footprint: 100, cpu: 0),
            ProcessUsage(id: "b", displayName: "Aero", bundleID: nil, kind: .process, footprint: 100, cpu: 0),
            ProcessUsage(id: "c", displayName: "Big", bundleID: nil, kind: .process, footprint: 999, cpu: 0),
        ]
        let top = ProcessMonitor.topN(usages, limit: 2)
        #expect(top.map(\.displayName) == ["Big", "Aero"])  // footprint desc, then name asc
    }

    @Test func isNoiseDaemonFiltersKnownHelpers() {
        #expect(ProcessMonitor.isNoiseDaemon("cfprefsd") == true)
        #expect(ProcessMonitor.isNoiseDaemon("distnoted") == true)
        #expect(ProcessMonitor.isNoiseDaemon("node") == false)
        #expect(ProcessMonitor.isNoiseDaemon("python3") == false)
    }

    @Test @MainActor func liveSampleDoesNotCrash() {
        let m = ProcessMonitor()
        m.sample(limit: 8, agentsEnabled: true)
        #expect(m.top.count <= 8)
        for u in m.top { #expect(u.footprint > 0) }
    }

    // MARK: - aggregateAgentTrees (TDD: tests written before the helper exists)

    @Test func aggregateAgentTreesSumsSubtree() {
        typealias Rec = ProcessMonitor.AgentRecord
        let records: [Rec] = [
            Rec(pid: 100, ppid: 1,   kind: .claudeCode, footprint: 1000),
            Rec(pid: 101, ppid: 100, kind: nil,          footprint: 500),
            Rec(pid: 102, ppid: 101, kind: nil,          footprint: 200),
            Rec(pid: 200, ppid: 1,   kind: nil,          footprint: 9000), // unrelated; no kind → not a root
        ]
        let sessions = ProcessMonitor.aggregateAgentTrees(records)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "pid:100")
        #expect(sessions[0].displayName == "Claude Code")
        #expect(sessions[0].kind == .agent)
        #expect(sessions[0].footprint == 1700) // 1000 + 500 + 200; pid 200 excluded (no kind → not in tree)
    }

    @Test func aggregateAgentTreesCutsAtNestedRoot() {
        typealias Rec = ProcessMonitor.AgentRecord
        // 100 (claude) → 101 (helper) → 102 (codex root) → 103 (codex helper)
        let records: [Rec] = [
            Rec(pid: 100, ppid: 1,   kind: .claudeCode, footprint: 1000),
            Rec(pid: 101, ppid: 100, kind: nil,          footprint: 100),
            Rec(pid: 102, ppid: 101, kind: .codex,       footprint: 2000),
            Rec(pid: 103, ppid: 102, kind: nil,          footprint: 500),
        ]
        let sessions = ProcessMonitor.aggregateAgentTrees(records)
        #expect(sessions.count == 2)
        let claude = sessions.first { $0.displayName == "Claude Code" }!
        let codex  = sessions.first { $0.displayName == "Codex" }!
        // Claude subtree: 100 + 101 only — cut at 102 (nested Codex root)
        #expect(claude.footprint == 1100)
        // Codex subtree: 102 + 103
        #expect(codex.footprint == 2500)
    }

    // MARK: - Per-session identity (TDD: tests written before the helpers exist)
    // Concurrent same-kind sessions must be distinguishable; the project directory
    // (cwd) is the primary human-facing distinguisher, pid the guaranteed fallback.

    @Test func projectNameTakesLastPathComponent() {
        #expect(ProcessMonitor.projectName(fromCwd: "/Users/x/side-workspace/trim-my-mac") == "trim-my-mac")
    }

    @Test func projectNameStripsTrailingSlash() {
        #expect(ProcessMonitor.projectName(fromCwd: "/Users/x/proj/") == "proj")
    }

    @Test func projectNameRootOrEmptyIsNil() {
        #expect(ProcessMonitor.projectName(fromCwd: "/") == nil)
        #expect(ProcessMonitor.projectName(fromCwd: "") == nil)
    }

    @Test func agentLabelUsesProjectWhenPresent() {
        #expect(ProcessMonitor.agentSessionLabel(baseName: "Claude Code", projectName: "trim-my-mac", pid: 42)
                == "Claude Code · trim-my-mac")
    }

    @Test func agentLabelFallsBackToPidWhenNoProject() {
        #expect(ProcessMonitor.agentSessionLabel(baseName: "Codex", projectName: nil, pid: 4242)
                == "Codex · pid 4242")
        #expect(ProcessMonitor.agentSessionLabel(baseName: "Codex", projectName: "", pid: 4242)
                == "Codex · pid 4242")
    }

    @Test func processCwdForSelfIsAbsolutePath() {
        let cwd = ProcessMonitor.processCwd(ProcessInfo.processInfo.processIdentifier)
        #expect(cwd != nil)
        #expect(cwd?.hasPrefix("/") == true)
    }
}
