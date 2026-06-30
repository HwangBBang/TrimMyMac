import Foundation

public struct FileEntry: Sendable {
    public let url: URL
    public let snapshot: StatSnapshot
    public let logicalSize: Int64
    public let allocatedSize: Int64
    public let isDirectory: Bool

    public init(
        url: URL,
        snapshot: StatSnapshot,
        logicalSize: Int64,
        allocatedSize: Int64,
        isDirectory: Bool
    ) {
        self.url = url
        self.snapshot = snapshot
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.isDirectory = isDirectory
    }
}

public struct Scanner {
    private let ignore: IgnoreRules
    private let probe: any StatProbing

    public init(ignore: IgnoreRules, probe: any StatProbing) {
        self.ignore = ignore
        self.probe = probe
    }

    private static let childKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileSizeKey
    ]

    /// Recursively enumerates regular files under `root` (depth-first).
    /// Skips ignored paths and guards against symlink loops via a visited Set of
    /// (deviceID, fileID) keys resolved through symlinks. Throws `CancellationError`
    /// if the enclosing Task is cancelled.
    public func enumerate(_ root: URL) throws -> [FileEntry] {
        if Task.isCancelled { throw CancellationError() }

        var results: [FileEntry] = []
        var visited = Set<String>()

        let rootValues = try? root.resourceValues(forKeys: Self.childKeys)
        if rootValues?.isDirectory == true {
            try walk(root, into: &results, visited: &visited)
        } else if rootValues?.isRegularFile == true,
                  rootValues?.isSymbolicLink != true,
                  !ignore.shouldIgnore(root),
                  let entry = fileEntry(for: root, values: rootValues) {
            results.append(entry)
        }
        return results
    }

    /// Sums logical (st_size) and allocated (totalFileAllocatedSize) over all
    /// non-ignored regular files in the subtree rooted at `root`.
    public func aggregateSize(_ root: URL) throws -> (logical: Int64, allocated: Int64) {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        for entry in try enumerate(root) {
            logical += entry.logicalSize
            allocated += entry.allocatedSize
        }
        return (logical, allocated)
    }

    // MARK: - Internals

    private func walk(
        _ dir: URL,
        into results: inout [FileEntry],
        visited: inout Set<String>
    ) throws {
        if Task.isCancelled { throw CancellationError() }
        if ignore.shouldIgnore(dir) { return }

        // Guard symlink loops: resolve the directory's real identity via lstat on
        // the canonicalised path so that a symlink pointing back to an ancestor
        // directory shares the same (deviceID, fileID) key and is skipped.
        let canonical = dir.resolvingSymlinksInPath()
        guard let dirSnap = probe.snapshot(of: canonical) else { return }
        let key = "\(dirSnap.deviceID)-\(dirSnap.fileID)"
        guard !visited.contains(key) else { return }
        visited.insert(key)

        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: Array(Self.childKeys),
                options: []
            )
        } catch {
            return // permission denied or unreadable; skip silently
        }

        for child in children {
            if Task.isCancelled { throw CancellationError() }
            if ignore.shouldIgnore(child) { continue }

            let values = try? child.resourceValues(forKeys: Self.childKeys)

            if values?.isDirectory == true {
                // Recurse; the visited set prevents infinite loops through symlinked dirs.
                try walk(child, into: &results, visited: &visited)
                continue
            }

            // Emit only regular files; skip symlinks and special files.
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }

            if let entry = fileEntry(for: child, values: values) {
                results.append(entry)
            }
        }
    }

    private func fileEntry(for url: URL, values: URLResourceValues? = nil) -> FileEntry? {
        guard let snap = probe.snapshot(of: url) else { return nil }
        let resolved = values ?? (try? url.resourceValues(forKeys: Self.childKeys))
        let allocated = Int64(resolved?.totalFileAllocatedSize ?? Int(snap.size))
        return FileEntry(
            url: url,
            snapshot: snap,
            logicalSize: snap.size,
            allocatedSize: allocated,
            isDirectory: false
        )
    }
}
