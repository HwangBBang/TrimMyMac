import Foundation
import Darwin

/// Whole-percent CPU usage snapshot. `usage` is total busy time; `system` and
/// `user` (user includes "nice") break it down. All values are 0...100.
public struct CPUSample: Sendable {
    public let usage: Int
    public let system: Int
    public let user: Int

    public init(usage: Int, system: Int, user: Int) {
        self.usage = usage
        self.system = system
        self.user = user
    }
}

/// Samples host CPU load. Usage is computed from the *delta* between two
/// cumulative tick reads, so the monitor is stateful and MUST be driven by a
/// single sampler (the menu-bar label) — sampling from two places would split
/// the interval and corrupt the deltas.
@MainActor
public final class CPUMonitor: ObservableObject {
    @Published public private(set) var latest: CPUSample?

    private var previous: CPUTicks?

    public init() {}

    // MARK: - Pure, testable helpers (nonisolated so unit tests call them synchronously)

    /// Aggregated CPU tick counters (summed across all cores), matching the
    /// HOST_CPU_LOAD_INFO state order: user, system, idle, nice.
    struct CPUTicks: Equatable, Sendable {
        var user: UInt64
        var system: UInt64
        var nice: UInt64
        var idle: UInt64
    }

    /// Whole-percent usage from the delta between two cumulative tick reads.
    /// busy = user + system + nice; usage% = busy / (busy + idle). A counter
    /// reset/overflow (current < previous on a field) clamps that field's delta
    /// to 0. Returns zeros when no time elapsed (total delta == 0). `user`
    /// includes nice to mirror how Activity Monitor groups niced work.
    nonisolated static func usagePercents(previous: CPUTicks, current: CPUTicks)
        -> (usage: Int, system: Int, user: Int)
    {
        func delta(_ a: UInt64, _ b: UInt64) -> Double { a >= b ? Double(a - b) : 0 }
        let u = delta(current.user, previous.user)
        let s = delta(current.system, previous.system)
        let n = delta(current.nice, previous.nice)
        let i = delta(current.idle, previous.idle)
        let busy = u + s + n
        let total = busy + i
        guard total > 0 else { return (0, 0, 0) }
        func pct(_ x: Double) -> Int { Int((x / total * 100).rounded()) }
        return (pct(busy), pct(s), pct(u + n))
    }

    /// Reads aggregated CPU tick counters via host_statistics(HOST_CPU_LOAD_INFO).
    /// Returns nil if the syscall fails.
    nonisolated static func readTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), host_flavor_t(HOST_CPU_LOAD_INFO), intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        // cpu_ticks is a fixed 4-tuple indexed by CPU_STATE_{USER,SYSTEM,IDLE,NICE} = 0,1,2,3.
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            nice: UInt64(info.cpu_ticks.3),
            idle: UInt64(info.cpu_ticks.2)
        )
    }

    // MARK: - Live sampling

    /// Samples current CPU usage. The first call establishes a baseline and
    /// reports 0% (no interval yet); subsequent calls report usage since the
    /// previous call. If the syscall fails the last known sample is retained.
    @discardableResult
    public func sample() -> CPUSample {
        guard let current = Self.readTicks() else {
            return latest ?? CPUSample(usage: 0, system: 0, user: 0)
        }
        defer { previous = current }

        guard let prev = previous else {
            let baseline = CPUSample(usage: 0, system: 0, user: 0)
            latest = baseline
            return baseline
        }

        let p = Self.usagePercents(previous: prev, current: current)
        let result = CPUSample(usage: p.usage, system: p.system, user: p.user)
        latest = result
        return result
    }
}
