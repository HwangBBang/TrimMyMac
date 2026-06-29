import Foundation

public protocol StatProbing: Sendable {
    func snapshot(of url: URL) -> StatSnapshot?   // lstat-based; nil if missing
}

public struct DefaultStatProbe: StatProbing {
    public init() {}

    public func snapshot(of url: URL) -> StatSnapshot? {
        var st = stat()
        let rc = url.withUnsafeFileSystemRepresentation { ptr -> Int32 in
            guard let ptr else { return -1 }
            return lstat(ptr, &st)
        }
        guard rc == 0 else { return nil }

        let mtime = TimeInterval(st.st_mtimespec.tv_sec)
            + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000

        return StatSnapshot(
            size: Int64(st.st_size),
            mtime: mtime,
            fileID: UInt64(st.st_ino),
            deviceID: Int32(st.st_dev)
        )
    }
}
