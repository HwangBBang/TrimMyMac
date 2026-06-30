import Foundation

public struct JunkRoot: Sendable {
    public let url: URL
    public let kind: ItemKind
    public let perBundleSubdirs: Bool

    public init(url: URL, kind: ItemKind, perBundleSubdirs: Bool) {
        self.url = url
        self.kind = kind
        self.perBundleSubdirs = perBundleSubdirs
    }
}

public struct JunkScanner {
    private let roots: [JunkRoot]
    private let scanner: Scanner
    private let isRunning: RunningCheck
    private let probe: any StatProbing
    private let fileManager: FileManager

    public init(roots: [JunkRoot], scanner: Scanner, isRunning: @escaping RunningCheck) {
        self.roots = roots
        self.scanner = scanner
        self.isRunning = isRunning
        self.probe = DefaultStatProbe()
        self.fileManager = FileManager.default
    }

    public static func defaultRoots(home: URL) -> [JunkRoot] {
        func sub(_ path: String) -> URL {
            home.appendingPathComponent(path, isDirectory: true)
        }
        return [
            JunkRoot(url: sub("Library/Caches"),
                     kind: .userCache, perBundleSubdirs: true),
            JunkRoot(url: sub("Library/Logs"),
                     kind: .log, perBundleSubdirs: false),
            JunkRoot(url: sub("Library/Developer/Xcode/DerivedData"),
                     kind: .devJunk, perBundleSubdirs: false),
            JunkRoot(url: sub(".npm/_cacache"),
                     kind: .devJunk, perBundleSubdirs: false),
            JunkRoot(url: sub("Library/Caches/org.swift.swiftpm"),
                     kind: .devJunk, perBundleSubdirs: false),
            JunkRoot(url: sub("Library/Caches/CocoaPods"),
                     kind: .devJunk, perBundleSubdirs: false),
            JunkRoot(url: sub(".gradle/caches"),
                     kind: .devJunk, perBundleSubdirs: false),
        ]
    }

    public func scan() throws -> [ScanItem] {
        var items: [ScanItem] = []
        for root in roots {
            guard isDirectory(root.url) else { continue }
            if root.perBundleSubdirs {
                items.append(contentsOf: try scanPerBundle(root))
            } else if let item = try aggregatedItem(at: root.url, kind: root.kind) {
                items.append(item)
            }
        }
        return items
    }

    // MARK: - Internals

    private func scanPerBundle(_ root: JunkRoot) throws -> [ScanItem] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: root.url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])) ?? []
        var items: [ScanItem] = []
        for entry in entries {
            guard isDirectory(entry) else { continue }
            let name = entry.lastPathComponent
            guard looksLikeBundleID(name) else { continue }
            if isRunning(name) { continue }
            if let item = try aggregatedItem(at: entry, kind: root.kind) {
                items.append(item)
            }
        }
        return items
    }

    private func aggregatedItem(at url: URL, kind: ItemKind) throws -> ScanItem? {
        guard let snapshot = probe.snapshot(of: url) else { return nil }
        let sizes = try scanner.aggregateSize(url)
        return ScanItem(
            id: UUID(),
            url: url,
            logicalSize: sizes.logical,
            allocatedSize: sizes.allocated,
            kind: kind,
            snapshot: snapshot,
            isAutoSelected: true,
            evidence: nil
        )
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Returns true if `name` looks like a bundle identifier (e.g. com.apple.Finder).
    /// Requires at least two dot-separated components each containing only
    /// alphanumerics, hyphens, or underscores.
    private func looksLikeBundleID(_ name: String) -> Bool {
        guard name.contains(".") else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        for part in parts {
            if part.isEmpty { return false }
            if String(part).rangeOfCharacter(from: allowed.inverted) != nil { return false }
        }
        return true
    }
}
