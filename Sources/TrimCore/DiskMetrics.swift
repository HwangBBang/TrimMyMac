import Foundation

public struct DiskSample: Sendable {
    public let total: Int64
    public let availableImportant: Int64   // volumeAvailableCapacityForImportantUsageKey
    public init(total: Int64, availableImportant: Int64) {
        self.total = total
        self.availableImportant = availableImportant
    }
}

public struct DiskMetrics {
    public init() {}

    public func sample(volume: URL) -> DiskSample? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? volume.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let availableImportant = values.volumeAvailableCapacityForImportantUsage
        else {
            return nil
        }
        return DiskSample(total: Int64(total), availableImportant: availableImportant)
    }
}
