import Testing
import Foundation
@testable import TrimCore

@Suite("MemoryHistory")
struct MemoryHistoryTests {
    typealias S = MemoryMonitor.PressureSample
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func sample(_ offset: TimeInterval, _ p: MemoryPressure) -> S {
        S(time: t0.addingTimeInterval(offset), pressure: p, swapUsed: 0, usedRatio: 0.5)
    }

    @Test func trimmedDropsOldSamples() {
        let samples = [sample(0, .normal), sample(60, .normal), sample(115, .normal)]
        let kept = MemoryMonitor.trimmed(samples, keeping: 120, now: t0.addingTimeInterval(120))
        // cutoff = 0; sample(0) is exactly at cutoff (kept), all within window
        #expect(kept.count == 3)
        let kept2 = MemoryMonitor.trimmed(samples, keeping: 30, now: t0.addingTimeInterval(120))
        #expect(kept2.map(\.time) == [samples[2].time])   // cutoff 90 → only sample(115) survives
    }

    @Test func trimmedKeepsWithinWindow() {
        let samples = [sample(0, .normal), sample(100, .normal), sample(115, .normal)]
        let kept = MemoryMonitor.trimmed(samples, keeping: 30, now: t0.addingTimeInterval(120))
        #expect(kept.map(\.time) == [samples[1].time, samples[2].time]) // 100,115 >= 90
    }

    @Test func sustainedCriticalTrueWhenAllCriticalSpanningWindow() {
        let samples = (0...12).map { sample(Double($0) * 10, .critical) } // 0..120, 10s apart
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == true)
    }

    @Test func sustainedCriticalFalseWhenAnyNonCritical() {
        var samples = (0...12).map { sample(Double($0) * 10, .critical) }
        samples[5] = sample(50, .warning)
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == false)
    }

    @Test func sustainedCriticalFalseOnSleepGap() {
        // critical at 0..20, then a 100s gap (sleep), then critical at 120
        let samples = [sample(0, .critical), sample(10, .critical),
                       sample(20, .critical), sample(120, .critical)]
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == false)   // gap 20→120 exceeds maxGap
    }

    @Test func sustainedCriticalFalseWhenWindowNotYetSpanned() {
        let samples = [sample(110, .critical), sample(115, .critical), sample(120, .critical)]
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == false)   // oldest recent sample only 10s before now, < 120s window
    }

    @Test func sustainedCriticalTrueWithFractionalNow() {
        // 10 s-spaced critical samples spanning exactly 120 s; 'now' is 0.3 s past the boundary.
        // A strict cutoff (now − 120 = t0 + 0.3) would drop the t0 sample, leaving only 110.3 s
        // of span and causing a false negative. The fix must absorb this fractional-clock jitter.
        let samples = (0...12).map { sample(Double($0) * 10, .critical) } // t0, t0+10, …, t0+120
        let now = t0.addingTimeInterval(120.3)
        let ok = MemoryMonitor.sustainedCritical(samples, now: now, window: 120, maxGap: 15)
        #expect(ok == true)
    }
}
