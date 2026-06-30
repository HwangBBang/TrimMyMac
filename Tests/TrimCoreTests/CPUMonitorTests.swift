import Testing
@testable import TrimCore

@Suite("CPUMonitor")
struct CPUMonitorTests {
    typealias Ticks = CPUMonitor.CPUTicks

    // MARK: - usage math from tick deltas

    @Test func usageFromKnownDeltas() {
        // busy delta = user 20 + system 20 + nice 0 = 40; idle delta = 60; total = 100 -> 40%
        let prev = Ticks(user: 100, system: 100, nice: 0, idle: 1000)
        let cur  = Ticks(user: 120, system: 120, nice: 0, idle: 1060)
        let r = CPUMonitor.usagePercents(previous: prev, current: cur)
        #expect(r.usage == 40)
        #expect(r.system == 20)
        #expect(r.user == 20)
    }

    @Test func zeroIntervalReturnsZero() {
        // No elapsed ticks -> avoid divide-by-zero, report 0.
        let t = Ticks(user: 5, system: 5, nice: 5, idle: 5)
        let r = CPUMonitor.usagePercents(previous: t, current: t)
        #expect(r.usage == 0)
        #expect(r.system == 0)
        #expect(r.user == 0)
    }

    @Test func counterResetClampsToZero() {
        // current < previous on every field -> all deltas clamp to 0 -> total 0 -> zeros (no underflow)
        let prev = Ticks(user: 100, system: 100, nice: 100, idle: 100)
        let cur  = Ticks(user: 10, system: 10, nice: 10, idle: 10)
        let r = CPUMonitor.usagePercents(previous: prev, current: cur)
        #expect(r.usage == 0)
    }

    @Test func fullyBusyReportsHundred() {
        let prev = Ticks(user: 0, system: 0, nice: 0, idle: 0)
        let cur  = Ticks(user: 50, system: 50, nice: 0, idle: 0)
        let r = CPUMonitor.usagePercents(previous: prev, current: cur)
        #expect(r.usage == 100)
    }

    @Test func niceCountsTowardUserAndBusy() {
        // nice ticks must count toward busy AND toward `user` (not system).
        let prev = Ticks(user: 0, system: 0, nice: 0, idle: 0)
        let cur  = Ticks(user: 0, system: 0, nice: 50, idle: 50)
        let r = CPUMonitor.usagePercents(previous: prev, current: cur)
        #expect(r.usage == 50)
        #expect(r.user == 50)
        #expect(r.system == 0)
    }

    @Test func partialDeltaClampOnSingleField() {
        // idle counter reset (cur idle < prev) clamps idle delta to 0; busy still accrues.
        let prev = Ticks(user: 0, system: 0, nice: 0, idle: 100)
        let cur  = Ticks(user: 40, system: 10, nice: 0, idle: 50) // idle delta clamps to 0
        let r = CPUMonitor.usagePercents(previous: prev, current: cur)
        // total = busy 50 + idle 0 = 50 -> 100% busy
        #expect(r.usage == 100)
    }

    // MARK: - Smoke: live sample() executes the syscall path, baseline then bounded

    @Test @MainActor func firstSampleBaselineThenBounded() {
        let m = CPUMonitor()
        #expect(m.latest == nil)
        let first = m.sample()            // baseline: no interval yet
        #expect(first.usage == 0)
        #expect(m.latest != nil)
        let second = m.sample()           // delta over a tiny interval — must be a valid percent
        #expect(second.usage >= 0 && second.usage <= 100)
        #expect(second.system >= 0 && second.system <= 100)
        #expect(second.user >= 0 && second.user <= 100)
    }
}
