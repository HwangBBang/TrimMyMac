import Testing
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
}
