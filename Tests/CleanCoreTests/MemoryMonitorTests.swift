import Testing
import Dispatch
@testable import CleanCore

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
        let r = MemoryMonitor.memoryBytes(
            activePages: 100,
            inactivePages: 50,
            wiredPages: 20,
            compressedPages: 10,
            pageSize: 16384)
        #expect(r.active == 100 * 16384)
        #expect(r.inactive == 50 * 16384)
        #expect(r.wired == 20 * 16384)
        #expect(r.compressed == 10 * 16384)
        // "used" follows Activity Monitor convention: active + wired + compressed
        #expect(r.used == (100 + 20 + 10) * 16384)
    }

    @Test func pageCountToBytesZero() {
        let r = MemoryMonitor.memoryBytes(
            activePages: 0, inactivePages: 0, wiredPages: 0, compressedPages: 0, pageSize: 4096)
        #expect(r.active == 0)
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
