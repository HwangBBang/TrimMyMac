// swift-tools-version: 6.0
// NOTE: Run tests via `./scripts/test.sh` (or `swift test -Xswiftc -F -Xswiftc
// /Library/Developer/CommandLineTools/Library/Developer/Frameworks`) when using
// CommandLineTools only. Plain `swift test` silently skips Swift Testing because
// the CLT does not expose Testing.framework on the default search path.
import PackageDescription

let package = Package(
    name: "TrimMyMac",
    platforms: [
        // macOS 26 (Tahoe). The string form is required because the
        // toolchain may not yet expose a `.v26` enum case.
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "TrimMyMacApp",
            dependencies: ["TrimCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
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
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // CommandLineTools does not add Testing.framework to compiler/linker
                // search paths automatically; -F + explicit -framework link are required.
                // Xcode.app injects these via its SDK overlay, so this is CLT-only.
                .unsafeFlags(
                    ["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"],
                    .when(platforms: [.macOS])
                )
            ],
            linkerSettings: [
                .unsafeFlags(
                    [
                        "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                        "-framework", "Testing",
                        // Runtime rpath for Testing.framework itself.
                        "-Xlinker", "-rpath",
                        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                        // Runtime rpath for lib_TestingInterop.dylib (transitive dep of Testing).
                        "-Xlinker", "-rpath",
                        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                    ],
                    .when(platforms: [.macOS])
                )
            ]
        )
    ]
)
