import Testing
@testable import TrimCore

@Suite("AgentSessionMonitor")
struct AgentSessionMonitorTests {
    typealias Rec = AgentSessionMonitor.ProcRecord

    // MARK: - classify

    @Test func classifyCodexBinary() {
        #expect(AgentSessionMonitor.classify(comm: "codex", argv: []) == .codex)
    }

    @Test func classifyClaudeBinary() {
        #expect(AgentSessionMonitor.classify(comm: "claude", argv: []) == .claudeCode)
    }

    @Test func classifyClaudeViaNodeArgv() {
        let argv = ["/usr/bin/node", "/Users/x/.npm/@anthropic-ai/claude-code/cli.js", "--resume"]
        #expect(AgentSessionMonitor.classify(comm: "node", argv: argv) == .claudeCode)
    }

    @Test func classifyCodexViaArgv() {
        let argv = ["/opt/homebrew/bin/codex", "chat"]
        #expect(AgentSessionMonitor.classify(comm: "node", argv: argv) == .codex)
    }

    @Test func classifyUnrelatedIsNil() {
        #expect(AgentSessionMonitor.classify(comm: "node", argv: ["/usr/bin/node", "server.js"]) == nil)
        #expect(AgentSessionMonitor.classify(comm: "Safari", argv: []) == nil)
    }

    // MARK: - cpu math

    @Test func cpuPercentHalfCore() {
        // 0.5s cpu over 1s wall = 50% of one core
        let p = AgentSessionMonitor.cpuPercentOfCore(deltaCpuNs: 0.5e9, elapsedNs: 1e9)
        #expect(abs(p - 50) < 0.0001)
    }

    @Test func cpuPercentZeroElapsedReturnsZero() {
        #expect(AgentSessionMonitor.cpuPercentOfCore(deltaCpuNs: 1e9, elapsedNs: 0) == 0)
    }

    @Test func cpuPercentCanExceedHundred() {
        // two cores' worth of cpu time over the interval = 200%
        let p = AgentSessionMonitor.cpuPercentOfCore(deltaCpuNs: 2e9, elapsedNs: 1e9)
        #expect(abs(p - 200) < 0.0001)
    }

    // MARK: - aggregate

    @Test func aggregateSumsSubtree() {
        let recs = [
            Rec(pid: 100, ppid: 1,   kind: .claudeCode, cpu: 10, rss: 1000),
            Rec(pid: 101, ppid: 100, kind: nil,         cpu: 5,  rss: 500),
            Rec(pid: 102, ppid: 101, kind: nil,         cpu: 2,  rss: 200),
            Rec(pid: 200, ppid: 1,   kind: nil,         cpu: 99, rss: 9999),  // unrelated
        ]
        let s = AgentSessionMonitor.aggregate(recs)
        #expect(s.count == 1)
        #expect(s[0].pid == 100)
        #expect(s[0].kind == .claudeCode)
        #expect(s[0].cpu == 17)        // 10 + 5 + 2
        #expect(s[0].memory == 1700)   // 1000 + 500 + 200
    }

    @Test func aggregateCutsAtNestedRoot() {
        // claude 100 -> 101 -> codex 102 (own root) -> 103
        let recs = [
            Rec(pid: 100, ppid: 1,   kind: .claudeCode, cpu: 10, rss: 1000),
            Rec(pid: 101, ppid: 100, kind: nil,         cpu: 1,  rss: 100),
            Rec(pid: 102, ppid: 101, kind: .codex,      cpu: 20, rss: 2000),
            Rec(pid: 103, ppid: 102, kind: nil,         cpu: 5,  rss: 500),
        ]
        let s = AgentSessionMonitor.aggregate(recs)
        #expect(s.count == 2)
        let claude = s.first { $0.pid == 100 }!
        #expect(claude.cpu == 11)        // 10 + 1, NOT including codex subtree
        #expect(claude.memory == 1100)
        let codex = s.first { $0.pid == 102 }!
        #expect(codex.cpu == 25)         // 20 + 5
        #expect(codex.memory == 2500)
    }

    @Test func aggregateSortsByCpuDescending() {
        let recs = [
            Rec(pid: 10, ppid: 1, kind: .claudeCode, cpu: 3,  rss: 1),
            Rec(pid: 20, ppid: 1, kind: .codex,      cpu: 30, rss: 1),
        ]
        let s = AgentSessionMonitor.aggregate(recs)
        #expect(s.map(\.pid) == [20, 10])
    }

    @Test func aggregateEmptyWhenNoRoots() {
        let recs = [Rec(pid: 1, ppid: 0, kind: nil, cpu: 5, rss: 100)]
        #expect(AgentSessionMonitor.aggregate(recs).isEmpty)
    }

    // MARK: - live smoke (must not crash; values are well-formed)

    @Test @MainActor func liveSampleDoesNotCrash() {
        let m = AgentSessionMonitor()
        m.sample()   // baseline
        m.sample()   // delta over a tiny interval
        for s in m.sessions {
            #expect(s.cpu >= 0)
            #expect(s.pid > 0)
        }
    }
}
