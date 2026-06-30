import Testing
import Dispatch
@testable import TrimCore

@Suite("MemoryMonitor")
struct MemoryMonitorTests {

    // MARK: - DispatchSource memory-pressure-event -> MemoryPressure mapping

    @Test func pressureMappingWarning() {
        #expect(MemoryMonitor.pressure(from: .warning) == .warning)
    }

    @Test func pressureMappingCritical() {
        #expect(MemoryMonitor.pressure(from: .critical) == .critical)
    }

    @Test func pressureMappingNormal() {
        #expect(MemoryMonitor.pressure(from: .normal) == .normal)
    }

    @Test func pressureMappingCriticalDominatesWarning() {
        // A combined event must resolve to the most severe state.
        let combined: DispatchSource.MemoryPressureEvent = [.warning, .critical]
        #expect(MemoryMonitor.pressure(from: combined) == .critical)
    }

    // MARK: - page-count-to-bytes math

    @Test func pageCountToBytesWithKnownPageSize() {
        // Formula (matches Stats): active + inactive + speculative + wired + compressed − purgeable − external
        // active=100, inactive=50, speculative=30, wired=20, compressed=10, purgeable=15, external=5
        // used pages = 100+50+30+20+10−15−5 = 190
        let pageSize: UInt64 = 16384
        let total: UInt64 = 512 * pageSize   // 512 pages total, well above used
        let r = MemoryMonitor.memoryBytes(
            activePages: 100,
            inactivePages: 50,
            speculativePages: 30,
            wiredPages: 20,
            compressedPages: 10,
            purgeablePages: 15,
            externalPages: 5,
            pageSize: pageSize,
            total: total)
        #expect(r.active == 100 * pageSize)
        #expect(r.inactive == 50 * pageSize)
        #expect(r.wired == 20 * pageSize)
        #expect(r.compressed == 10 * pageSize)
        // used = (100+50+30+20+10−15−5) × pageSize = 190 × 16384
        #expect(r.used == 190 * pageSize)
    }

    @Test func pageCountToBytesZero() {
        let r = MemoryMonitor.memoryBytes(
            activePages: 0, inactivePages: 0, speculativePages: 0,
            wiredPages: 0, compressedPages: 0, purgeablePages: 0,
            externalPages: 0, pageSize: 4096, total: 0)
        #expect(r.active == 0)
        #expect(r.used == 0)
    }

    @Test func pageCountToBytesClampedToZeroOnUnderflow() {
        // purgeable+external exceed the additive sum → used must clamp to 0, not underflow
        let pageSize: UInt64 = 4096
        let total: UInt64 = 1000 * pageSize
        let r = MemoryMonitor.memoryBytes(
            activePages: 10,
            inactivePages: 5,
            speculativePages: 0,
            wiredPages: 0,
            compressedPages: 0,
            purgeablePages: 100,   // purgeable alone exceeds the sum
            externalPages: 0,
            pageSize: pageSize,
            total: total)
        #expect(r.used == 0)
    }

    // MARK: - Smoke: sample() executes live syscall path and populates latest
    // We deliberately do NOT assert on live system magnitudes.

    @Test @MainActor func samplePopulatesLatestWithoutCrashing() {
        let monitor = MemoryMonitor()
        #expect(monitor.latest == nil)
        let s = monitor.sample()
        // default pressure before any DispatchSource event is .normal
        #expect(s.pressure == .normal)
        #expect(monitor.latest != nil)
    }
}
