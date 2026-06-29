import Testing
import Foundation
@testable import CleanCore

@Suite("DefaultStatProbe")
struct DefaultStatProbeTests {

    // Set up a temp directory unique to each test run.
    private let dir: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DefaultStatProbeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // 1a: snapshot of a real file has the exact byte size and non-zero ids matching a direct lstat.
    @Test func snapshotMatchesDirectLstat() throws {
        let file = dir.appendingPathComponent("payload.bin")
        let payload = Data(repeating: 0xAB, count: 4096)
        try payload.write(to: file)

        let probe = DefaultStatProbe()
        let snap = try #require(probe.snapshot(of: file), "snapshot of an existing file must not be nil")

        #expect(snap.size == 4096, "size must equal the written byte length")
        #expect(snap.fileID != 0, "fileID (st_ino) must be non-zero")
        #expect(snap.deviceID != 0, "deviceID (st_dev) must be non-zero")

        var st = stat()
        let rc = file.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return lstat(ptr, &st)
        }
        try #require(rc == 0, "direct lstat must succeed")
        #expect(snap.size == Int64(st.st_size))
        #expect(snap.fileID == UInt64(st.st_ino))
        #expect(snap.deviceID == Int32(st.st_dev))
        let expectedMtime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        #expect(snap.mtime == expectedMtime)

        // Clean up temp dir after this test
        try? FileManager.default.removeItem(at: dir)
    }

    // 1b: snapshot of a missing path returns nil.
    @Test func snapshotOfMissingPathIsNil() throws {
        let missing = dir.appendingPathComponent("does-not-exist.bin")
        #expect(DefaultStatProbe().snapshot(of: missing) == nil)
        try? FileManager.default.removeItem(at: dir)
    }

    // 1c: StatSnapshot Equatable — equal fields compare equal, any differing field compares unequal.
    @Test func statSnapshotEquatable() throws {
        let a = StatSnapshot(size: 10, mtime: 100, fileID: 7, deviceID: 3)
        let b = StatSnapshot(size: 10, mtime: 100, fileID: 7, deviceID: 3)
        #expect(a == b)

        #expect(a != StatSnapshot(size: 11, mtime: 100, fileID: 7, deviceID: 3))
        #expect(a != StatSnapshot(size: 10, mtime: 101, fileID: 7, deviceID: 3))
        #expect(a != StatSnapshot(size: 10, mtime: 100, fileID: 8, deviceID: 3))
        #expect(a != StatSnapshot(size: 10, mtime: 100, fileID: 7, deviceID: 4))
        try? FileManager.default.removeItem(at: dir)
    }
}
