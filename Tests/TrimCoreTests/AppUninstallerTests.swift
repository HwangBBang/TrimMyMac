import Testing
import Foundation
@testable import TrimCore

@Suite("AppUninstaller")
struct AppUninstallerTests {

    // MARK: - Helpers

    /// Creates a temporary directory tree:
    ///   <base>/home/                     (fake home)
    ///   <base>/Applications/Foo.app/     (fake .app with CFBundleIdentifier = com.acme.foo)
    ///   <home>/Library/Preferences/com.acme.foo.plist        (exact .plist → auto)
    ///   <home>/Library/Application Support/com.acme.foo/     (exact dir → auto)
    ///   <home>/Library/Caches/com.acme.foobar/               (prefix-only → NOT auto + evidence)
    private func makeFixture() throws -> (home: URL, fooApp: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppUninstallerTests-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let fm = FileManager.default

        // fake Foo.app with Info.plist
        let fooApp = base
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Foo.app", isDirectory: true)
        let contents = fooApp.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let infoPlist = contents.appendingPathComponent("Info.plist")
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.acme.foo</string>
        </dict>
        </plist>
        """
        try plistXML.write(to: infoPlist, atomically: true, encoding: .utf8)

        let library = home.appendingPathComponent("Library", isDirectory: true)

        // exact .plist match → auto
        let prefs = library.appendingPathComponent("Preferences", isDirectory: true)
        try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: prefs.appendingPathComponent("com.acme.foo.plist"))

        // exact directory match → auto
        let appSupport = library
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.acme.foo", isDirectory: true)
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try Data("y".utf8).write(to: appSupport.appendingPathComponent("state.bin"))

        // prefix-only match (com.acme.foo vs com.acme.foobar) → NOT auto + evidence
        let caches = library
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("com.acme.foobar", isDirectory: true)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try Data("z".utf8).write(to: caches.appendingPathComponent("cache.db"))

        return (home, fooApp)
    }

    // MARK: - Main test

    @Test func planParsesBundleIDAndClassifiesLeftovers() throws {
        let (home, fooApp) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

        let scanner = TrimCore.Scanner(ignore: .default, probe: DefaultStatProbe())
        let uninstaller = AppUninstaller(scanner: scanner, home: home)
        let plan = try uninstaller.plan(for: fooApp)

        // bundleID parsed from Info.plist
        #expect(plan.bundleID == "com.acme.foo")

        // app item
        #expect(plan.app.kind == .appBundle)
        #expect(plan.app.isAutoSelected == true)
        #expect(plan.app.url.lastPathComponent == "Foo.app")

        // three leftovers discovered
        #expect(plan.leftovers.count == 3, "expected 3 leftovers, got \(plan.leftovers.count): \(plan.leftovers.map(\.url.lastPathComponent))")
        for leftover in plan.leftovers {
            #expect(leftover.kind == .appLeftover)
        }

        func leftover(named name: String) throws -> ScanItem {
            let match = plan.leftovers.first { $0.url.lastPathComponent == name }
            return try #require(match, "missing leftover \(name)")
        }

        // exact .plist → auto, no evidence
        let plist = try leftover(named: "com.acme.foo.plist")
        #expect(plist.isAutoSelected == true)
        #expect(plist.evidence == nil)

        // exact directory → auto, no evidence
        let dir = try leftover(named: "com.acme.foo")
        #expect(dir.isAutoSelected == true)
        #expect(dir.evidence == nil)

        // prefix-only → NOT auto, evidence set and non-empty
        let prefix = try leftover(named: "com.acme.foobar")
        #expect(prefix.isAutoSelected == false)
        let evidence = try #require(prefix.evidence, "prefix match must have evidence")
        #expect(!evidence.isEmpty)
    }

    // MARK: - Error handling: missing Info.plist

    @Test func planThrowsWhenInfoPlistMissing() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppUninstallerTests-NoPlist-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: base) }

        // .app with no Info.plist
        let emptyApp = base.appendingPathComponent("Empty.app", isDirectory: true)
        let contents = emptyApp.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)

        let scanner = TrimCore.Scanner(ignore: .default, probe: DefaultStatProbe())
        let uninstaller = AppUninstaller(scanner: scanner, home: home)
        #expect(throws: (any Error).self) {
            _ = try uninstaller.plan(for: emptyApp)
        }
    }

    // MARK: - Safety: group-container component-boundary match

    @Test func groupContainerSubstringFalsePositiveExcluded() throws {
        // com.acme.foobar in Group Containers must NOT be reported for com.acme.foo.
        // The old contains() check would produce a false positive; the component-boundary
        // check (hasPrefix(bundleID + ".") / hasPrefix(bundleID + "-")) must reject it.
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AppUninstallerTests-GC-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: base) }

        // Minimal Foo.app
        let fooApp = base.appendingPathComponent("Foo.app", isDirectory: true)
        let contents = fooApp.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let plistXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.acme.foo</string>
        </dict></plist>
        """
        try plistXML.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        // Group Containers directory with a SIBLING bundleID name (false-positive candidate)
        let groupContainers = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
        let sibling = groupContainers.appendingPathComponent("com.acme.foobar", isDirectory: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        // Also add a legitimate group-container entry (exact match) to confirm it IS included
        let exact = groupContainers.appendingPathComponent("com.acme.foo", isDirectory: true)
        try fm.createDirectory(at: exact, withIntermediateDirectories: true)
        // And one with a dot-suffix (should also be included as ambiguous)
        let dotSuffix = groupContainers.appendingPathComponent("com.acme.foo.shared", isDirectory: true)
        try fm.createDirectory(at: dotSuffix, withIntermediateDirectories: true)

        let scanner = TrimCore.Scanner(ignore: .default, probe: DefaultStatProbe())
        let uninstaller = AppUninstaller(scanner: scanner, home: home)
        let plan = try uninstaller.plan(for: fooApp)

        let names = plan.leftovers.map(\.url.lastPathComponent)

        // com.acme.foobar is a different app — must NOT appear in leftovers
        #expect(
            !names.contains("com.acme.foobar"),
            "com.acme.foobar must NOT be reported as a leftover of com.acme.foo (component-boundary safety)"
        )
        // Exact and dot-suffix group containers belong to com.acme.foo — must appear (ambiguous)
        #expect(names.contains("com.acme.foo"), "exact group-container must be included")
        #expect(names.contains("com.acme.foo.shared"), "dot-suffix group-container must be included")
        for leftover in plan.leftovers where leftover.url.lastPathComponent.hasPrefix("com.acme.foo") {
            #expect(leftover.isAutoSelected == false, "group-container entries are always ambiguous")
            #expect(leftover.evidence != nil, "group-container entries must carry evidence")
        }
    }

    // MARK: - Safety: bundleID prefix boundary

    @Test func prefixMatchIsNotAutoSelected() throws {
        // Validates the critical safety boundary: com.acme.foo must NOT auto-select com.acme.foobar
        let (home, fooApp) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

        let scanner = TrimCore.Scanner(ignore: .default, probe: DefaultStatProbe())
        let uninstaller = AppUninstaller(scanner: scanner, home: home)
        let plan = try uninstaller.plan(for: fooApp)

        let prefixItem = plan.leftovers.first { $0.url.lastPathComponent == "com.acme.foobar" }
        let item = try #require(prefixItem, "com.acme.foobar must appear in leftovers")
        #expect(item.isAutoSelected == false, "prefix-only match must NOT be auto-selected (safety boundary)")
        #expect(item.evidence != nil, "prefix match must carry evidence explaining why it is ambiguous")
    }
}
