import Foundation

// MARK: - UninstallPlan

public struct UninstallPlan: Sendable {
    /// The .app bundle itself (kind .appBundle, isAutoSelected = true).
    public let app: ScanItem
    /// The CFBundleIdentifier read from the app's Info.plist.
    public let bundleID: String
    /// Files / directories found in standard ~/Library locations.
    /// Exact-ID matches: isAutoSelected = true, evidence = nil.
    /// Ambiguous (name-only, prefix, group container): isAutoSelected = false, evidence = non-nil.
    public let leftovers: [ScanItem]

    public init(app: ScanItem, bundleID: String, leftovers: [ScanItem]) {
        self.app = app
        self.bundleID = bundleID
        self.leftovers = leftovers
    }
}

// MARK: - Errors

public enum UninstallError: Error, Sendable {
    case infoPlistNotFound(URL)
    case missingBundleID(URL)
    case appBundleUnreadable(URL)
}

// MARK: - AppUninstaller

public struct AppUninstaller {
    private let scanner: Scanner
    private let home: URL
    private let probe: any StatProbing

    public init(scanner: Scanner, home: URL) {
        self.scanner = scanner
        self.home = home
        self.probe = DefaultStatProbe()
    }

    /// Reads the CFBundleIdentifier from Info.plist, scans standard ~/Library
    /// directories for leftover files / directories, and classifies each one.
    public func plan(for appURL: URL) throws -> UninstallPlan {
        let bundleID = try Self.readBundleID(appURL)
        let displayName = appURL.deletingPathExtension().lastPathComponent

        guard let appItem = makeItem(url: appURL, kind: .appBundle, isAutoSelected: true, evidence: nil) else {
            throw UninstallError.appBundleUnreadable(appURL)
        }

        var leftovers: [ScanItem] = []
        let fm = FileManager.default

        for searchDir in Self.searchDirs(home: home) {
            guard let entries = try? fm.contentsOfDirectory(
                at: searchDir.url,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }

            for entry in entries {
                let name = entry.lastPathComponent
                guard let verdict = classify(
                    name: name,
                    bundleID: bundleID,
                    displayName: displayName,
                    isGroupContainer: searchDir.isGroupContainer
                ) else { continue }

                if let item = makeItem(
                    url: entry,
                    kind: .appLeftover,
                    isAutoSelected: verdict.isAutoSelected,
                    evidence: verdict.evidence
                ) {
                    leftovers.append(item)
                }
            }
        }

        return UninstallPlan(app: appItem, bundleID: bundleID, leftovers: leftovers)
    }

    // MARK: - Classification

    /// Returns nil when the entry is unrelated to this app.
    private func classify(
        name: String,
        bundleID: String,
        displayName: String,
        isGroupContainer: Bool
    ) -> (isAutoSelected: Bool, evidence: String?)? {
        if isGroupContainer {
            // Group containers are shared; only flag when the bundleID appears in the name.
            if name == bundleID || name.contains(bundleID) {
                return (false, "shared group container '\(name)' — may be used by multiple apps")
            }
            return nil
        }

        // ── EXACT matches (safe to auto-select) ──────────────────────────────
        // 1. Entry name equals bundleID exactly (e.g. a directory named "com.acme.foo").
        // 2. Entry name equals "<bundleID>.plist" (preference file).
        if name == bundleID || name == "\(bundleID).plist" {
            return (true, nil)
        }

        // ── AMBIGUOUS matches (must NOT be auto-selected) ────────────────────
        // 3. Display-name-only match (e.g. "Foo") — could belong to a different vendor.
        if name == displayName {
            return (false, "matches app display name '\(displayName)' but not the bundle identifier — may belong to another app")
        }

        // 4. Bundle identifier PREFIX match: bundleID is a strict prefix of name
        //    (e.g. "com.acme.foo" is a prefix of "com.acme.foobar").
        //    SAFETY-CRITICAL: this must use a component boundary check so that
        //    "com.acme.foo" does NOT accidentally auto-select "com.acme.foobar".
        if name.hasPrefix(bundleID) && name.count > bundleID.count {
            return (false, "bundle identifier prefix match — '\(name)' shares the prefix '\(bundleID)' but may belong to a different app")
        }

        return nil
    }

    // MARK: - Helpers

    private func makeItem(
        url: URL,
        kind: ItemKind,
        isAutoSelected: Bool,
        evidence: String?
    ) -> ScanItem? {
        guard let snapshot = probe.snapshot(of: url) else { return nil }
        let sizes = (try? scanner.aggregateSize(url)) ?? (logical: 0, allocated: 0)
        return ScanItem(
            id: UUID(),
            url: url,
            logicalSize: sizes.logical,
            allocatedSize: sizes.allocated,
            kind: kind,
            snapshot: snapshot,
            isAutoSelected: isAutoSelected,
            evidence: evidence
        )
    }

    // MARK: - Standard leftover search directories

    private struct SearchDir {
        let url: URL
        let isGroupContainer: Bool
    }

    private static func searchDirs(home: URL) -> [SearchDir] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let standard: [String] = [
            "Caches",
            "Preferences",
            "Application Support",
            "Containers",
            "Saved Application State",
            "Logs",
            "HTTPStorages",
            "LaunchAgents",
        ]
        var dirs: [SearchDir] = standard.map {
            SearchDir(url: library.appendingPathComponent($0, isDirectory: true), isGroupContainer: false)
        }
        dirs.append(SearchDir(
            url: library.appendingPathComponent("Group Containers", isDirectory: true),
            isGroupContainer: true
        ))
        return dirs
    }

    // MARK: - Info.plist parsing

    static func readBundleID(_ appURL: URL) throws -> String {
        let plistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")

        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw UninstallError.infoPlistNotFound(appURL)
        }

        let data = try Data(contentsOf: plistURL)
        let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )

        guard
            let dict = object as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            !bundleID.isEmpty
        else {
            throw UninstallError.missingBundleID(appURL)
        }

        return bundleID
    }
}
