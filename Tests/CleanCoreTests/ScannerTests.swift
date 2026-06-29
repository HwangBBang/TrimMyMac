import Testing
import Foundation
@testable import CleanCore

@Suite("Scanner")
struct ScannerTests {

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func removeIfExists(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func writeFile(_ url: URL, bytes count: Int) throws {
        var data = Data(count: count)
        for i in 0..<count { data[i] = UInt8(i % 251) }
        try data.write(to: url)
    }

    private func makeScanner() -> CleanCore.Scanner {
        CleanCore.Scanner(ignore: .default, probe: DefaultStatProbe())
    }

    // MARK: - 1a + 1b: nested files enumerated; node_modules skipped.

    @Test func enumerateFindsNestedFilesAndSkipsNodeModules() throws {
        let root = try makeTempRoot()
        defer { removeIfExists(root) }

        try writeFile(root.appendingPathComponent("a.txt"), bytes: 5)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(sub.appendingPathComponent("b.txt"), bytes: 10)
        try writeFile(sub.appendingPathComponent("c.bin"), bytes: 100)

        let nm = root.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("junk.txt"), bytes: 50)

        let entries = try makeScanner().enumerate(root)
        let names = Set(entries.map { $0.url.lastPathComponent })

        #expect(names == ["a.txt", "b.txt", "c.bin"])
        #expect(!names.contains("junk.txt"), "node_modules must be skipped")
        #expect(entries.allSatisfy { !$0.isDirectory })
    }

    // MARK: - 1c: symlink loop back to parent must terminate with no duplicates.

    @Test func symlinkLoopTerminates() throws {
        let root = try makeTempRoot()
        defer { removeIfExists(root) }

        try writeFile(root.appendingPathComponent("a.txt"), bytes: 5)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(sub.appendingPathComponent("b.txt"), bytes: 10)

        // loop -> root (would recurse forever without the visited guard)
        try FileManager.default.createSymbolicLink(
            at: sub.appendingPathComponent("loop"),
            withDestinationURL: root
        )

        let entries = try makeScanner().enumerate(root)
        let names = entries.map { $0.url.lastPathComponent }.sorted()

        #expect(names == ["a.txt", "b.txt"], "loop must not duplicate or hang")
    }

    // MARK: - 1d: aggregateSize logical equals known sum; allocated >= logical.

    @Test func aggregateSizeKnownTree() throws {
        let root = try makeTempRoot()
        defer { removeIfExists(root) }

        try writeFile(root.appendingPathComponent("a.txt"), bytes: 5)
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeFile(sub.appendingPathComponent("b.txt"), bytes: 10)
        try writeFile(sub.appendingPathComponent("c.bin"), bytes: 100)

        let nm = root.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        try writeFile(nm.appendingPathComponent("junk.txt"), bytes: 50)

        let totals = try makeScanner().aggregateSize(root)
        #expect(totals.logical == 115, "5 + 10 + 100, node_modules excluded")
        #expect(totals.allocated >= totals.logical, "allocated may exceed logical due to block rounding")
    }

    // MARK: - Cancellation: a cancelled Task makes enumerate throw CancellationError.

    @Test func cancellationThrows() async throws {
        let root = try makeTempRoot()
        defer { removeIfExists(root) }

        // Build a wide tree so the per-iteration cancellation check is reliably hit.
        for i in 0..<300 {
            try writeFile(root.appendingPathComponent("f\(i).txt"), bytes: 4)
        }
        let scanner = makeScanner()
        let captured = root

        let task = Task { () throws -> [CleanCore.FileEntry] in
            try scanner.enumerate(captured)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }
}
