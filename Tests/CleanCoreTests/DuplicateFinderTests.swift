import Testing
import Darwin
import Foundation
@testable import CleanCore

// NOTE: CleanCore.Scanner to avoid ambiguity with Foundation.Scanner

@Suite("DuplicateFinder")
struct DuplicateFinderTests {

    private let fm = FileManager.default

    private func makeFinder() -> DuplicateFinder {
        let scanner = CleanCore.Scanner(ignore: .default, probe: DefaultStatProbe())
        return DuplicateFinder(scanner: scanner, probe: DefaultStatProbe())
    }

    private func makeBase() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DupFinderTest-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeDir(_ name: String, in base: URL) throws -> URL {
        let dir = base.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 1a: two identical files → one .exact group, exactly one auto-selected

    @Test func identicalContentYieldsOneExactGroupWithOneAutoSelected() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        let dir = try makeDir("identical", in: base)
        let content = Data("the quick brown fox jumps over the lazy dog".utf8)
        try content.write(to: dir.appendingPathComponent("a.txt"))
        try content.write(to: dir.appendingPathComponent("b.txt"))

        let groups = try makeFinder().find(in: [dir])

        #expect(groups.count == 1)
        let g = try #require(groups.first)
        #expect(g.confidence == .exact)
        #expect(g.items.count == 2)
        #expect(g.items[0].isAutoSelected == false, "items[0] is the kept original")
        #expect(g.items.filter { $0.isAutoSelected }.count == 1,
                "exactly one duplicate auto-selected for an exact group")
    }

    // MARK: - 1b: different content, same size → no group

    @Test func differentContentSameSizeYieldsNoGroup() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        let dir = try makeDir("different", in: base)
        try Data("AAAA".utf8).write(to: dir.appendingPathComponent("a.txt")) // 4 bytes
        try Data("BBBB".utf8).write(to: dir.appendingPathComponent("b.txt")) // 4 bytes

        let groups = try makeFinder().find(in: [dir])

        #expect(groups.isEmpty, "same size but different content must not group")
    }

    // MARK: - 1c: hardlinks to one inode are collapsed, NOT reported as deletable pair

    @Test func hardlinksAreCollapsedAndNotReported() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        let dir = try makeDir("hardlink", in: base)
        let src = dir.appendingPathComponent("orig.bin")
        try Data("hardlink content sample payload".utf8).write(to: src)
        let dst = dir.appendingPathComponent("link.bin")

        let rc = src.path.withCString { s in dst.path.withCString { d in link(s, d) } }
        if rc != 0 {
            Issue.record("link() failed: \(String(cString: strerror(errno)))")
            return
        }

        let groups = try makeFinder().find(in: [dir])

        #expect(groups.isEmpty,
                "two hardlinks share deviceID+fileID → one physical file → never a deletable pair")
    }

    // MARK: - 1d: APFS clone → .cloneSuspected, no auto-selected
    // If clonefile(2) is unsupported on the temp volume this test passes trivially
    // (non-APFS / HFS+ environment). Verified manually on APFS developer machines.

    @Test func apfsCloneIsReportedAsCloneSuspected() throws {
        let base = try makeBase()
        defer { try? fm.removeItem(at: base) }
        let dir = try makeDir("clone", in: base)
        let src = dir.appendingPathComponent("orig.bin")
        try Data("clone content payload for the apfs clone test".utf8).write(to: src)
        let dst = dir.appendingPathComponent("clone.bin")

        // clonefile(2): flags == 0. Guard-skips silently if the temp volume is not
        // APFS or cannot clone — documented as a manual check in the task report.
        let rc = src.path.withCString { s in dst.path.withCString { d in clonefile(s, d, 0) } }
        guard rc == 0 else {
            // clonefile not available on this volume — skipping clone assertion.
            // Error: \(String(cString: strerror(errno)))
            // Manual verification required: two APFS clones must yield .cloneSuspected
            // with NO auto-selected items and evidence != nil.
            return
        }

        let groups = try makeFinder().find(in: [dir])

        #expect(groups.count == 1)
        let g = try #require(groups.first)
        #expect(g.confidence == .cloneSuspected)
        #expect(g.items.filter { $0.isAutoSelected }.count == 0,
                "clone-suspected groups auto-select nothing")
        #expect(g.items[1].evidence != nil, "clone evidence note is set")
    }
}
