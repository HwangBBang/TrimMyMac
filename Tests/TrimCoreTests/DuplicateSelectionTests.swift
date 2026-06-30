import Testing
import Foundation
@testable import TrimCore

@Suite("DuplicateSelection")
struct DuplicateSelectionTests {

    // Build a throwaway ScanItem with deterministic fields.
    private func makeItem(_ name: String, size: Int64) -> ScanItem {
        let url = URL(fileURLWithPath: "/tmp/trimmymac-fixtures/\(name)")
        let snap = StatSnapshot(size: size, mtime: 1_000, fileID: 1, deviceID: 1)
        return ScanItem(
            id: UUID(),
            url: url,
            logicalSize: size,
            allocatedSize: size,
            kind: .duplicate,
            snapshot: snap,
            isAutoSelected: false,
            evidence: nil
        )
    }

    @Test func exactGroupContributesNonFirstItems() throws {
        let group = DuplicateGroup(
            id: UUID(),
            confidence: .exact,
            items: [makeItem("a", size: 10), makeItem("b", size: 10), makeItem("c", size: 10)]
        )
        let selected = autoSelectedItems(groups: [group])
        // Kept original (items[0]) excluded; the other two contributed.
        #expect(selected.count == 2)
        let selectedURLs = Set(selected.map { $0.url })
        #expect(selectedURLs == Set([group.items[1].url, group.items[2].url]))
        #expect(!selected.contains(where: { $0.url == group.items[0].url }))
    }

    @Test func cloneSuspectedGroupContributesNothing() {
        let group = DuplicateGroup(
            id: UUID(),
            confidence: .cloneSuspected,
            items: [makeItem("x", size: 20), makeItem("y", size: 20)]
        )
        let selected = autoSelectedItems(groups: [group])
        #expect(selected.isEmpty)
    }

    @Test func mixedGroupsOnlyExactContribute() throws {
        let exact = DuplicateGroup(
            id: UUID(),
            confidence: .exact,
            items: [makeItem("e1", size: 30), makeItem("e2", size: 30)]
        )
        let clone = DuplicateGroup(
            id: UUID(),
            confidence: .cloneSuspected,
            items: [makeItem("c1", size: 40), makeItem("c2", size: 40), makeItem("c3", size: 40)]
        )
        let selected = autoSelectedItems(groups: [exact, clone])
        #expect(selected.count == 1)
        #expect(selected.first?.url == exact.items[1].url)
    }

    @Test func emptyInputYieldsEmpty() {
        #expect(autoSelectedItems(groups: []).isEmpty)
    }
}
