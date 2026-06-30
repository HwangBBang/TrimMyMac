// swift-tools-version: 6.0
// Tests use Swift Testing. On a CommandLineTools-only machine, Testing.framework
// is not on the default search path, so the test target needs explicit -F/-rpath
// flags pointing at the CLT framework dir (and `./scripts/test.sh` passes the same
// flags to the generated test runner). On a full-Xcode toolchain (e.g. CI's
// macos-26 runner) those paths don't exist and aren't needed, so the flags below
// are added ONLY when the CLT Testing.framework is actually present.
import PackageDescription
import Foundation

let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltUsrLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let useCLTTestingFlags = FileManager.default.fileExists(atPath: "\(cltFrameworks)/Testing.framework")

var testSwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]
var testLinkerSettings: [LinkerSetting] = []
if useCLTTestingFlags {
    testSwiftSettings.append(
        .unsafeFlags(["-F", cltFrameworks], .when(platforms: [.macOS]))
    )
    testLinkerSettings.append(
        .unsafeFlags(
            [
                "-F", cltFrameworks,
                "-framework", "Testing",
                // Runtime rpath for Testing.framework itself.
                "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                // Runtime rpath for lib_TestingInterop.dylib (transitive dep of Testing).
                "-Xlinker", "-rpath", "-Xlinker", cltUsrLib
            ],
            .when(platforms: [.macOS])
        )
    )
}

let package = Package(
    name: "TrimMyMac",
    platforms: [
        // macOS 26 (Tahoe). The string form is required because the
        // toolchain may not yet expose a `.v26` enum case.
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "TrimMyMacApp",
            dependencies: [
                "TrimCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                // Embedded Sparkle.framework is resolved at runtime from
                // Contents/Frameworks (build-app.sh copies it there); SPM links @rpath.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .target(
            name: "TrimCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "TrimCoreTests",
            dependencies: ["TrimCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        )
    ]
)
