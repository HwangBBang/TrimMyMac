import Testing
import Foundation
@testable import TrimCore

@Suite("JunkScanner")
struct JunkScannerTests {

    // MARK: - Helpers

    private func makeTempHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("JunkScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func removeIfExists(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: url)
    }

    private func makeScanner() -> TrimCore.Scanner {
        TrimCore.Scanner(ignore: .default, probe: DefaultStatProbe())
    }

    // MARK: - 1: perBundleSubdirs skips running apps; non-perBundle emits one aggregated item

    @Test func scanPerBundleSkipsRunningAndAggregatesDevJunk() throws {
        let home = try makeTempHome()
        defer { removeIfExists(home) }

        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        try write(100, to: caches.appendingPathComponent("com.acme.App/a.bin"))
        try write(200, to: caches.appendingPathComponent("com.acme.App/b.bin"))  // acme total = 300
        try write(50,  to: caches.appendingPathComponent("com.run.App/c.bin"))   // running -> skipped

        let cacache = home.appendingPathComponent(".npm/_cacache", isDirectory: true)
        try write(123, to: cacache.appendingPathComponent("x.bin"))
        try write(77,  to: cacache.appendingPathComponent("sub/y.bin"))          // devJunk total = 200

        let roots = [
            JunkRoot(url: caches,  kind: .userCache, perBundleSubdirs: true),
            JunkRoot(url: cacache, kind: .devJunk,   perBundleSubdirs: false),
        ]
        let isRunning: RunningCheck = { $0 == "com.run.App" }
        let sut = JunkScanner(roots: roots, scanner: makeScanner(), isRunning: isRunning)

        let items = try sut.scan()

        // com.run.App must be skipped because it is "running"
        #expect(!items.contains { $0.url.lastPathComponent == "com.run.App" },
                "running app bundle must be skipped")

        // com.acme.App present with correct kind/size/isAutoSelected
        let acme = items.first { $0.url.lastPathComponent == "com.acme.App" }
        #expect(acme != nil, "com.acme.App must appear")
        #expect(acme?.kind == .userCache)
        #expect(acme?.logicalSize == 300)
        #expect((acme?.allocatedSize ?? -1) >= (acme?.logicalSize ?? 0))
        #expect(acme?.isAutoSelected == true)

        // Exactly one aggregated devJunk item for _cacache subtree
        let devItems = items.filter { $0.kind == .devJunk }
        #expect(devItems.count == 1, "exactly one aggregated devJunk item")
        let dev = devItems.first
        #expect(dev?.url.lastPathComponent == "_cacache")
        #expect(dev?.logicalSize == 200)
        #expect(dev?.isAutoSelected == true)

        // Total: 1 acme + 1 devJunk = 2
        #expect(items.count == 2)
    }

    // MARK: - 2: non-existent roots are skipped silently (no throw)

    @Test func skipsRootsThatDoNotExist() throws {
        let home = try makeTempHome()
        defer { removeIfExists(home) }

        let missing = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let roots = [JunkRoot(url: missing, kind: .userCache, perBundleSubdirs: true)]
        let sut = JunkScanner(roots: roots, scanner: makeScanner(), isRunning: { _ in false })

        #expect(try sut.scan().count == 0, "missing root must produce no items")
    }

    // MARK: - 3: defaultRoots(home:) shape

    @Test func defaultRootsShape() {
        let home = URL(fileURLWithPath: "/fake/home")
        let roots = JunkScanner.defaultRoots(home: home)

        func root(_ suffix: String) -> JunkRoot? {
            roots.first { $0.url.path == home.appendingPathComponent(suffix).path }
        }

        let caches = root("Library/Caches")
        #expect(caches?.kind == .userCache)
        #expect(caches?.perBundleSubdirs == true)

        #expect(root("Library/Logs")?.kind == .log)
        #expect(root("Library/Logs")?.perBundleSubdirs == false)

        #expect(root("Library/Developer/Xcode/DerivedData")?.kind == .devJunk)
        #expect(root(".npm/_cacache")?.kind == .devJunk)
        #expect(root("Library/Caches/org.swift.swiftpm")?.kind == .devJunk)
        #expect(root("Library/Caches/CocoaPods")?.kind == .devJunk)
        #expect(root(".gradle/caches")?.kind == .devJunk)

        #expect(roots.count == 7)
    }
}
