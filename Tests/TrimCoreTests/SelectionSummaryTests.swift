import Testing
import Foundation
@testable import TrimCore

@Suite("SelectionSummary")
struct SelectionSummaryTests {

    private func makeItem(logical: Int64, allocated: Int64, kind: ItemKind = .userCache) -> ScanItem {
        ScanItem(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/trimmymac-fixture/\(UUID().uuidString)"),
            logicalSize: logical,
            allocatedSize: allocated,
            kind: kind,
            snapshot: StatSnapshot(size: logical, mtime: 0, fileID: 1, deviceID: 1),
            isAutoSelected: true,
            evidence: nil
        )
    }

    @Test func emptySelectionIsZero() {
        let summary = selectionSummary(items: [])
        #expect(summary == SelectionSummary(count: 0, logicalBytes: 0, allocatedBytes: 0))
    }

    @Test func sumsCountAndBothByteTotals() {
        let items = [
            makeItem(logical: 100, allocated: 4096),
            makeItem(logical: 250, allocated: 8192, kind: .log),
            makeItem(logical: 1,   allocated: 4096, kind: .devJunk),
        ]
        let summary = selectionSummary(items: items)
        #expect(summary.count == 3)
        #expect(summary.logicalBytes == 351)
        #expect(summary.allocatedBytes == 16384)
    }

    @Test func summaryReflectsOnlyPassedItems() {
        // Caller is responsible for filtering to the *selected* subset before calling.
        let all = [
            makeItem(logical: 10, allocated: 4096),
            makeItem(logical: 20, allocated: 4096),
            makeItem(logical: 30, allocated: 4096),
        ]
        let selected = Array(all.prefix(2))
        let summary = selectionSummary(items: selected)
        #expect(summary.count == 2)
        #expect(summary.logicalBytes == 30)
        #expect(summary.allocatedBytes == 8192)
    }
}
