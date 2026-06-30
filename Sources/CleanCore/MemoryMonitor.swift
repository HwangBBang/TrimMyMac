import Foundation
import Dispatch
import Darwin

public enum MemoryPressure: String, Sendable {
    case normal, warning, critical
}

public struct MemorySample: Sendable {
    public let total: UInt64
    public let used: UInt64
    public let active: UInt64
    public let inactive: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let swapUsed: UInt64
    public let pressure: MemoryPressure

    public init(
        total: UInt64,
        used: UInt64,
        active: UInt64,
        inactive: UInt64,
        wired: UInt64,
        compressed: UInt64,
        swapUsed: UInt64,
        pressure: MemoryPressure
    ) {
        self.total = total
        self.used = used
        self.active = active
        self.inactive = inactive
        self.wired = wired
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pressure = pressure
    }
}

@MainActor
public final class MemoryMonitor: ObservableObject {
    @Published public private(set) var latest: MemorySample?

    private var pressureSource: DispatchSourceMemoryPressure?
    private var onChangeHandler: ((MemoryPressure) -> Void)?
    private var latestPressure: MemoryPressure = .normal
    private let monitorQueue = DispatchQueue(label: "com.cleanstatus.memorymonitor", qos: .utility)

    public init() {}

    // MARK: - Pure, testable helpers (nonisolated so unit tests call them synchronously)

    /// Maps a DispatchSource memory-pressure event to a MemoryPressure.
    /// Most-severe state wins when an event reports more than one bit.
    nonisolated static func pressure(from event: DispatchSource.MemoryPressureEvent) -> MemoryPressure {
        if event.contains(.critical) { return .critical }
        if event.contains(.warning) { return .warning }
        return .normal
    }

    /// Converts raw VM page counts to byte totals for a given page size.
    /// Formula (matches macOS Stats): used = active + inactive + speculative + wired + compressed − purgeable − external,
    /// clamped to 0 ... total to guard against pathological cases where purgeable+external exceed the additive sum.
    nonisolated static func memoryBytes(
        activePages: UInt64,
        inactivePages: UInt64,
        speculativePages: UInt64,
        wiredPages: UInt64,
        compressedPages: UInt64,
        purgeablePages: UInt64,
        externalPages: UInt64,
        pageSize: UInt64,
        total: UInt64
    ) -> (active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, used: UInt64) {
        let active = activePages * pageSize
        let inactive = inactivePages * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressedPages * pageSize
        let rawUsed = Double(activePages + inactivePages + speculativePages + wiredPages + compressedPages) * Double(pageSize)
                    - Double(purgeablePages + externalPages) * Double(pageSize)
        let used = UInt64(max(0, min(rawUsed, Double(total))))
        return (active, inactive, wired, compressed, used)
    }

    // MARK: - Live sampling

    public func sample() -> MemorySample {
        // Page size.
        var rawPageSize: vm_size_t = 0
        if host_page_size(mach_host_self(), &rawPageSize) != KERN_SUCCESS || rawPageSize == 0 {
            rawPageSize = 4096   // conservative fallback; host_page_size succeeds on all macOS
        }
        let pageSize = UInt64(rawPageSize)

        // VM statistics via host_statistics64(HOST_VM_INFO64).
        var vmStat = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &vmStat) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), intPtr, &count)
            }
        }

        // Total physical memory (needed by memoryBytes for clamping; read before byte math).
        var total: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.memsize", &total, &totalSize, nil, 0)

        let bytes: (active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, used: UInt64)
        if kr == KERN_SUCCESS {
            bytes = Self.memoryBytes(
                activePages: UInt64(vmStat.active_count),
                inactivePages: UInt64(vmStat.inactive_count),
                speculativePages: UInt64(vmStat.speculative_count),
                wiredPages: UInt64(vmStat.wire_count),
                compressedPages: UInt64(vmStat.compressor_page_count),
                purgeablePages: UInt64(vmStat.purgeable_count),
                externalPages: UInt64(vmStat.external_page_count),
                pageSize: pageSize,
                total: total)
        } else {
            bytes = (0, 0, 0, 0, 0)
        }

        // Swap usage.
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let result = MemorySample(
            total: total,
            used: bytes.used,
            active: bytes.active,
            inactive: bytes.inactive,
            wired: bytes.wired,
            compressed: bytes.compressed,
            swapUsed: swap.xsu_used,
            pressure: latestPressure)
        latest = result
        return result
    }

    // MARK: - Pressure monitoring

    public func start(onChange: @escaping (MemoryPressure) -> Void) {
        stop()
        onChangeHandler = onChange
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: monitorQueue)
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            // Read the actual current pressure via .data (NOT .mask) on the monitor queue,
            // then hop to the main actor via a Sendable raw value.
            let raw = source.data.rawValue
            Task { @MainActor in
                self?.handlePressureEvent(DispatchSource.MemoryPressureEvent(rawValue: raw))
            }
        }
        pressureSource = source
        source.resume()
    }

    public func stop() {
        pressureSource?.cancel()
        pressureSource = nil
        onChangeHandler = nil
    }

    // MARK: - Private

    private func handlePressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
        let pressure = Self.pressure(from: event)
        latestPressure = pressure
        _ = sample()               // refreshes @Published latest with the new pressure
        onChangeHandler?(pressure)
    }
}
