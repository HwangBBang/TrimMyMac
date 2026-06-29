import Testing
import Foundation
@testable import CleanCore

/// A StatProbing test double that always returns a fixed (possibly nil) snapshot,
/// letting us force the "changed since scan" branch deterministically.
private struct FixedProbe: StatProbing {
    let forced: StatSnapshot?
    func snapshot(of url: URL) -> StatSnapshot? { forced }
}

@Suite("SafeRemover")
struct SafeRemoverTests {

    private let sandbox: URL

    init() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SafeRemoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    /// Build a ScanItem whose `snapshot` matches the file currently on disk.
    private func liveItem(at url: URL, allocated: Int64, probe: some StatProbing) throws -> ScanItem {
        let snap = try #require(probe.snapshot(of: url), "probe must see existing fixture")
        return ScanItem(
            id: UUID(),
            url: url,
            logicalSize: snap.size,
            allocatedSize: allocated,
            kind: .userCache,
            snapshot: snap,
            isAutoSelected: true,
            evidence: nil
        )
    }

    // (a) Unchanged file → trashed: not at original path, in outcome.trashed, reclaimedAllocated > 0
    @Test func unchangedFileIsTrashed() throws {
        let probe = DefaultStatProbe()
        let fileURL = sandbox.appendingPathComponent("victim.txt")
        try Data("delete me".utf8).write(to: fileURL)

        let item = try liveItem(at: fileURL, allocated: 4096, probe: probe)
        let remover = SafeRemover(probe: probe, fileManager: FileManager.default)

        let outcome = remover.trash([item])

        #expect(!FileManager.default.fileExists(atPath: fileURL.path),
                "trashed file must no longer exist at its original path")
        #expect(outcome.trashed.contains(fileURL),
                "outcome.trashed must contain the original url")
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.reclaimedAllocated > 0)
        #expect(outcome.reclaimedAllocated == 4096)

        try? FileManager.default.removeItem(at: sandbox)
    }

    // (b) File whose probe reports a DIFFERENT snapshot → skipped with reason "changed since scan"
    @Test func changedSinceScanIsSkipped() throws {
        let realProbe = DefaultStatProbe()
        let fileURL = sandbox.appendingPathComponent("changed.txt")
        try Data("original".utf8).write(to: fileURL)

        // Item claims the file looked like this at scan time...
        let item = try liveItem(at: fileURL, allocated: 4096, probe: realProbe)

        // ...but the probe used during trash reports a DIFFERENT size, forcing the changed branch.
        let stale = StatSnapshot(
            size: item.snapshot.size + 999,
            mtime: item.snapshot.mtime,
            fileID: item.snapshot.fileID,
            deviceID: item.snapshot.deviceID
        )
        let remover = SafeRemover(probe: FixedProbe(forced: stale), fileManager: FileManager.default)

        let outcome = remover.trash([item])

        #expect(FileManager.default.fileExists(atPath: fileURL.path),
                "a changed item must not be trashed")
        #expect(outcome.trashed.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.url == fileURL)
        #expect(outcome.skipped.first?.reason == "changed since scan")
        #expect(outcome.reclaimedAllocated == 0)

        try? FileManager.default.removeItem(at: sandbox)
    }

    // (c) Missing file (probe returns nil) → skipped with reason "no longer exists"
    @Test func missingFileIsSkipped() throws {
        let missingURL = sandbox.appendingPathComponent("never-existed.txt")
        #expect(!FileManager.default.fileExists(atPath: missingURL.path))

        // Snapshot value is irrelevant; the real probe returns nil for a missing path.
        let bogusSnap = StatSnapshot(size: 10, mtime: 0, fileID: 1, deviceID: 1)
        let item = ScanItem(
            id: UUID(),
            url: missingURL,
            logicalSize: 10,
            allocatedSize: 4096,
            kind: .userCache,
            snapshot: bogusSnap,
            isAutoSelected: true,
            evidence: nil
        )
        let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: FileManager.default)

        let outcome = remover.trash([item])

        // Decision: a path that no longer exists is SKIPPED (nothing to reclaim, not an error).
        #expect(outcome.trashed.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.url == missingURL)
        #expect(outcome.skipped.first?.reason == "no longer exists")
        #expect(outcome.reclaimedAllocated == 0)

        try? FileManager.default.removeItem(at: sandbox)
    }
}
