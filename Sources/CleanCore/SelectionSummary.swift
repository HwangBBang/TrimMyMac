import Foundation

/// Pure, UI-free summary of a set of selected scan items.
/// The caller passes exactly the items that are currently selected.
public struct SelectionSummary: Equatable, Sendable {
    public let count: Int
    public let logicalBytes: Int64
    public let allocatedBytes: Int64

    public init(count: Int, logicalBytes: Int64, allocatedBytes: Int64) {
        self.count = count
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
    }
}

/// Sum the count and byte totals of the given (already-filtered) items.
public func selectionSummary(items: [ScanItem]) -> SelectionSummary {
    var logical: Int64 = 0
    var allocated: Int64 = 0
    for item in items {
        logical &+= item.logicalSize
        allocated &+= item.allocatedSize
    }
    return SelectionSummary(count: items.count, logicalBytes: logical, allocatedBytes: allocated)
}
