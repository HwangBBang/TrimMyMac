# CleanStatus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal macOS menu-bar app that monitors memory/disk and safely cleans junk, duplicate files, and app leftovers — every deletion routed through the Trash (reversible).

**Architecture:** Two-layer Swift Package — a UI-free `CleanCore` engine (metrics, scanning, dedup, uninstall; all deletions funneled through a single `SafeRemover`) and a thin SwiftUI `CleanApp` menu-bar layer (`MenuBarExtra`). Built with Swift Package Manager plus a `build-app.sh` that assembles a **self-signed `.app`** (no Xcode required).

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI `MenuBarExtra`, AppKit (`NSWorkspace`/`NSRunningApplication`), CryptoKit (SHA256), Darwin syscalls (`lstat`, `host_statistics64`, `sysctl`, `getattrlist`), XCTest. macOS 26 (Tahoe), Apple Silicon.

## Global Constraints

- Package name `CleanStatus`; targets: `CleanApp` (executable), `CleanCore` (library), `CleanCoreTests` (tests). Swift language mode **v6**. Platform **macOS 26**.
- **SAFETY — deletions:** ONLY via `SafeRemover` using `FileManager.trashItem` — NEVER `removeItem`. Permanent deletion is never performed (no empty-Trash feature in v1).
- **SAFETY — scope:** home (`~/`) paths only — never touch `/Library` or `/System`.
- **SAFETY — TOCTOU:** re-stat each item immediately before trashing; skip if its `StatSnapshot` changed since scan.
- **SAFETY — duplicates:** exclude hardlinks (same `deviceID`+`fileID`); flag APFS clones (`ATTR_CMNEXT_CLONEID`) as `.cloneSuspected` and never auto-select them.
- **SAFETY — preview:** always show items + total reclaimable bytes before trashing.
- **Memory:** read-only monitor only (`DispatchSource` pressure + `host_statistics64` + `vm.swapusage`). NO `purge`/RAM-clear action button (decision 2).
- **Code signing:** a **named self-signed Code Signing identity** (NOT ad-hoc `-s -`) so TCC / Full Disk Access persists across rebuilds (Codex MUST-1 fix).
- **COMMIT POLICY (user CLAUDE.md):** the USER runs `git commit`. Each task's final step only stages (`git add`) and prints a recommended message — never auto-run `git commit`.
- **Tests:** run with `swift test --filter <Name>`.
- **Build order:** implement tasks in number order. **Task 0 is a spike** — verify the menu-bar app builds+launches before building features on it.

---

### Task 0: SPM scaffold + build-app.sh (self-signed) + empty MenuBarExtra spike

> **SPIKE — do this FIRST.** It de-risks the riskiest assumption of the whole project: that a SwiftUI `MenuBarExtra` app **builds with SwiftPM (no Xcode)** and **actually shows up in the menu bar** when assembled into a `.app` bundle and launched. It also locks in the **self-signed codesign-by-name** approach so that TCC / Full Disk Access grants survive rebuilds. Verification is **MANUAL** (no XCTest for the spike itself); a trivial `CleanCoreTests` smoke target is created so the package + `swift test` pipeline is wired for every later task.

**Web-verified facts used here:**
- `MenuBarExtra("Title", systemImage:) { ... }.menuBarExtraStyle(.window)` is the correct minimal SwiftUI menu-bar scene; **no `NSApplicationDelegateAdaptor` is required** for a plain menu-bar item (Apple `MenuBarExtra` docs; nilcoalescing "Build a macOS menu bar utility in SwiftUI").
- A SwiftUI `@main App` only reliably renders its menu-bar item when run as a **bundled `.app` with an `Info.plist`** launched via `open` — not as a bare `swift run` binary; `LSUIElement=true` makes it menu-bar-only (no Dock icon).
- Self-signed **Code Signing** identity is created in **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate** (Identity Type: *Self Signed Root*, Certificate Type: *Code Signing*) and then referenced by name with `codesign -s "<name>"` (Apple Support `kyca8916`; Apple Code Signing Tasks).
- Signing with a **named identity** (not ad-hoc `-s -`) makes the **Designated Requirement** anchor on `identifier + leaf cert`, which is **stable across rebuilds** even when the cdhash changes — so TCC/FDA persists. Ad-hoc signing bakes the cdhash into the DR, so every rebuild looks like a new app and **loses** FDA.

**Files:**
- Create: `Package.swift`
- Create: `Sources/CleanApp/CleanStatusApp.swift`
- Create: `Sources/CleanCore/CleanCore.swift` (empty marker so the library module compiles)
- Create: `scripts/build-app.sh`
- Create: `scripts/Info.plist.template`
- Create: `docs/codesign-setup.md`
- Test: `Tests/CleanCoreTests/ScaffoldSmokeTests.swift`

**Interfaces:**
- Consumes: none (foundational).
- Produces: the package layout (`CleanStatus` package; `CleanApp` executable target; `CleanCore` library target; `CleanCoreTests` test target; platform macOS 26) and the signed `.app` bundling pipeline that every later task builds on. No public CleanCore signatures from the frozen contract are implemented in this task — `CleanCore` is an empty module here and is filled in by later tasks.

---

- [ ] **Step 1: Create `Package.swift`**

    ```swift
    // swift-tools-version: 6.0
    import PackageDescription

    let package = Package(
        name: "CleanStatus",
        platforms: [
            // macOS 26 (Tahoe). The string form is required because the
            // toolchain may not yet expose a `.v26` enum case.
            .macOS("26.0")
        ],
        targets: [
            .executableTarget(
                name: "CleanApp",
                dependencies: ["CleanCore"],
                linkerSettings: [
                    .linkedFramework("AppKit"),
                    .linkedFramework("SwiftUI")
                ],
                swiftSettings: [
                    .swiftLanguageMode(.v6)
                ]
            ),
            .target(
                name: "CleanCore",
                swiftSettings: [
                    .swiftLanguageMode(.v6)
                ]
            ),
            .testTarget(
                name: "CleanCoreTests",
                dependencies: ["CleanCore"],
                swiftSettings: [
                    .swiftLanguageMode(.v6)
                ]
            )
        ]
    )
    ```

- [ ] **Step 2: Create the empty `CleanCore` module marker**

    `CleanCore` is filled in by later tasks (Models, Scanner, etc.). For the spike it only needs to be a compilable, public-surface-free module so `import CleanCore` works.

    File `Sources/CleanCore/CleanCore.swift`:
    ```swift
    // CleanCore — shared, UI-free library for CleanStatus.
    // Intentionally empty in Task 0. Public types from the frozen contract
    // (Models, StatProbing, Scanner, SafeRemover, etc.) are added by later tasks.
    // An empty Swift source file compiles to a valid (empty) module.
    ```

- [ ] **Step 3: Create the SwiftUI `MenuBarExtra` app**

    The file is named `CleanStatusApp.swift` (NOT `main.swift`) so the `@main` attribute on the `App` is used as the entry point; a top-level `main.swift` would conflict with `@main`.

    File `Sources/CleanApp/CleanStatusApp.swift`:
    ```swift
    import SwiftUI

    @main
    struct CleanStatusApp: App {
        var body: some Scene {
            MenuBarExtra("CleanStatus", systemImage: "sparkles") {
                MenuBarContentView()
            }
            .menuBarExtraStyle(.window)
        }
    }

    struct MenuBarContentView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("CleanStatus")
                    .font(.headline)
                Text("Scaffold spike — menu bar item is live.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                Button("Quit CleanStatus") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 260)
        }
    }
    ```

    > No `NSApplicationDelegateAdaptor` is added — it is not required for a plain `MenuBarExtra`. If a later task needs an `applicationDidFinishLaunching` hook, add it then.

- [ ] **Step 4: Create the `Info.plist` template**

    File `scripts/Info.plist.template` (placeholders `__SHORT_VERSION__` / `__BUILD_VERSION__` are substituted by `build-app.sh`):
    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleDevelopmentRegion</key>
        <string>en</string>
        <key>CFBundleExecutable</key>
        <string>CleanApp</string>
        <key>CFBundleIdentifier</key>
        <string>com.hbh0112.cleanstatus</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>CleanStatus</string>
        <key>CFBundleDisplayName</key>
        <string>CleanStatus</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>__SHORT_VERSION__</string>
        <key>CFBundleVersion</key>
        <string>__BUILD_VERSION__</string>
        <key>LSMinimumSystemVersion</key>
        <string>26.0</string>
        <key>LSUIElement</key>
        <true/>
        <key>NSHumanReadableCopyright</key>
        <string>Personal use.</string>
    </dict>
    </plist>
    ```

- [ ] **Step 5: Document the one-time self-signed identity setup**

    File `docs/codesign-setup.md`:
    ```markdown
    # CleanStatus code-signing identity (one-time, manual)

    CleanStatus is signed with a **named self-signed Code Signing certificate** so
    that the app's Designated Requirement (identifier + leaf cert) stays **stable
    across rebuilds**. This is what lets the Full Disk Access (TCC) grant survive
    `scripts/build-app.sh` runs. Ad-hoc signing (`codesign -s -`) bakes the cdhash
    into the DR, so every rebuild looks like a brand-new app and FDA is lost.

    ## Create the identity (Keychain Access — once)

    1. Open **Keychain Access**.
    2. Menu: **Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…**
    3. Name: **CleanStatus Self-Signed**
       Identity Type: **Self Signed Root**
       Certificate Type: **Code Signing**
       (optionally tick "Let me override defaults" to bump validity to e.g. 3650 days)
    4. Click **Create**, accept, **Done**. The cert + private key land in the
       **login** keychain.

    ## Verify it is visible to codesign

    ```bash
    security find-identity -v -p codesigning
    # Expect a line like:
    #   1) <40-hex> "CleanStatus Self-Signed"
    ```

    ## Avoid repeated keychain-access prompts (optional, once)

    The first `codesign` may prompt "codesign wants to use key ... in your keychain".
    Click **Always Allow**. To pre-authorize non-interactively:

    ```bash
    security set-key-partition-list \
        -S apple-tool:,apple: \
        -s -k "<your-login-keychain-password>" \
        ~/Library/Keychains/login.keychain-db
    ```

    ## How build-app.sh references it

    `scripts/build-app.sh` reads the identity name from `$CODESIGN_IDENTITY`
    (default `"CleanStatus Self-Signed"`) and runs:

    ```
    codesign --force -s "$CODESIGN_IDENTITY" --identifier com.hbh0112.cleanstatus <app>
    ```

    Note: **not** `--deep` (it re-signs nested code and is deprecated) and
    **not** ad-hoc `-s -`.
    ```

- [ ] **Step 6: Create `scripts/build-app.sh`**

    File `scripts/build-app.sh`:
    ```bash
    #!/usr/bin/env bash
    # Build, bundle, sign (named self-signed identity), and install CleanStatus.app.
    set -euo pipefail

    # --- Resolve repo root (script lives in <root>/scripts) ---
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
    cd "${ROOT_DIR}"

    # --- Config ---
    APP_NAME="CleanStatus"
    EXE_NAME="CleanApp"
    BUNDLE_ID="com.hbh0112.cleanstatus"
    SHORT_VERSION="${SHORT_VERSION:-0.1.0}"
    BUILD_VERSION="${BUILD_VERSION:-1}"
    CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-CleanStatus Self-Signed}"
    INSTALL_DIR="/Applications"

    BUILD_DIR="${ROOT_DIR}/.build/bundle"
    APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
    CONTENTS="${APP_BUNDLE}/Contents"
    MACOS_DIR="${CONTENTS}/MacOS"

    # --- 0. Verify the signing identity exists before doing any work ---
    if ! security find-identity -v -p codesigning | grep -q "${CODESIGN_IDENTITY}"; then
        echo "ERROR: code-signing identity '${CODESIGN_IDENTITY}' not found." >&2
        echo "       Create it once via Keychain Access (see docs/codesign-setup.md)" >&2
        echo "       or set CODESIGN_IDENTITY to an existing identity name." >&2
        exit 1
    fi

    # --- 1. Compile release ---
    echo "==> swift build -c release"
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/${EXE_NAME}"
    if [[ ! -x "${BIN_PATH}" ]]; then
        echo "ERROR: built binary not found at ${BIN_PATH}" >&2
        exit 1
    fi

    # --- 2. Assemble the .app bundle ---
    echo "==> assembling ${APP_NAME}.app"
    rm -rf "${APP_BUNDLE}"
    mkdir -p "${MACOS_DIR}"
    cp "${BIN_PATH}" "${MACOS_DIR}/${EXE_NAME}"
    chmod +x "${MACOS_DIR}/${EXE_NAME}"

    # Info.plist from template with version substitution.
    sed -e "s/__SHORT_VERSION__/${SHORT_VERSION}/g" \
        -e "s/__BUILD_VERSION__/${BUILD_VERSION}/g" \
        "${ROOT_DIR}/scripts/Info.plist.template" > "${CONTENTS}/Info.plist"

    # PkgInfo (harmless but conventional).
    printf 'APPL????' > "${CONTENTS}/PkgInfo"

    # --- 3. Sign with the NAMED identity (stable DR for TCC/FDA) ---
    echo "==> codesign with '${CODESIGN_IDENTITY}'"
    codesign --force \
        --sign "${CODESIGN_IDENTITY}" \
        --identifier "${BUNDLE_ID}" \
        --timestamp=none \
        "${APP_BUNDLE}"

    # Confirm signature & print the Designated Requirement (stable across rebuilds).
    codesign --verify --strict --verbose=2 "${APP_BUNDLE}"
    echo "---- Designated Requirement (must stay constant across rebuilds) ----"
    codesign -d --requirements - "${APP_BUNDLE}" 2>&1 || true
    echo "--------------------------------------------------------------------"

    # --- 4. Install to /Applications ---
    echo "==> installing to ${INSTALL_DIR}/${APP_NAME}.app"
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/${APP_NAME}.app"

    echo "==> done: ${INSTALL_DIR}/${APP_NAME}.app (v${SHORT_VERSION} build ${BUILD_VERSION})"
    echo "    launch with: open '${INSTALL_DIR}/${APP_NAME}.app'"
    ```

    Make it executable:
    ```bash
    chmod +x scripts/build-app.sh
    ```

- [ ] **Step 7: Create the scaffold smoke test (wires up `swift test` for later tasks)**

    > This is the only test file in Task 0 and it is intentionally trivial — its job is to prove the `CleanCoreTests` target compiles, links against `CleanCore`, and that `swift test` runs green. The **real** acceptance for this spike is the MANUAL menu-bar check in Step 9.

    File `Tests/CleanCoreTests/ScaffoldSmokeTests.swift`:
    ```swift
    import XCTest
    @testable import CleanCore

    final class ScaffoldSmokeTests: XCTestCase {
        // Proves the package compiles and the test pipeline is wired.
        // CleanCore is an empty module in Task 0; later tasks add real tests.
        func testCleanCoreModuleImportsAndTestPipelineRuns() {
            XCTAssertTrue(true, "CleanCore imported and CleanCoreTests target built")
        }
    }
    ```

- [ ] **Step 8: Verify the build + test pipeline compiles**

    Run:
    ```bash
    swift build && swift test --filter ScaffoldSmokeTests
    ```
    Expected: `swift build` succeeds (both `CleanApp` and `CleanCore` compile); `swift test` reports **1 test passed** for `ScaffoldSmokeTests`. If `swift build` fails on `MenuBarExtra`/`@main`, the SwiftPM-MenuBarExtra assumption is broken — STOP and reassess before any later task.

- [ ] **Step 9: MANUAL spike verification — bundle, install, and confirm the menu bar item**

    Run:
    ```bash
    ./scripts/build-app.sh
    open /Applications/CleanStatus.app
    ```
    **Exact expected observation:**
    1. `build-app.sh` prints `==> done: /Applications/CleanStatus.app ...` with no codesign errors, and `codesign --verify --strict` produces **no output / exit 0**.
    2. After `open`, a **`sparkles` (✨) icon appears in the macOS menu bar** (top-right status area). **No Dock icon and no app-switcher entry appear** (because `LSUIElement=true`).
    3. **Clicking the sparkles icon** opens a small window-style popover showing the heading **"CleanStatus"**, the subtitle **"Scaffold spike — menu bar item is live."**, a divider, and a **"Quit CleanStatus"** button.
    4. Clicking **Quit CleanStatus** (or ⌘Q) removes the menu-bar icon and terminates the app.

    **Codesign-stability spot check** (confirms the TCC-persistence assumption):
    ```bash
    codesign -d --requirements - /Applications/CleanStatus.app 2>&1   # note the line
    ./scripts/build-app.sh                                            # rebuild
    codesign -d --requirements - /Applications/CleanStatus.app 2>&1   # compare
    ```
    Expected: the **Designated Requirement is identical** across the two builds (it references `identifier "com.hbh0112.cleanstatus"` anchored to the `CleanStatus Self-Signed` cert), even though the cdhash changes. This is the property that keeps Full Disk Access granted after rebuilds. (If the DR instead mentioned the cdhash, signing would have been ad-hoc — fix the identity before continuing.)

- [ ] **Step 10: Stage (user commits)**

    ```bash
    git add Package.swift \
            Sources/CleanApp/CleanStatusApp.swift \
            Sources/CleanCore/CleanCore.swift \
            scripts/build-app.sh \
            scripts/Info.plist.template \
            docs/codesign-setup.md \
            Tests/CleanCoreTests/ScaffoldSmokeTests.swift
    # Recommended commit message (USER runs the commit, per policy):
    #   chore(scaffold): SPM package + self-signed build-app.sh + MenuBarExtra spike
    #
    #   - Package.swift: CleanStatus (CleanApp exe + CleanCore lib + CleanCoreTests), macOS 26, Swift 6
    #   - CleanStatusApp: @main MenuBarExtra(sparkles, .window) — verified appears in menu bar
    #   - build-app.sh: swift build -c release -> .app bundle (LSUIElement, com.hbh0112.cleanstatus)
    #     signed by NAMED self-signed identity (--force, no --deep, no ad-hoc) for stable DR / TCC persistence
    #   - docs/codesign-setup.md: one-time Keychain Access identity creation steps
    ```

### Task 1: Models + DefaultStatProbe

**Files:**
- Create: `Sources/CleanCore/Models.swift`
- Create: `Sources/CleanCore/StatProbing.swift`
- Test: `Tests/CleanCoreTests/DefaultStatProbeTests.swift`

**Interfaces:**
- Consumes: none (foundational task — everything else consumes these types)
- Produces:
  ```swift
  public enum ItemKind: String, Sendable {
      case userCache, log, devJunk, duplicate, appLeftover, appBundle
  }
  public struct StatSnapshot: Equatable, Sendable {
      public let size: Int64
      public let mtime: TimeInterval
      public let fileID: UInt64
      public let deviceID: Int32
      public init(size: Int64, mtime: TimeInterval, fileID: UInt64, deviceID: Int32)
  }
  public struct ScanItem: Identifiable, Sendable {
      public let id: UUID
      public let url: URL
      public let logicalSize: Int64
      public let allocatedSize: Int64
      public let kind: ItemKind
      public let snapshot: StatSnapshot
      public var isAutoSelected: Bool
      public var evidence: String?
      public init(id: UUID, url: URL, logicalSize: Int64, allocatedSize: Int64, kind: ItemKind, snapshot: StatSnapshot, isAutoSelected: Bool, evidence: String?)
  }
  public protocol StatProbing: Sendable {
      func snapshot(of url: URL) -> StatSnapshot?
  }
  public struct DefaultStatProbe: StatProbing {
      public init()
      public func snapshot(of url: URL) -> StatSnapshot?
  }
  ```

- [ ] **Step 1: Write the failing test**

    ```swift
    import XCTest
    @testable import CleanCore

    final class DefaultStatProbeTests: XCTestCase {

        private var dir: URL!

        override func setUpWithError() throws {
            dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("DefaultStatProbeTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            if let dir, FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        }

        // 1a: snapshot of a real file has the exact byte size and non-zero ids matching a direct lstat.
        func testSnapshotMatchesDirectLstat() throws {
            let file = dir.appendingPathComponent("payload.bin")
            let payload = Data(repeating: 0xAB, count: 4096)
            try payload.write(to: file)

            let probe = DefaultStatProbe()
            let snap = try XCTUnwrap(probe.snapshot(of: file), "snapshot of an existing file must not be nil")

            XCTAssertEqual(snap.size, 4096, "size must equal the written byte length")
            XCTAssertNotEqual(snap.fileID, 0, "fileID (st_ino) must be non-zero")
            XCTAssertNotEqual(snap.deviceID, 0, "deviceID (st_dev) must be non-zero")

            var st = stat()
            let rc = file.withUnsafeFileSystemRepresentation { ptr -> Int32 in
                guard let ptr else { return -1 }
                return lstat(ptr, &st)
            }
            XCTAssertEqual(rc, 0, "direct lstat must succeed")
            XCTAssertEqual(snap.size, Int64(st.st_size))
            XCTAssertEqual(snap.fileID, UInt64(st.st_ino))
            XCTAssertEqual(snap.deviceID, Int32(st.st_dev))
        }

        // 1b: snapshot of a missing path returns nil.
        func testSnapshotOfMissingPathIsNil() {
            let missing = dir.appendingPathComponent("does-not-exist.bin")
            XCTAssertNil(DefaultStatProbe().snapshot(of: missing))
        }

        // 1c: StatSnapshot Equatable — equal fields compare equal, any differing field compares unequal.
        func testStatSnapshotEquatable() {
            let a = StatSnapshot(size: 10, mtime: 100, fileID: 7, deviceID: 3)
            let b = StatSnapshot(size: 10, mtime: 100, fileID: 7, deviceID: 3)
            XCTAssertEqual(a, b)

            XCTAssertNotEqual(a, StatSnapshot(size: 11, mtime: 100, fileID: 7, deviceID: 3))
            XCTAssertNotEqual(a, StatSnapshot(size: 10, mtime: 101, fileID: 7, deviceID: 3))
            XCTAssertNotEqual(a, StatSnapshot(size: 10, mtime: 100, fileID: 8, deviceID: 3))
            XCTAssertNotEqual(a, StatSnapshot(size: 10, mtime: 100, fileID: 7, deviceID: 4))
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter DefaultStatProbeTests`
    Expected: FAIL — compile error "cannot find 'DefaultStatProbe' in scope" / "cannot find type 'StatSnapshot' in scope" because `Sources/CleanCore/Models.swift` and `Sources/CleanCore/StatProbing.swift` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

    `Sources/CleanCore/Models.swift`:
    ```swift
    import Foundation

    public enum ItemKind: String, Sendable {
        case userCache, log, devJunk, duplicate, appLeftover, appBundle
    }

    public struct StatSnapshot: Equatable, Sendable {
        public let size: Int64        // st_size
        public let mtime: TimeInterval
        public let fileID: UInt64     // st_ino
        public let deviceID: Int32    // st_dev

        public init(size: Int64, mtime: TimeInterval, fileID: UInt64, deviceID: Int32) {
            self.size = size
            self.mtime = mtime
            self.fileID = fileID
            self.deviceID = deviceID
        }
    }

    public struct ScanItem: Identifiable, Sendable {
        public let id: UUID
        public let url: URL
        public let logicalSize: Int64     // sum of st_size for files under url (or st_size if file)
        public let allocatedSize: Int64   // sum of totalFileAllocatedSize
        public let kind: ItemKind
        public let snapshot: StatSnapshot // captured at scan time (of url itself)
        public var isAutoSelected: Bool
        public var evidence: String?      // ambiguous-leftover reason or clone note

        public init(
            id: UUID,
            url: URL,
            logicalSize: Int64,
            allocatedSize: Int64,
            kind: ItemKind,
            snapshot: StatSnapshot,
            isAutoSelected: Bool,
            evidence: String?
        ) {
            self.id = id
            self.url = url
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.kind = kind
            self.snapshot = snapshot
            self.isAutoSelected = isAutoSelected
            self.evidence = evidence
        }
    }
    ```

    `Sources/CleanCore/StatProbing.swift`:
    ```swift
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
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter DefaultStatProbeTests`
    Expected: PASS (3 tests: `testSnapshotMatchesDirectLstat`, `testSnapshotOfMissingPathIsNil`, `testStatSnapshotEquatable`).

- [ ] **Step 5: Stage (user commits)**

    ```bash
    git add Sources/CleanCore/Models.swift \
            Sources/CleanCore/StatProbing.swift \
            Tests/CleanCoreTests/DefaultStatProbeTests.swift

    # Recommended commit message (run yourself):
    # git commit -m "feat(core): add core models and lstat-based DefaultStatProbe
    #
    # - ItemKind, StatSnapshot (Equatable), ScanItem models
    # - StatProbing protocol + DefaultStatProbe via lstat (nil on missing)
    # - Tests: size/fileID/deviceID match direct lstat, missing -> nil, Equatable"
    ```

### Task 2: SafeRemover (the only deletion path)

**Files:**
- Create: `Sources/CleanCore/SafeRemover.swift`
- Test: `Tests/CleanCoreTests/SafeRemoverTests.swift`

**Interfaces:**
- Consumes:
  - `public protocol StatProbing: Sendable { func snapshot(of url: URL) -> StatSnapshot? }`
  - `public struct DefaultStatProbe: StatProbing { public init(); public func snapshot(of url: URL) -> StatSnapshot? }`
  - `public struct StatSnapshot: Equatable, Sendable { public let size: Int64; public let mtime: TimeInterval; public let fileID: UInt64; public let deviceID: Int32; public init(size: Int64, mtime: TimeInterval, fileID: UInt64, deviceID: Int32) }`
  - `public struct ScanItem: Identifiable, Sendable { public let id: UUID; public let url: URL; public let logicalSize: Int64; public let allocatedSize: Int64; public let kind: ItemKind; public let snapshot: StatSnapshot; public var isAutoSelected: Bool; public var evidence: String?; public init(id: UUID, url: URL, logicalSize: Int64, allocatedSize: Int64, kind: ItemKind, snapshot: StatSnapshot, isAutoSelected: Bool, evidence: String?) }`
  - `public enum ItemKind: String, Sendable { case userCache, log, devJunk, duplicate, appLeftover, appBundle }`
- Produces:
  - `public struct SkippedItem: Sendable { public let url: URL; public let reason: String; public init(url: URL, reason: String) }`
  - `public struct FailedItem: Sendable { public let url: URL; public let message: String; public init(url: URL, message: String) }`
  - `public struct TrashOutcome: Sendable { public let trashed: [URL]; public let skipped: [SkippedItem]; public let failed: [FailedItem]; public let reclaimedAllocated: Int64; public init(trashed: [URL], skipped: [SkippedItem], failed: [FailedItem], reclaimedAllocated: Int64) }`
  - `public struct SafeRemover { public init(probe: StatProbing, fileManager: FileManager); public func trash(_ items: [ScanItem]) -> TrashOutcome }`

- [ ] **Step 1a: Write the failing test — unchanged file is trashed**
    ```swift
    import XCTest
    import Foundation
    @testable import CleanCore

    final class SafeRemoverTests: XCTestCase {

        // MARK: - Fixtures

        private var sandbox: URL!

        override func setUpWithError() throws {
            sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("SafeRemoverTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            if let sandbox, FileManager.default.fileExists(atPath: sandbox.path) {
                try FileManager.default.removeItem(at: sandbox)
            }
        }

        /// A StatProbing test double that always returns a fixed (possibly nil) snapshot,
        /// letting us force the "changed since scan" branch deterministically.
        private struct FixedProbe: StatProbing {
            let forced: StatSnapshot?
            func snapshot(of url: URL) -> StatSnapshot? { forced }
        }

        /// Build a ScanItem whose `snapshot` matches the file currently on disk.
        private func liveItem(at url: URL, allocated: Int64, probe: StatProbing) throws -> ScanItem {
            let snap = try XCTUnwrap(probe.snapshot(of: url), "probe must see existing fixture")
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

        func testUnchangedFileIsTrashed() throws {
            let probe = DefaultStatProbe()
            let fileURL = sandbox.appendingPathComponent("victim.txt")
            try Data("delete me".utf8).write(to: fileURL)

            let item = try liveItem(at: fileURL, allocated: 4096, probe: probe)
            let remover = SafeRemover(probe: probe, fileManager: FileManager.default)

            let outcome = remover.trash([item])

            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                           "trashed file must no longer exist at its original path")
            XCTAssertTrue(outcome.trashed.contains(fileURL),
                          "outcome.trashed must contain the original url")
            XCTAssertTrue(outcome.skipped.isEmpty)
            XCTAssertTrue(outcome.failed.isEmpty)
            XCTAssertGreaterThan(outcome.reclaimedAllocated, 0)
            XCTAssertEqual(outcome.reclaimedAllocated, 4096)
        }
    }
    ```

- [ ] **Step 1b: Write the failing test — forged-stale snapshot is skipped**
    ```swift
    extension SafeRemoverTests {
        func testChangedSinceScanIsSkipped() throws {
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

            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                          "a changed item must not be trashed")
            XCTAssertTrue(outcome.trashed.isEmpty)
            XCTAssertTrue(outcome.failed.isEmpty)
            XCTAssertEqual(outcome.skipped.count, 1)
            XCTAssertEqual(outcome.skipped.first?.url, fileURL)
            XCTAssertEqual(outcome.skipped.first?.reason, "changed since scan")
            XCTAssertEqual(outcome.reclaimedAllocated, 0)
        }
    }
    ```

- [ ] **Step 1c: Write the failing test — missing file is handled**
    ```swift
    extension SafeRemoverTests {
        func testMissingFileIsSkipped() throws {
            let missingURL = sandbox.appendingPathComponent("never-existed.txt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))

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
            XCTAssertTrue(outcome.trashed.isEmpty)
            XCTAssertTrue(outcome.failed.isEmpty)
            XCTAssertEqual(outcome.skipped.count, 1)
            XCTAssertEqual(outcome.skipped.first?.url, missingURL)
            XCTAssertEqual(outcome.skipped.first?.reason, "no longer exists")
            XCTAssertEqual(outcome.reclaimedAllocated, 0)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter SafeRemoverTests`
    Expected: FAIL with a compile error — `cannot find 'SafeRemover' in scope` (and `SkippedItem`/`FailedItem`/`TrashOutcome` unresolved) because `Sources/CleanCore/SafeRemover.swift` does not exist yet.

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation

    /// An item that was deliberately not trashed (and why).
    public struct SkippedItem: Sendable {
        public let url: URL
        public let reason: String
        public init(url: URL, reason: String) {
            self.url = url
            self.reason = reason
        }
    }

    /// An item whose trash operation threw.
    public struct FailedItem: Sendable {
        public let url: URL
        public let message: String
        public init(url: URL, message: String) {
            self.url = url
            self.message = message
        }
    }

    /// Result of a batch trash operation.
    public struct TrashOutcome: Sendable {
        public let trashed: [URL]
        public let skipped: [SkippedItem]
        public let failed: [FailedItem]
        public let reclaimedAllocated: Int64
        public init(trashed: [URL], skipped: [SkippedItem], failed: [FailedItem], reclaimedAllocated: Int64) {
            self.trashed = trashed
            self.skipped = skipped
            self.failed = failed
            self.reclaimedAllocated = reclaimedAllocated
        }
    }

    /// The ONLY deletion path in CleanStatus. Re-stats each item immediately before
    /// moving it to the Trash, refusing to touch anything that changed since the scan.
    /// Never calls `FileManager.removeItem` — deletions are recoverable by design.
    public struct SafeRemover {
        private let probe: StatProbing
        private let fileManager: FileManager

        public init(probe: StatProbing, fileManager: FileManager) {
            self.probe = probe
            self.fileManager = fileManager
        }

        public func trash(_ items: [ScanItem]) -> TrashOutcome {
            var trashed: [URL] = []
            var skipped: [SkippedItem] = []
            var failed: [FailedItem] = []
            var reclaimedAllocated: Int64 = 0

            for item in items {
                // Re-stat at the moment of deletion. A nil result means the path is gone.
                guard let current = probe.snapshot(of: item.url) else {
                    skipped.append(SkippedItem(url: item.url, reason: "no longer exists"))
                    continue
                }

                // Refuse to delete anything that drifted from what we showed the user.
                let unchanged = current.size == item.snapshot.size
                    && current.mtime == item.snapshot.mtime
                    && current.fileID == item.snapshot.fileID
                guard unchanged else {
                    skipped.append(SkippedItem(url: item.url, reason: "changed since scan"))
                    continue
                }

                do {
                    try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                    trashed.append(item.url)
                    reclaimedAllocated += item.allocatedSize
                } catch {
                    failed.append(FailedItem(url: item.url, message: error.localizedDescription))
                }
            }

            return TrashOutcome(
                trashed: trashed,
                skipped: skipped,
                failed: failed,
                reclaimedAllocated: reclaimedAllocated
            )
        }
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter SafeRemoverTests`
    Expected: PASS — all of `testUnchangedFileIsTrashed`, `testChangedSinceScanIsSkipped`, and `testMissingFileIsSkipped` succeed.

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/SafeRemover.swift Tests/CleanCoreTests/SafeRemoverTests.swift
    # Recommended commit message (run yourself):
    # feat(core): add SafeRemover — re-stat-guarded trash-only deletion path
    #
    # - trash(_:) re-stats each item via injected StatProbing and skips anything
    #   whose size/mtime/fileID drifted ("changed since scan")
    # - missing paths are skipped ("no longer exists"); trashItem throws -> FailedItem
    # - sums allocatedSize of trashed items into reclaimedAllocated
    # - uses FileManager.trashItem exclusively; never calls removeItem
    ```

### Task 3: IgnoreRules

**Files:**
- Create: `Sources/CleanCore/IgnoreRules.swift`
- Test: `Tests/CleanCoreTests/IgnoreRulesTests.swift`

**Interfaces:**
- Consumes: none (foundational; depends only on Foundation `URL`)
- Produces:
```swift
public struct IgnoreRules: Sendable {
    public init(extraGlobs: [String])
    public static let `default`: IgnoreRules   // node_modules, *.photoslibrary internals, com.apple.* cache dirs, .Trash
    public func shouldIgnore(_ url: URL) -> Bool
}
```

- [ ] **Step 1: Write the failing test**
    ```swift
    import XCTest
    @testable import CleanCore

    final class IgnoreRulesTests: XCTestCase {

        func testDefaultIgnoresNodeModules() {
            let rules = IgnoreRules.default
            let url = URL(fileURLWithPath: "/Users/me/proj/node_modules/left-pad/index.js")
            XCTAssertTrue(rules.shouldIgnore(url))
        }

        func testDefaultIgnoresPhotosLibraryInternals() {
            let rules = IgnoreRules.default
            let url = URL(fileURLWithPath: "/Users/me/Pictures/Foo.photoslibrary/database/Photos.sqlite")
            XCTAssertTrue(rules.shouldIgnore(url))
        }

        func testDefaultIgnoresAppleCacheBundle() {
            let rules = IgnoreRules.default
            let url = URL(fileURLWithPath: "/Users/me/Library/Caches/com.apple.Safari/Cache.db")
            XCTAssertTrue(rules.shouldIgnore(url))
        }

        func testDefaultIgnoresTrash() {
            let rules = IgnoreRules.default
            let url = URL(fileURLWithPath: "/Users/me/.Trash/old.txt")
            XCTAssertTrue(rules.shouldIgnore(url))
        }

        func testDefaultDoesNotIgnoreThirdPartyCacheBundle() {
            let rules = IgnoreRules.default
            let url = URL(fileURLWithPath: "/Users/me/Library/Caches/com.acme.App/Cache.db")
            XCTAssertFalse(rules.shouldIgnore(url))
        }

        func testExtraGlobSuffixMatches() {
            let rules = IgnoreRules(extraGlobs: ["*.tmpcache"])
            let hit = URL(fileURLWithPath: "/Users/me/Documents/build.tmpcache")
            let miss = URL(fileURLWithPath: "/Users/me/Documents/build.swift")
            XCTAssertTrue(rules.shouldIgnore(hit))
            XCTAssertFalse(rules.shouldIgnore(miss))
        }

        func testExtraGlobExactComponentMatches() {
            let rules = IgnoreRules(extraGlobs: ["DerivedData"])
            let hit = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedData/App-abc/Build")
            let miss = URL(fileURLWithPath: "/Users/me/Library/Developer/Xcode/DerivedDataExtra/Build")
            XCTAssertTrue(rules.shouldIgnore(hit))
            XCTAssertFalse(rules.shouldIgnore(miss))
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter IgnoreRulesTests`
    Expected: FAIL — compile error "cannot find 'IgnoreRules' in scope" (type does not exist yet).

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation

    /// Path-based exclusion rules applied during scanning. A path is ignored if any
    /// built-in default rule matches one of its components, or if any `extraGlobs`
    /// entry matches (simple suffix `*.ext`, or an exact component name).
    public struct IgnoreRules: Sendable {

        private let extraGlobs: [String]

        public init(extraGlobs: [String]) {
            self.extraGlobs = extraGlobs
        }

        /// node_modules, *.photoslibrary internals, com.apple.* cache dirs, .Trash
        public static let `default` = IgnoreRules(extraGlobs: [])

        public func shouldIgnore(_ url: URL) -> Bool {
            let components = url.pathComponents
            for component in components {
                if Self.matchesDefault(component) {
                    return true
                }
            }
            for glob in extraGlobs {
                if Self.matches(glob: glob, components: components) {
                    return true
                }
            }
            return false
        }

        // MARK: - Built-in default rules

        private static func matchesDefault(_ component: String) -> Bool {
            // any path component equal to node_modules
            if component == "node_modules" { return true }
            // a component named .Trash
            if component == ".Trash" { return true }
            // any component ending with .photoslibrary (the package and everything inside it)
            if component.hasSuffix(".photoslibrary") { return true }
            // any component starting with com.apple. (Apple-owned cache bundle dir)
            if component.hasPrefix("com.apple.") { return true }
            return false
        }

        // MARK: - extraGlobs

        private static func matches(glob: String, components: [String]) -> Bool {
            if glob.hasPrefix("*") {
                // simple suffix match: "*.ext" -> any component ending in ".ext"
                let suffix = String(glob.dropFirst())
                guard !suffix.isEmpty else { return false }
                return components.contains { $0.hasSuffix(suffix) }
            }
            // exact-component match
            return components.contains(glob)
        }
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter IgnoreRulesTests`
    Expected: PASS (all seven cases green).

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/IgnoreRules.swift Tests/CleanCoreTests/IgnoreRulesTests.swift
    # Recommended commit message (USER runs git commit):
    # feat(core): add IgnoreRules with default macOS exclusions + extraGlobs
    #
    # Ignore node_modules, *.photoslibrary internals, com.apple.* cache bundles,
    # and .Trash by default. extraGlobs supports "*.ext" suffix and exact-component
    # matching. Covered by IgnoreRulesTests.
    ```

### Task 4: Scanner (recursive enumerate + symlink guard + cancellation + aggregateSize)

**Files:**
- Create: `Sources/CleanCore/Scanner.swift`
- Test: `Tests/CleanCoreTests/ScannerTests.swift`

**Interfaces:**
- Consumes:
  - `public struct StatSnapshot: Equatable, Sendable { public let size: Int64; public let mtime: TimeInterval; public let fileID: UInt64; public let deviceID: Int32; ... }`
  - `public protocol StatProbing: Sendable { func snapshot(of url: URL) -> StatSnapshot? }`
  - `public struct DefaultStatProbe: StatProbing { public init() }`
  - `public struct IgnoreRules: Sendable { public static let default: IgnoreRules; public func shouldIgnore(_ url: URL) -> Bool }`
- Produces:
  - `public struct FileEntry: Sendable { public let url: URL; public let snapshot: StatSnapshot; public let logicalSize: Int64; public let allocatedSize: Int64; public let isDirectory: Bool }`
  - `public struct Scanner { public init(ignore: IgnoreRules, probe: StatProbing); public func enumerate(_ root: URL) throws -> [FileEntry]; public func aggregateSize(_ root: URL) throws -> (logical: Int64, allocated: Int64) }`

- [ ] **Step 1: Write the failing test**
    Covers four facets in one compilable test class: (1a) every nested regular file is enumerated; (1b) a `node_modules` subtree is skipped via `IgnoreRules.default`; (1c) a directory that symlinks back to its parent terminates without an infinite loop or duplicate entries; (1d) `aggregateSize` returns the known logical sum with `allocated >= logical`; plus a cancellation facet asserting `CancellationError` is thrown when the enclosing `Task` is cancelled.

    ```swift
    import XCTest
    @testable import CleanCore

    final class ScannerTests: XCTestCase {

        private var root: URL!

        override func setUpWithError() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ScannerTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            if let root, FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
        }

        // Helper: write exactly `count` bytes at `url`.
        private func writeFile(_ url: URL, bytes count: Int) throws {
            var data = Data(count: count)
            for i in 0..<count { data[i] = UInt8(i % 251) }
            try data.write(to: url)
        }

        private func makeScanner() -> Scanner {
            Scanner(ignore: .default, probe: DefaultStatProbe())
        }

        // 1a + 1b: nested files enumerated; node_modules skipped.
        func testEnumerateFindsNestedFilesAndSkipsNodeModules() throws {
            try writeFile(root.appendingPathComponent("a.txt"), bytes: 5)
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try writeFile(sub.appendingPathComponent("b.txt"), bytes: 10)
            try writeFile(sub.appendingPathComponent("c.bin"), bytes: 100)

            let nm = root.appendingPathComponent("node_modules", isDirectory: true)
            try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
            try writeFile(nm.appendingPathComponent("junk.txt"), bytes: 50)

            let entries = try makeScanner().enumerate(root)
            let names = Set(entries.map { $0.url.lastPathComponent })

            XCTAssertEqual(names, ["a.txt", "b.txt", "c.bin"])
            XCTAssertFalse(names.contains("junk.txt"), "node_modules must be skipped")
            XCTAssertTrue(entries.allSatisfy { !$0.isDirectory })
        }

        // 1c: symlink loop back to parent must terminate with no duplicates.
        func testSymlinkLoopTerminates() throws {
            try writeFile(root.appendingPathComponent("a.txt"), bytes: 5)
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try writeFile(sub.appendingPathComponent("b.txt"), bytes: 10)

            // loop -> root (would recurse forever without the visited guard)
            try FileManager.default.createSymbolicLink(
                at: sub.appendingPathComponent("loop"),
                withDestinationURL: root
            )

            let entries = try makeScanner().enumerate(root)
            let names = entries.map { $0.url.lastPathComponent }.sorted()

            XCTAssertEqual(names, ["a.txt", "b.txt"], "loop must not duplicate or hang")
        }

        // 1d: aggregateSize logical equals known sum; allocated >= logical.
        func testAggregateSizeKnownTree() throws {
            try writeFile(root.appendingPathComponent("a.txt"), bytes: 5)
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try writeFile(sub.appendingPathComponent("b.txt"), bytes: 10)
            try writeFile(sub.appendingPathComponent("c.bin"), bytes: 100)

            let nm = root.appendingPathComponent("node_modules", isDirectory: true)
            try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
            try writeFile(nm.appendingPathComponent("junk.txt"), bytes: 50)

            let totals = try makeScanner().aggregateSize(root)
            XCTAssertEqual(totals.logical, 115, "5 + 10 + 100, node_modules excluded")
            XCTAssertGreaterThanOrEqual(totals.allocated, totals.logical,
                                        "allocated may exceed logical due to block rounding")
        }

        // Cancellation: a cancelled Task makes enumerate throw CancellationError.
        func testCancellationThrows() async throws {
            // Build a wide tree so the per-iteration cancellation check is reliably hit.
            for i in 0..<300 {
                try writeFile(root.appendingPathComponent("f\(i).txt"), bytes: 4)
            }
            let scanner = makeScanner()
            let captured = root!
            let task = Task { () throws -> [FileEntry] in
                try scanner.enumerate(captured)
            }
            task.cancel()

            do {
                _ = try await task.value
                XCTFail("expected CancellationError")
            } catch is CancellationError {
                // expected
            } catch {
                XCTFail("expected CancellationError, got \(error)")
            }
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter ScannerTests`
    Expected: FAIL — compile error "cannot find 'Scanner' in scope" / "cannot find type 'FileEntry' in scope" because `Sources/CleanCore/Scanner.swift` does not exist yet.

- [ ] **Step 3: Write minimal implementation**
    Depth-first walk. Each directory is keyed by its real `(deviceID, fileID)` (resolved through symlinks) and recorded in a `visited` set before descending, so any symlink that resolves back to an already-entered directory returns immediately. Only regular files become `FileEntry`s; symlinks and special files are not emitted and ignored paths are pruned at both directory and child level. `Task.isCancelled` is checked at entry and per child.

    ```swift
    import Foundation

    public struct FileEntry: Sendable {
        public let url: URL
        public let snapshot: StatSnapshot
        public let logicalSize: Int64
        public let allocatedSize: Int64
        public let isDirectory: Bool

        public init(url: URL,
                    snapshot: StatSnapshot,
                    logicalSize: Int64,
                    allocatedSize: Int64,
                    isDirectory: Bool) {
            self.url = url
            self.snapshot = snapshot
            self.logicalSize = logicalSize
            self.allocatedSize = allocatedSize
            self.isDirectory = isDirectory
        }
    }

    public struct Scanner {
        private let ignore: IgnoreRules
        private let probe: StatProbing

        public init(ignore: IgnoreRules, probe: StatProbing) {
            self.ignore = ignore
            self.probe = probe
        }

        private static let childKeys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileSizeKey
        ]

        /// Recursively enumerate regular files under `root` (depth-first).
        /// Skips ignored paths and symlink loops. Throws `CancellationError` if cancelled.
        public func enumerate(_ root: URL) throws -> [FileEntry] {
            if Task.isCancelled { throw CancellationError() }

            var results: [FileEntry] = []
            var visited = Set<String>()

            let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if rootValues?.isDirectory == true {
                try walk(root, into: &results, visited: &visited)
            } else if rootValues?.isRegularFile == true,
                      !ignore.shouldIgnore(root),
                      let entry = fileEntry(for: root) {
                results.append(entry)
            }
            return results
        }

        /// Sum logical (st_size) and allocated (totalFileAllocatedSize) over files in a subtree.
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

        private func walk(_ dir: URL,
                          into results: inout [FileEntry],
                          visited: inout Set<String>) throws {
            if Task.isCancelled { throw CancellationError() }
            if ignore.shouldIgnore(dir) { return }

            // Guard symlink loops by the directory's real (device, file) identity.
            let canonical = dir.resolvingSymlinksInPath()
            guard let dirSnap = probe.snapshot(of: canonical) else { return }
            let key = "\(dirSnap.deviceID)-\(dirSnap.fileID)"
            if visited.contains(key) { return }
            visited.insert(key)

            let children: [URL]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: Array(Self.childKeys),
                    options: []
                )
            } catch {
                return
            }

            for child in children {
                if Task.isCancelled { throw CancellationError() }
                if ignore.shouldIgnore(child) { continue }

                let values = try? child.resourceValues(forKeys: Self.childKeys)
                if values?.isDirectory == true {
                    // Recurse; the visited set stops loops via symlinked directories.
                    try walk(child, into: &results, visited: &visited)
                    continue
                }
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                if let entry = fileEntry(for: child, values: values) {
                    results.append(entry)
                }
            }
        }

        private func fileEntry(for url: URL,
                               values: URLResourceValues? = nil) -> FileEntry? {
            guard let snap = probe.snapshot(of: url) else { return nil }
            let resolved = values ?? (try? url.resourceValues(forKeys: Self.childKeys))
            let allocated = Int64(resolved?.totalFileAllocatedSize ?? Int(snap.size))
            return FileEntry(url: url,
                             snapshot: snap,
                             logicalSize: snap.size,
                             allocatedSize: allocated,
                             isDirectory: false)
        }
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter ScannerTests`
    Expected: PASS — all five test methods green (nested enumeration, node_modules skipped, symlink loop terminates, aggregateSize logical == 115 with allocated >= logical, cancellation throws `CancellationError`).

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/Scanner.swift Tests/CleanCoreTests/ScannerTests.swift
    # Recommended commit message (run yourself):
    # git commit -m "feat(core): add Scanner with recursive enumerate, symlink-loop guard, cancellation, aggregateSize"
    ```

### Task 5: MemoryMonitor

**Files:**
- Create: `Sources/CleanCore/MemoryMonitor.swift`
- Test: `Tests/CleanCoreTests/MemoryMonitorTests.swift`

**Interfaces:**
- Consumes: none (foundational; uses only Darwin/Dispatch system APIs)
- Produces:
    ```swift
    public enum MemoryPressure: String, Sendable { case normal, warning, critical }
    public struct MemorySample: Sendable {
        public let total: UInt64
        public let used: UInt64
        public let active: UInt64
        public let inactive: UInt64
        public let wired: UInt64
        public let compressed: UInt64
        public let swapUsed: UInt64
        public let pressure: MemoryPressure
        public init(total: UInt64, used: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, swapUsed: UInt64, pressure: MemoryPressure)
    }
    @MainActor public final class MemoryMonitor: ObservableObject {
        @Published public private(set) var latest: MemorySample?
        public init()
        public func sample() -> MemorySample            // host_statistics64(HOST_VM_INFO64) + sysctlbyname vm.swapusage + hw.memsize
        public func start(onChange: @escaping (MemoryPressure) -> Void)  // DispatchSource.makeMemoryPressureSource(eventMask:[.normal,.warning,.critical])
        public func stop()
    }
    ```

> **Web-verified API facts (June 2026):**
> - `host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), intPtr, &count)` where `intPtr` is a `vm_statistics64_data_t` rebound to `integer_t`, and `count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)`. Returns `KERN_SUCCESS` on success. Page fields are `active_count`, `inactive_count`, `wire_count`, `compressor_page_count` (all `natural_t`/`UInt32`).
> - Page size from `host_page_size(mach_host_self(), &pageSize)` (`vm_size_t`), falling back to the global `vm_page_size`.
> - Total RAM: `sysctlbyname("hw.memsize", ...)` into `UInt64`. Swap: `sysctlbyname("vm.swapusage", ...)` into `xsw_usage`, used bytes = `xsu_used`.
> - `DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue:)`. Inside the event handler read **`source.data`** (NOT `source.mask`) which returns a `DispatchSource.MemoryPressureEvent` describing the current pressure. (Confirmed bug-fix note on the canonical gist: must use `.data`.)

- [ ] **Step 1: Write the failing test**
    ```swift
    import XCTest
    import Dispatch
    @testable import CleanCore

    final class MemoryMonitorTests: XCTestCase {

        // --- DispatchSource memory-pressure-event -> MemoryPressure mapping ---

        func testPressureMappingWarning() {
            XCTAssertEqual(MemoryMonitor.pressure(from: .warning), .warning)
        }

        func testPressureMappingCritical() {
            XCTAssertEqual(MemoryMonitor.pressure(from: .critical), .critical)
        }

        func testPressureMappingNormal() {
            XCTAssertEqual(MemoryMonitor.pressure(from: .normal), .normal)
        }

        func testPressureMappingCriticalDominatesWarning() {
            // A combined event must resolve to the most severe state.
            let combined: DispatchSource.MemoryPressureEvent = [.warning, .critical]
            XCTAssertEqual(MemoryMonitor.pressure(from: combined), .critical)
        }

        // --- page-count-to-bytes math ---

        func testPageCountToBytesWithKnownPageSize() {
            let r = MemoryMonitor.memoryBytes(
                activePages: 100,
                inactivePages: 50,
                wiredPages: 20,
                compressedPages: 10,
                pageSize: 16384)
            XCTAssertEqual(r.active, 100 * 16384)
            XCTAssertEqual(r.inactive, 50 * 16384)
            XCTAssertEqual(r.wired, 20 * 16384)
            XCTAssertEqual(r.compressed, 10 * 16384)
            // "used" follows the Activity-Monitor convention: active + wired + compressed.
            XCTAssertEqual(r.used, (100 + 20 + 10) * 16384)
        }

        func testPageCountToBytesZero() {
            let r = MemoryMonitor.memoryBytes(
                activePages: 0, inactivePages: 0, wiredPages: 0, compressedPages: 0, pageSize: 4096)
            XCTAssertEqual(r.active, 0)
            XCTAssertEqual(r.used, 0)
        }

        // --- smoke: sample() executes the live syscall path and populates latest.
        //     We deliberately do NOT assert on live system magnitudes. ---

        @MainActor
        func testSamplePopulatesLatestWithoutCrashing() {
            let monitor = MemoryMonitor()
            XCTAssertNil(monitor.latest)
            let s = monitor.sample()
            // default pressure before any DispatchSource event is .normal
            XCTAssertEqual(s.pressure, .normal)
            XCTAssertNotNil(monitor.latest)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter MemoryMonitorTests`
    Expected: FAIL — build error "cannot find 'MemoryMonitor' in scope" / "type 'MemoryMonitor' has no member 'pressure'/'memoryBytes'" because `Sources/CleanCore/MemoryMonitor.swift` does not exist yet.

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation
    import Dispatch
    import Darwin

    public enum MemoryPressure: String, Sendable {
        case normal, warning, critical
    }

    public struct MemorySample: Sendable {
        public let total: UInt64
        public let used: UInt64
        public let active: UInt64
        public let inactive: UInt64
        public let wired: UInt64
        public let compressed: UInt64
        public let swapUsed: UInt64
        public let pressure: MemoryPressure
        public init(total: UInt64, used: UInt64, active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, swapUsed: UInt64, pressure: MemoryPressure) {
            self.total = total
            self.used = used
            self.active = active
            self.inactive = inactive
            self.wired = wired
            self.compressed = compressed
            self.swapUsed = swapUsed
            self.pressure = pressure
        }
    }

    @MainActor
    public final class MemoryMonitor: ObservableObject {
        @Published public private(set) var latest: MemorySample?

        private var pressureSource: DispatchSourceMemoryPressure?
        private var onChangeHandler: ((MemoryPressure) -> Void)?
        private var latestPressure: MemoryPressure = .normal
        private let monitorQueue = DispatchQueue(label: "com.cleanstatus.memorymonitor", qos: .utility)

        public init() {}

        // MARK: - Pure, testable helpers (nonisolated so unit tests call them synchronously)

        /// Maps a DispatchSource memory-pressure event to a MemoryPressure.
        /// Most-severe state wins when an event reports more than one bit.
        nonisolated static func pressure(from event: DispatchSource.MemoryPressureEvent) -> MemoryPressure {
            if event.contains(.critical) { return .critical }
            if event.contains(.warning) { return .warning }
            return .normal
        }

        /// Converts raw VM page counts to byte totals for a given page size.
        nonisolated static func memoryBytes(
            activePages: UInt64,
            inactivePages: UInt64,
            wiredPages: UInt64,
            compressedPages: UInt64,
            pageSize: UInt64
        ) -> (active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, used: UInt64) {
            let active = activePages * pageSize
            let inactive = inactivePages * pageSize
            let wired = wiredPages * pageSize
            let compressed = compressedPages * pageSize
            let used = active + wired + compressed
            return (active, inactive, wired, compressed, used)
        }

        // MARK: - Live sampling

        public func sample() -> MemorySample {
            // Page size.
            var rawPageSize: vm_size_t = 0
            if host_page_size(mach_host_self(), &rawPageSize) != KERN_SUCCESS || rawPageSize == 0 {
                rawPageSize = vm_size_t(vm_page_size)
            }
            let pageSize = UInt64(rawPageSize)

            // VM statistics via host_statistics64(HOST_VM_INFO64).
            var vmStat = vm_statistics64_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &vmStat) { ptr -> kern_return_t in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), intPtr, &count)
                }
            }

            let bytes: (active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64, used: UInt64)
            if kr == KERN_SUCCESS {
                bytes = Self.memoryBytes(
                    activePages: UInt64(vmStat.active_count),
                    inactivePages: UInt64(vmStat.inactive_count),
                    wiredPages: UInt64(vmStat.wire_count),
                    compressedPages: UInt64(vmStat.compressor_page_count),
                    pageSize: pageSize)
            } else {
                bytes = (0, 0, 0, 0, 0)
            }

            // Total physical memory.
            var total: UInt64 = 0
            var totalSize = MemoryLayout<UInt64>.size
            _ = sysctlbyname("hw.memsize", &total, &totalSize, nil, 0)

            // Swap usage.
            var swap = xsw_usage()
            var swapSize = MemoryLayout<xsw_usage>.size
            _ = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

            let result = MemorySample(
                total: total,
                used: bytes.used,
                active: bytes.active,
                inactive: bytes.inactive,
                wired: bytes.wired,
                compressed: bytes.compressed,
                swapUsed: swap.xsu_used,
                pressure: latestPressure)
            latest = result
            return result
        }

        // MARK: - Pressure monitoring

        public func start(onChange: @escaping (MemoryPressure) -> Void) {
            stop()
            onChangeHandler = onChange
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: monitorQueue)
            source.setEventHandler { [weak self, weak source] in
                guard let source else { return }
                // Read the actual pressure event (NOT .mask) on the source's queue,
                // then hop to the main actor with a Sendable raw value.
                let raw = source.data.rawValue
                Task { @MainActor in
                    self?.handlePressureEvent(DispatchSource.MemoryPressureEvent(rawValue: raw))
                }
            }
            pressureSource = source
            source.resume()
        }

        public func stop() {
            pressureSource?.cancel()
            pressureSource = nil
            onChangeHandler = nil
        }

        private func handlePressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
            let pressure = Self.pressure(from: event)
            latestPressure = pressure
            _ = sample()                 // refreshes @Published latest with the new pressure
            onChangeHandler?(pressure)
        }
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter MemoryMonitorTests`
    Expected: PASS — all mapping and byte-math assertions hold, and `sample()` populates `latest` without crashing.

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/MemoryMonitor.swift Tests/CleanCoreTests/MemoryMonitorTests.swift
    # Recommended commit message (run yourself):
    # feat(core): add MemoryMonitor (host_statistics64 + vm.swapusage + DispatchSource pressure)
    #
    # - sample(): host_statistics64(HOST_VM_INFO64) page counts -> bytes via host_page_size,
    #   total via hw.memsize, swap via vm.swapusage(xsw_usage)
    # - start(onChange:): DispatchSource memory-pressure source ([.normal,.warning,.critical]),
    #   reads source.data, maps to MemoryPressure, updates @Published latest, calls onChange
    # - pure helpers pressure(from:) and memoryBytes(...) unit-tested; no live-value assertions
    ```

### Task 6: DiskMetrics

**Files:**
- Create: `Sources/CleanCore/DiskMetrics.swift`
- Test: `Tests/CleanCoreTests/DiskMetricsTests.swift`

**Interfaces:**
- Consumes: none (foundational — Foundation `URL.resourceValues(forKeys:)` only)
- Produces:
    ```swift
    public struct DiskSample: Sendable {
        public let total: Int64
        public let availableImportant: Int64   // volumeAvailableCapacityForImportantUsageKey
        public init(total: Int64, availableImportant: Int64)
    }
    public struct DiskMetrics {
        public init()
        public func sample(volume: URL) -> DiskSample?
    }
    ```

**Web-verified API facts (Foundation `URLResourceValues`, macOS 26 / Swift 6):**
- `URLResourceKey.volumeTotalCapacityKey` → accessor property `volumeTotalCapacity: Int?` (bytes).
- `URLResourceKey.volumeAvailableCapacityForImportantUsageKey` → accessor property `volumeAvailableCapacityForImportantUsage: Int64?` (bytes available for important resources). Exact spelling confirmed against Apple docs / swiftlang `Foundation/URL.swift`.
- Values are fetched via `url.resourceValues(forKeys: Set<URLResourceKey>) throws -> URLResourceValues`; a missing/bogus path throws (e.g. `NSCocoaErrorDomain` no-such-file), which we map to `nil`.

- [ ] **Step 1: Write the failing test**
    ```swift
    import XCTest
    @testable import CleanCore

    final class DiskMetricsTests: XCTestCase {

        // Root volume always exists and is a real mounted volume.
        func testRootVolumeSampleIsConsistent() {
            let metrics = DiskMetrics()
            guard let sample = metrics.sample(volume: URL(fileURLWithPath: "/")) else {
                XCTFail("expected a DiskSample for the root volume")
                return
            }
            XCTAssertGreaterThan(sample.total, 0, "total capacity must be positive")
            XCTAssertGreaterThanOrEqual(sample.availableImportant, 0, "availableImportant must be non-negative")
            XCTAssertLessThanOrEqual(sample.availableImportant, sample.total,
                                     "availableImportant cannot exceed total capacity")
        }

        func testBogusPathReturnsNil() {
            let metrics = DiskMetrics()
            let bogus = URL(fileURLWithPath: "/this/path/definitely/does/not/exist-\(UUID().uuidString)")
            XCTAssertNil(metrics.sample(volume: bogus), "a non-existent path must return nil")
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter DiskMetricsTests`
    Expected: FAIL — compile error / unresolved identifier `DiskMetrics` and `DiskSample` (types do not exist yet in `CleanCore`).

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation

    public struct DiskSample: Sendable {
        public let total: Int64
        public let availableImportant: Int64   // volumeAvailableCapacityForImportantUsageKey
        public init(total: Int64, availableImportant: Int64) {
            self.total = total
            self.availableImportant = availableImportant
        }
    }

    public struct DiskMetrics {
        public init() {}

        public func sample(volume: URL) -> DiskSample? {
            let keys: Set<URLResourceKey> = [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ]
            guard let values = try? volume.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity,
                  let availableImportant = values.volumeAvailableCapacityForImportantUsage
            else {
                return nil
            }
            return DiskSample(total: Int64(total), availableImportant: availableImportant)
        }
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter DiskMetricsTests`
    Expected: PASS — root volume yields a `DiskSample` with `total > 0`, `0 <= availableImportant <= total`; the bogus path returns `nil`.

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/DiskMetrics.swift Tests/CleanCoreTests/DiskMetricsTests.swift
    # Recommended commit message (user runs `git commit`):
    #   feat(core): add DiskMetrics volume capacity sampling
    #
    #   Reads volumeTotalCapacityKey + volumeAvailableCapacityForImportantUsageKey
    #   via URLResourceValues; returns DiskSample or nil on error.
    ```

### Task 7: RunningApps

**Files:**
- Create: `Sources/CleanCore/RunningApps.swift`
- Test: `Tests/CleanCoreTests/RunningAppsTests.swift`

**Interfaces:**
- Consumes: none
- Produces:
  - `@MainActor public final class RunningApps`
  - `public static let shared: RunningApps`
  - `public func isRunning(bundleID: String) -> Bool   // NSWorkspace.shared.runningApplications`
  - `@discardableResult public func quit(bundleID: String) -> Bool`
  - `public typealias RunningCheck = @Sendable (String) -> Bool   // true if app with bundleID running`
  - (helper, additive) `public func snapshotCheck() -> RunningCheck` — builds a `@Sendable` closure over a frozen snapshot of running bundle IDs, usable off the main actor

- [ ] **Step 1: Write the failing test**
    ```swift
    import XCTest
    @testable import CleanCore

    final class RunningAppsTests: XCTestCase {

        // Finder is always running on a live, logged-in macOS session.
        @MainActor
        func testFinderIsRunning() {
            XCTAssertTrue(
                RunningApps.shared.isRunning(bundleID: "com.apple.finder"),
                "Finder should always be running on a live Mac session"
            )
        }

        @MainActor
        func testFakeBundleIDIsNotRunning() {
            XCTAssertFalse(
                RunningApps.shared.isRunning(bundleID: "com.example.totally.not.real.\(UUID().uuidString)"),
                "A random fake bundle id must not report as running"
            )
        }

        // The snapshot closure must be usable as a plain @Sendable value and
        // still report Finder as running.
        @MainActor
        func testSnapshotRunningCheckSeesFinder() {
            let check: RunningCheck = RunningApps.shared.snapshotCheck()
            XCTAssertTrue(check("com.apple.finder"),
                          "snapshot RunningCheck should report com.apple.finder as running")
            XCTAssertFalse(check("com.example.totally.not.real.\(UUID().uuidString)"),
                           "snapshot RunningCheck must reject a fake bundle id")
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter RunningAppsTests`
    Expected: FAIL — compile error "cannot find 'RunningApps' in scope" / "cannot find type 'RunningCheck' in scope" (the type does not exist yet).

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation
    import AppKit

    /// Closure that answers "is an app with this bundle id running?".
    /// `@Sendable` so a captured snapshot can be passed to core scanners that
    /// run off the main actor.
    public typealias RunningCheck = @Sendable (String) -> Bool

    @MainActor
    public final class RunningApps {

        public static let shared = RunningApps()

        public init() {}

        /// True if any running application advertises this bundle identifier.
        public func isRunning(bundleID: String) -> Bool {
            NSWorkspace.shared.runningApplications.contains { app in
                app.bundleIdentifier == bundleID
            }
        }

        /// Politely terminate every running app matching `bundleID`.
        /// Returns whether at least one match was found.
        @discardableResult
        public func quit(bundleID: String) -> Bool {
            let matches = NSWorkspace.shared.runningApplications.filter { app in
                app.bundleIdentifier == bundleID
            }
            for app in matches {
                app.terminate()
            }
            return !matches.isEmpty
        }

        /// Capture the set of currently running bundle ids and return a
        /// `@Sendable` closure that tests membership against that frozen
        /// snapshot. Safe to call from a non-main actor.
        public func snapshotCheck() -> RunningCheck {
            let running = Set(
                NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
            )
            return { bundleID in running.contains(bundleID) }
        }
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter RunningAppsTests`
    Expected: PASS (run from a normal logged-in GUI session so Finder is alive; not over a pure headless ssh shell without a Window Server session).

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/RunningApps.swift Tests/CleanCoreTests/RunningAppsTests.swift
    # Recommended commit message (run yourself):
    # git commit -m "feat(core): add RunningApps (isRunning/quit) + snapshot RunningCheck"
    ```

### Task 8: JunkScanner

**Files:**
- Create: `Sources/CleanCore/JunkScanner.swift`
- Test: `Tests/CleanCoreTests/JunkScannerTests.swift`

**Interfaces:**
- Consumes:
  - `public struct Scanner { public init(ignore: IgnoreRules, probe: StatProbing); public func aggregateSize(_ root: URL) throws -> (logical: Int64, allocated: Int64) }`
  - `public protocol StatProbing: Sendable { func snapshot(of url: URL) -> StatSnapshot? }` / `public struct DefaultStatProbe: StatProbing { public init() }`
  - `public struct IgnoreRules: Sendable { public static let \`default\`: IgnoreRules }`
  - `public struct StatSnapshot: Equatable, Sendable { public init(size: Int64, mtime: TimeInterval, fileID: UInt64, deviceID: Int32) }`
  - `public struct ScanItem: Identifiable, Sendable { public init(id: UUID, url: URL, logicalSize: Int64, allocatedSize: Int64, kind: ItemKind, snapshot: StatSnapshot, isAutoSelected: Bool, evidence: String?) }`
  - `public enum ItemKind: String, Sendable { case userCache, log, devJunk, duplicate, appLeftover, appBundle }`
  - `public typealias RunningCheck = @Sendable (String) -> Bool`
- Produces:
  - `public struct JunkRoot: Sendable { public let url: URL; public let kind: ItemKind; public let perBundleSubdirs: Bool; public init(url: URL, kind: ItemKind, perBundleSubdirs: Bool) }`
  - `public struct JunkScanner { public init(roots: [JunkRoot], scanner: Scanner, isRunning: @escaping RunningCheck); public static func defaultRoots(home: URL) -> [JunkRoot]; public func scan() throws -> [ScanItem] }`

- [ ] **Step 1: Write the failing test**
    ```swift
    import XCTest
    @testable import CleanCore

    final class JunkScannerTests: XCTestCase {

        private var home: URL!

        override func setUpWithError() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("JunkScannerTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        override func tearDownWithError() throws {
            if let home, FileManager.default.fileExists(atPath: home.path) {
                try FileManager.default.removeItem(at: home)
            }
        }

        private func write(_ bytes: Int, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: bytes).write(to: url)
        }

        func testScanPerBundleSkipsRunningAndAggregatesDevJunk() throws {
            // perBundleSubdirs root: ~/Library/Caches
            let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
            try write(100, to: caches.appendingPathComponent("com.acme.App/a.bin"))
            try write(200, to: caches.appendingPathComponent("com.acme.App/b.bin"))   // acme total = 300
            try write(50,  to: caches.appendingPathComponent("com.run.App/c.bin"))    // running -> skipped

            // non-perBundle devJunk root: ~/.npm/_cacache (one aggregated item)
            let cacache = home.appendingPathComponent(".npm/_cacache", isDirectory: true)
            try write(123, to: cacache.appendingPathComponent("x.bin"))
            try write(77,  to: cacache.appendingPathComponent("sub/y.bin"))           // devJunk total = 200

            let roots = [
                JunkRoot(url: caches, kind: .userCache, perBundleSubdirs: true),
                JunkRoot(url: cacache, kind: .devJunk, perBundleSubdirs: false),
            ]
            let scanner = Scanner(ignore: .default, probe: DefaultStatProbe())
            let isRunning: RunningCheck = { $0 == "com.run.App" }
            let sut = JunkScanner(roots: roots, scanner: scanner, isRunning: isRunning)

            let items = try sut.scan()

            // com.run.App must be skipped because it is "running".
            XCTAssertFalse(items.contains { $0.url.lastPathComponent == "com.run.App" })

            // com.acme.App present, correct kind/size, auto-selected.
            let acme = try XCTUnwrap(items.first { $0.url.lastPathComponent == "com.acme.App" })
            XCTAssertEqual(acme.kind, .userCache)
            XCTAssertEqual(acme.logicalSize, 300)
            XCTAssertGreaterThanOrEqual(acme.allocatedSize, acme.logicalSize)
            XCTAssertTrue(acme.isAutoSelected)

            // Exactly one aggregated devJunk item for the whole _cacache subtree.
            let devItems = items.filter { $0.kind == .devJunk }
            XCTAssertEqual(devItems.count, 1)
            let dev = try XCTUnwrap(devItems.first)
            XCTAssertEqual(dev.url.lastPathComponent, "_cacache")
            XCTAssertEqual(dev.logicalSize, 200)
            XCTAssertTrue(dev.isAutoSelected)

            // Total: 1 acme + 1 devJunk = 2.
            XCTAssertEqual(items.count, 2)
        }

        func testSkipsRootsThatDoNotExist() throws {
            let missing = home.appendingPathComponent("Library/Caches", isDirectory: true)
            let roots = [JunkRoot(url: missing, kind: .userCache, perBundleSubdirs: true)]
            let scanner = Scanner(ignore: .default, probe: DefaultStatProbe())
            let sut = JunkScanner(roots: roots, scanner: scanner, isRunning: { _ in false })
            XCTAssertEqual(try sut.scan().count, 0)
        }

        func testDefaultRootsShape() {
            let roots = JunkScanner.defaultRoots(home: home)
            func root(_ suffix: String) -> JunkRoot? {
                roots.first { $0.url.path == home.appendingPathComponent(suffix).path }
            }
            let caches = root("Library/Caches")
            XCTAssertEqual(caches?.kind, .userCache)
            XCTAssertEqual(caches?.perBundleSubdirs, true)
            XCTAssertEqual(root("Library/Logs")?.kind, .log)
            XCTAssertEqual(root("Library/Logs")?.perBundleSubdirs, false)
            XCTAssertEqual(root("Library/Developer/Xcode/DerivedData")?.kind, .devJunk)
            XCTAssertEqual(root(".npm/_cacache")?.kind, .devJunk)
            XCTAssertEqual(root("Library/Caches/org.swift.swiftpm")?.kind, .devJunk)
            XCTAssertEqual(root("Library/Caches/CocoaPods")?.kind, .devJunk)
            XCTAssertEqual(root(".gradle/caches")?.kind, .devJunk)
            XCTAssertEqual(roots.count, 7)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter JunkScannerTests`
    Expected: FAIL — compilation error "cannot find 'JunkScanner' / 'JunkRoot' in scope" (type not yet defined).

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation

    public struct JunkRoot: Sendable {
        public let url: URL
        public let kind: ItemKind          // .userCache | .log | .devJunk
        public let perBundleSubdirs: Bool  // true for ~/Library/Caches (subdirs named by bundleID)
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
        private let probe: StatProbing
        private let fileManager: FileManager

        public init(roots: [JunkRoot], scanner: Scanner, isRunning: @escaping RunningCheck) {
            self.roots = roots
            self.scanner = scanner
            self.isRunning = isRunning
            self.probe = DefaultStatProbe()
            self.fileManager = FileManager.default
        }

        public static func defaultRoots(home: URL) -> [JunkRoot] {
            func sub(_ path: String) -> URL { home.appendingPathComponent(path, isDirectory: true) }
            return [
                JunkRoot(url: sub("Library/Caches"), kind: .userCache, perBundleSubdirs: true),
                JunkRoot(url: sub("Library/Logs"), kind: .log, perBundleSubdirs: false),
                JunkRoot(url: sub("Library/Developer/Xcode/DerivedData"), kind: .devJunk, perBundleSubdirs: false),
                JunkRoot(url: sub(".npm/_cacache"), kind: .devJunk, perBundleSubdirs: false),
                JunkRoot(url: sub("Library/Caches/org.swift.swiftpm"), kind: .devJunk, perBundleSubdirs: false),
                JunkRoot(url: sub("Library/Caches/CocoaPods"), kind: .devJunk, perBundleSubdirs: false),
                JunkRoot(url: sub(".gradle/caches"), kind: .devJunk, perBundleSubdirs: false),
            ]
        }

        // perBundleSubdirs root: one ScanItem per bundleID subdir (skip if isRunning(name)); else one aggregated ScanItem.
        // isAutoSelected=true. kind from the root.
        public func scan() throws -> [ScanItem] {
            var items: [ScanItem] = []
            for root in roots {
                guard isDirectory(root.url) else { continue }   // skip roots that do not exist
                if root.perBundleSubdirs {
                    items.append(contentsOf: try scanPerBundle(root))
                } else if let item = try aggregatedItem(at: root.url, kind: root.kind) {
                    items.append(item)
                }
            }
            return items
        }

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
                evidence: nil)
        }

        private func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

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
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter JunkScannerTests`
    Expected: PASS

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/JunkScanner.swift Tests/CleanCoreTests/JunkScannerTests.swift
    # Recommended commit message (user runs `git commit`):
    #   feat(CleanCore): add JunkScanner with per-bundle cache + aggregated dev-junk roots
    #
    #   - defaultRoots(home:) maps the 7 standard junk locations to ItemKind
    #   - perBundleSubdirs roots emit one ScanItem per bundle-id subdir, skipping running apps
    #   - non-perBundle roots emit one aggregated ScanItem per subtree; missing roots skipped
    ```

### Task 9: DuplicateFinder (size → hardlink collapse → partial hash → full SHA256 → clone probe)

**Files:**
- Create: `Sources/CleanCore/DuplicateFinder.swift`
- Test: `Tests/CleanCoreTests/DuplicateFinderTests.swift`

**Interfaces:**
- Consumes:
  - `Scanner.init(ignore: IgnoreRules, probe: StatProbing)` / `func enumerate(_ root: URL) throws -> [FileEntry]`
  - `FileEntry { let url: URL; let snapshot: StatSnapshot; let logicalSize: Int64; let allocatedSize: Int64; let isDirectory: Bool }`
  - `StatSnapshot { let size: Int64; let mtime: TimeInterval; let fileID: UInt64; let deviceID: Int32 }`
  - `ScanItem.init(id: UUID, url: URL, logicalSize: Int64, allocatedSize: Int64, kind: ItemKind, snapshot: StatSnapshot, isAutoSelected: Bool, evidence: String?)`, `ItemKind.duplicate`
  - `DefaultStatProbe()` / `StatProbing`, `IgnoreRules.default`
- Produces (verbatim from frozen contract):
  - `public enum DuplicateConfidence: String, Sendable { case exact, cloneSuspected }`
  - `public struct DuplicateGroup: Identifiable, Sendable { public let id: UUID; public let confidence: DuplicateConfidence; public let items: [ScanItem]; public init(id: UUID, confidence: DuplicateConfidence, items: [ScanItem]) }`
  - `public struct DuplicateFinder { public init(scanner: Scanner, probe: StatProbing); public func find(in roots: [URL]) throws -> [DuplicateGroup] }`

**API verification notes (web-verified):**
- `ATTR_CMNEXT_CLONEID` (`0x00000100`, `<sys/attr.h>`) must be placed in `attrlist.forkattr` and requires the `FSOPT_ATTR_CMN_EXTENDED` (`0x00000020`) option passed to `getattrlist(2)`; it returns a `u_int64_t` that uniquely identifies the file's data stream (two APFS clones share the same value). The `getattrlist` output buffer begins with a `u_int32_t` total length, followed by the attribute value on a 4-byte boundary — so the clone id is read with an unaligned load at byte offset 4. (Sources: [getattrlist(2)](https://keith.github.io/xcode-man-pages/getattrlist.2.html), [xnu getattrlist.2](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlist.2))
- `clonefile(const char *src, const char *dst, int flags)` from `<sys/clonefile.h>` creates a copy-on-write clone sharing data extents on the same APFS volume; both files then report the same `ATTR_CMNEXT_CLONEID`. Used only in the test to manufacture a clone. (Source: [Apple APFSCloning sample](https://developer.apple.com/library/archive/samplecode/APFSCloning/Listings/clonefile_main_c.html))

---

- [ ] **Step 1a: Write the failing test — identical content → one exact group, exactly one auto-selected**

```swift
import XCTest
import Darwin
@testable import CleanCore

final class DuplicateFinderTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    private func makeFinder() -> DuplicateFinder {
        let scanner = Scanner(ignore: .default, probe: DefaultStatProbe())
        return DuplicateFinder(scanner: scanner, probe: DefaultStatProbe())
    }

    private func makeDir(_ name: String) throws -> URL {
        let dir = base.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DupFinderTest-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? fm.removeItem(at: base) }
    }

    func testIdenticalContentYieldsOneExactGroupWithOneAutoSelected() throws {
        let dir = try makeDir("identical")
        let content = Data("the quick brown fox jumps over the lazy dog".utf8)
        try content.write(to: dir.appendingPathComponent("a.txt"))
        try content.write(to: dir.appendingPathComponent("b.txt"))

        let groups = try makeFinder().find(in: [dir])

        XCTAssertEqual(groups.count, 1)
        let g = try XCTUnwrap(groups.first)
        XCTAssertEqual(g.confidence, .exact)
        XCTAssertEqual(g.items.count, 2)
        XCTAssertFalse(g.items[0].isAutoSelected, "items[0] is the kept original")
        XCTAssertEqual(g.items.filter { $0.isAutoSelected }.count, 1,
                       "exactly one duplicate auto-selected for an exact group")
    }
}
```

- [ ] **Step 1b: Add the negative test — different content of equal size → no group**

```swift
extension DuplicateFinderTests {
    func testDifferentContentSameSizeYieldsNoGroup() throws {
        let dir = try makeDir("different")
        try Data("AAAA".utf8).write(to: dir.appendingPathComponent("a.txt")) // 4 bytes
        try Data("BBBB".utf8).write(to: dir.appendingPathComponent("b.txt")) // 4 bytes

        let groups = try makeFinder().find(in: [dir])

        XCTAssertTrue(groups.isEmpty, "same size but different content must not group")
    }
}
```

- [ ] **Step 1c: Add the hardlink-collapse test — two hardlinks to one inode are NOT a deletable pair**

```swift
extension DuplicateFinderTests {
    func testHardlinksAreCollapsedAndNotReported() throws {
        let dir = try makeDir("hardlink")
        let src = dir.appendingPathComponent("orig.bin")
        try Data("hardlink content sample payload".utf8).write(to: src)
        let dst = dir.appendingPathComponent("link.bin")

        let rc = src.path.withCString { s in dst.path.withCString { d in link(s, d) } }
        XCTAssertEqual(rc, 0, "link() failed: \(String(cString: strerror(errno)))")

        let groups = try makeFinder().find(in: [dir])

        XCTAssertTrue(groups.isEmpty,
                      "two hardlinks share deviceID+fileID → one physical file → never a deletable pair")
    }
}
```

- [ ] **Step 1d: Add the clone-probe test — APFS clone → cloneSuspected, none auto-selected (auto-skips if volume can't clone; otherwise a MANUAL check)**

```swift
extension DuplicateFinderTests {
    func testApfsCloneIsReportedAsCloneSuspected() throws {
        let dir = try makeDir("clone")
        let src = dir.appendingPathComponent("orig.bin")
        try Data("clone content payload for the apfs clone test".utf8).write(to: src)
        let dst = dir.appendingPathComponent("clone.bin")

        // clonefile(2): UInt32 flags == 0. Skips (documented manual check) if the
        // temp volume is not APFS / cannot clone.
        let rc = src.path.withCString { s in dst.path.withCString { d in clonefile(s, d, 0) } }
        try XCTSkipUnless(rc == 0,
            "clonefile unsupported on this volume — verify cloneSuspected manually: \(String(cString: strerror(errno)))")

        let groups = try makeFinder().find(in: [dir])

        XCTAssertEqual(groups.count, 1)
        let g = try XCTUnwrap(groups.first)
        XCTAssertEqual(g.confidence, .cloneSuspected)
        XCTAssertEqual(g.items.filter { $0.isAutoSelected }.count, 0,
                       "clone-suspected groups auto-select nothing")
        XCTAssertNotNil(g.items[1].evidence, "clone evidence note is set")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter DuplicateFinderTests`
    Expected: FAIL — does not compile / link with `cannot find 'DuplicateFinder' in scope` and `cannot find type 'DuplicateGroup'/'DuplicateConfidence' in scope` (the type does not exist yet).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import CryptoKit
import Darwin

// MARK: - Public contract

public enum DuplicateConfidence: String, Sendable { case exact, cloneSuspected }

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: UUID
    public let confidence: DuplicateConfidence
    public let items: [ScanItem]   // >=2; items[0] kept (isAutoSelected=false); rest isAutoSelected = (confidence==.exact)
    public init(id: UUID, confidence: DuplicateConfidence, items: [ScanItem]) {
        self.id = id
        self.confidence = confidence
        self.items = items
    }
}

public struct DuplicateFinder {
    private let scanner: Scanner
    private let probe: StatProbing

    public init(scanner: Scanner, probe: StatProbing) {
        self.scanner = scanner
        self.probe = probe
    }

    public func find(in roots: [URL]) throws -> [DuplicateGroup] {
        // 1) Enumerate all real files (skip directories and empty files).
        var files: [FileEntry] = []
        for root in roots {
            let entries = try scanner.enumerate(root) // throws CancellationError if cancelled
            files.append(contentsOf: entries.filter { !$0.isDirectory && $0.logicalSize > 0 })
        }

        // 2) Group by logical size.
        var bySize: [Int64: [FileEntry]] = [:]
        for f in files { bySize[f.logicalSize, default: []].append(f) }

        var groups: [DuplicateGroup] = []

        for (_, sizeBucket) in bySize {
            guard sizeBucket.count >= 2 else { continue }

            // 3) Collapse hardlinks: files sharing (deviceID, fileID) are ONE physical file.
            var byInode: [String: FileEntry] = [:]
            for f in sizeBucket {
                let key = "\(f.snapshot.deviceID):\(f.snapshot.fileID)"
                if byInode[key] == nil { byInode[key] = f }
            }
            let physical = Array(byInode.values)
            guard physical.count >= 2 else { continue }

            // 4) Sub-group by partial hash (first 4096 bytes).
            var byPartial: [Data: [FileEntry]] = [:]
            for f in physical {
                guard let ph = Self.partialHash(of: f.url) else { continue }
                byPartial[ph, default: []].append(f)
            }

            for (_, partialBucket) in byPartial {
                guard partialBucket.count >= 2 else { continue }

                // 5) Final-group by full SHA256 (streamed).
                var byFull: [Data: [FileEntry]] = [:]
                for f in partialBucket {
                    guard let fh = Self.fullHash(of: f.url) else { continue }
                    byFull[fh, default: []].append(f)
                }

                for (_, fullBucket) in byFull where fullBucket.count >= 2 {
                    groups.append(makeGroup(fullBucket))
                }
            }
        }

        return groups
    }

    // MARK: - Group assembly

    private func makeGroup(_ entries: [FileEntry]) -> DuplicateGroup {
        // Deterministic order: oldest mtime first is the kept original; tie-break on path.
        let sorted = entries.sorted { lhs, rhs in
            if lhs.snapshot.mtime != rhs.snapshot.mtime { return lhs.snapshot.mtime < rhs.snapshot.mtime }
            return lhs.url.path < rhs.url.path
        }

        // Clone probe: members sharing a (non-zero) clone id are APFS clones.
        let cloneIDs = sorted.map { CloneIDProbe.cloneID(of: $0.url) }
        let nonZero = cloneIDs.compactMap { $0 }.filter { $0 != 0 }
        let cloneSuspected = Set(nonZero).count < nonZero.count
        let confidence: DuplicateConfidence = cloneSuspected ? .cloneSuspected : .exact

        let cloneNote = "APFS clone suspected: members share storage (clone id); trashing a copy will not reclaim disk space."

        var items: [ScanItem] = []
        for (idx, f) in sorted.enumerated() {
            let isOriginal = (idx == 0)
            // items[0] never auto-selected; the rest auto-selected only when exact.
            let auto = !isOriginal && (confidence == .exact)
            let evidence: String? = cloneSuspected ? cloneNote : nil
            items.append(ScanItem(
                id: UUID(),
                url: f.url,
                logicalSize: f.logicalSize,
                allocatedSize: f.allocatedSize,
                kind: .duplicate,
                snapshot: f.snapshot,
                isAutoSelected: auto,
                evidence: evidence
            ))
        }

        return DuplicateGroup(id: UUID(), confidence: confidence, items: items)
    }

    // MARK: - Hashing

    private static let chunkSize = 1 << 20 // 1 MiB streaming chunks

    private static func partialHash(of url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 4096)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: head)
        return Data(hasher.finalize())
    }

    private static func fullHash(of url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? fh.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

// MARK: - APFS clone id probe (getattrlist + ATTR_CMNEXT_CLONEID)

private enum CloneIDProbe {
    /// Returns the APFS clone id (data-stream id) for `url`, or nil if unavailable
    /// (non-APFS volume, missing file, or unsupported attribute).
    static func cloneID(of url: URL) -> UInt64? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // FSOPT_ATTR_CMN_EXTENDED reinterprets `forkattr` as extended common attributes.
        attrList.forkattr = attrgroup_t(ATTR_CMNEXT_CLONEID)

        // Buffer: leading u_int32_t length + the u_int64_t clone id (4-byte aligned) + slack.
        var buffer = [UInt8](repeating: 0, count: 64)
        let path = url.path

        let status = path.withCString { cpath -> Int32 in
            buffer.withUnsafeMutableBytes { raw -> Int32 in
                withUnsafeMutablePointer(to: &attrList) { alp -> Int32 in
                    getattrlist(cpath, alp, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED))
                }
            }
        }
        guard status == 0 else { return nil }

        return buffer.withUnsafeBytes { raw -> UInt64? in
            let len = raw.load(fromByteOffset: 0, as: UInt32.self)
            guard len >= 12 else { return nil } // 4 (length) + 8 (clone id)
            return raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter DuplicateFinderTests`
    Expected: PASS — `testIdenticalContentYieldsOneExactGroupWithOneAutoSelected`, `testDifferentContentSameSizeYieldsNoGroup`, and `testHardlinksAreCollapsedAndNotReported` pass; `testApfsCloneIsReportedAsCloneSuspected` passes on an APFS temp volume (the normal case) or reports SKIPPED with the manual-check note on a non-APFS volume.

- [ ] **Step 5: Stage (user commits)**

```bash
git add Sources/CleanCore/DuplicateFinder.swift Tests/CleanCoreTests/DuplicateFinderTests.swift
# Recommended commit message (USER runs the commit):
# feat(core): DuplicateFinder — size→hardlink-collapse→partial→full SHA256 with APFS clone probe
#
# - Group candidates by logical size, collapse hardlinks (deviceID+fileID) to one
#   physical file so two links to the same inode are never a deletable pair.
# - Confirm duplicates via partial (first 4096B) then streamed full SHA256.
# - Probe ATTR_CMNEXT_CLONEID via getattrlist(FSOPT_ATTR_CMN_EXTENDED): shared clone
#   id → .cloneSuspected, auto-select none, evidence set; otherwise .exact with
#   items[0] kept and the rest auto-selected.
```

### Task 10: AppUninstaller

**Files:**
- Create: `Sources/CleanCore/AppUninstaller.swift`
- Test: `Tests/CleanCoreTests/AppUninstallerTests.swift`

**Interfaces:**
- Consumes:
  - `public struct Scanner { public init(ignore: IgnoreRules, probe: StatProbing); public func aggregateSize(_ root: URL) throws -> (logical: Int64, allocated: Int64) }`
  - `public protocol StatProbing: Sendable { func snapshot(of url: URL) -> StatSnapshot? }`
  - `public struct DefaultStatProbe: StatProbing { public init() }`
  - `public struct IgnoreRules: Sendable { public static let `default`: IgnoreRules }`
  - `public struct ScanItem: Identifiable, Sendable { public init(id: UUID, url: URL, logicalSize: Int64, allocatedSize: Int64, kind: ItemKind, snapshot: StatSnapshot, isAutoSelected: Bool, evidence: String?) }`
  - `public enum ItemKind: String, Sendable { case userCache, log, devJunk, duplicate, appLeftover, appBundle }`
  - `public struct StatSnapshot: Equatable, Sendable`
- Produces (verbatim from contract):
  - `public struct UninstallPlan: Sendable { public let app: ScanItem; public let bundleID: String; public let leftovers: [ScanItem]; public init(app: ScanItem, bundleID: String, leftovers: [ScanItem]) }`
  - `public struct AppUninstaller { public init(scanner: Scanner, home: URL); public func plan(for appURL: URL) throws -> UninstallPlan }`

- [ ] **Step 1: Write the failing test**
    ```swift
    import XCTest
    @testable import CleanCore

    final class AppUninstallerTests: XCTestCase {
        private var home: URL!
        private var fooApp: URL!

        override func setUpWithError() throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("AppUninstallerTests-\(UUID().uuidString)", isDirectory: true)
            home = base.appendingPathComponent("home", isDirectory: true)
            let fm = FileManager.default

            // ---- fake Foo.app with Info.plist (CFBundleIdentifier = com.acme.foo) ----
            fooApp = base.appendingPathComponent("Applications", isDirectory: true)
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

            // ---- seed ~/Library leftovers ----
            let library = home.appendingPathComponent("Library", isDirectory: true)

            // exact .plist match -> auto
            let prefs = library.appendingPathComponent("Preferences", isDirectory: true)
            try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: prefs.appendingPathComponent("com.acme.foo.plist"))

            // exact directory match -> auto
            let appSupport = library
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("com.acme.foo", isDirectory: true)
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
            try Data("y".utf8).write(to: appSupport.appendingPathComponent("state.bin"))

            // prefix-only match (com.acme.foo vs com.acme.foobar) -> NOT auto + evidence
            let caches = library
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("com.acme.foobar", isDirectory: true)
            try fm.createDirectory(at: caches, withIntermediateDirectories: true)
            try Data("z".utf8).write(to: caches.appendingPathComponent("cache.db"))
        }

        override func tearDownWithError() throws {
            if let home {
                let base = home.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: base)
            }
        }

        func testPlanParsesBundleIDAndClassifiesLeftovers() throws {
            let scanner = Scanner(ignore: .default, probe: DefaultStatProbe())
            let uninstaller = AppUninstaller(scanner: scanner, home: home)
            let plan = try uninstaller.plan(for: fooApp)

            // bundleID parsed from Info.plist
            XCTAssertEqual(plan.bundleID, "com.acme.foo")

            // app item
            XCTAssertEqual(plan.app.kind, .appBundle)
            XCTAssertTrue(plan.app.isAutoSelected)
            XCTAssertEqual(plan.app.url.lastPathComponent, "Foo.app")

            // three leftovers discovered
            XCTAssertEqual(plan.leftovers.count, 3)
            for leftover in plan.leftovers {
                XCTAssertEqual(leftover.kind, .appLeftover)
            }

            func leftover(named name: String) throws -> ScanItem {
                let match = plan.leftovers.first { $0.url.lastPathComponent == name }
                return try XCTUnwrap(match, "missing leftover \(name)")
            }

            // exact .plist -> auto, no evidence
            let plist = try leftover(named: "com.acme.foo.plist")
            XCTAssertTrue(plist.isAutoSelected)
            XCTAssertNil(plist.evidence)

            // exact directory -> auto, no evidence
            let dir = try leftover(named: "com.acme.foo")
            XCTAssertTrue(dir.isAutoSelected)
            XCTAssertNil(dir.evidence)

            // prefix-only -> NOT auto, evidence set
            let prefix = try leftover(named: "com.acme.foobar")
            XCTAssertFalse(prefix.isAutoSelected)
            let evidence = try XCTUnwrap(prefix.evidence)
            XCTAssertFalse(evidence.isEmpty)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter AppUninstallerTests`
    Expected: FAIL — compile error "cannot find 'AppUninstaller' in scope" / "cannot find 'UninstallPlan' in scope" because `Sources/CleanCore/AppUninstaller.swift` does not exist yet.

- [ ] **Step 3: Write minimal implementation**
    ```swift
    import Foundation

    public struct UninstallPlan: Sendable {
        public let app: ScanItem          // kind .appBundle, isAutoSelected=true
        public let bundleID: String
        public let leftovers: [ScanItem]  // .appLeftover; exact-id matches auto; ambiguous=false + evidence
        public init(app: ScanItem, bundleID: String, leftovers: [ScanItem]) {
            self.app = app
            self.bundleID = bundleID
            self.leftovers = leftovers
        }
    }

    public struct AppUninstaller {
        private let scanner: Scanner
        private let home: URL
        private let probe: StatProbing

        public init(scanner: Scanner, home: URL) {
            self.scanner = scanner
            self.home = home
            self.probe = DefaultStatProbe()
        }

        // The standard ~/Library directories searched for app leftovers (from the contract).
        static func leftoverDirs(home: URL) -> [URL] {
            let library = home.appendingPathComponent("Library", isDirectory: true)
            let names = [
                "Caches",
                "Preferences",
                "Application Support",
                "Containers",
                "Saved Application State",
                "Logs",
                "HTTPStorages",
                "Group Containers",
                "LaunchAgents",
            ]
            return names.map { library.appendingPathComponent($0, isDirectory: true) }
        }

        public func plan(for appURL: URL) throws -> UninstallPlan {
            let bundleID = try AppUninstaller.readBundleID(appURL)
            let displayName = appURL.deletingPathExtension().lastPathComponent

            guard let appItem = try makeItem(
                url: appURL, kind: .appBundle, isAutoSelected: true, evidence: nil
            ) else {
                throw UninstallError.appNotFound(appURL)
            }

            var leftovers: [ScanItem] = []
            let fm = FileManager.default

            for dir in AppUninstaller.leftoverDirs(home: home) {
                let isGroupContainer = dir.lastPathComponent == "Group Containers"
                guard let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: nil
                ) else { continue }

                for entry in entries {
                    let name = entry.lastPathComponent
                    guard let verdict = classify(
                        name: name,
                        bundleID: bundleID,
                        displayName: displayName,
                        isGroupContainer: isGroupContainer
                    ) else { continue }

                    if let item = try makeItem(
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

        // Returns nil when the entry is unrelated to this app.
        private func classify(
            name: String,
            bundleID: String,
            displayName: String,
            isGroupContainer: Bool
        ) -> (isAutoSelected: Bool, evidence: String?)? {
            if isGroupContainer {
                if name == bundleID || name.contains(bundleID) {
                    return (false, "shared group container — may be used by other apps")
                }
                return nil
            }

            // Exact matches: <bundleID>, <bundleID>.plist, or a directory named <bundleID>.
            if name == bundleID || name == bundleID + ".plist" {
                return (true, nil)
            }

            // App display name only (e.g. "Foo") — could belong to a different vendor's app.
            if name == displayName {
                return (false, "matches app display name '\(displayName)' but not the bundle identifier")
            }

            // Bundle identifier PREFIX only (com.acme.foo matching com.acme.foobar).
            if name.hasPrefix(bundleID) {
                return (false, "bundle identifier prefix match — '\(name)' may belong to a different app")
            }

            return nil
        }

        // MARK: - Helpers

        private func makeItem(
            url: URL,
            kind: ItemKind,
            isAutoSelected: Bool,
            evidence: String?
        ) throws -> ScanItem? {
            guard let snapshot = probe.snapshot(of: url) else { return nil }
            let sizes = try scanner.aggregateSize(url)
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

        static func readBundleID(_ appURL: URL) throws -> String {
            let plistURL = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist")
            let data = try Data(contentsOf: plistURL)
            let object = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
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

    enum UninstallError: Error, Sendable {
        case missingBundleID(URL)
        case appNotFound(URL)
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter AppUninstallerTests`
    Expected: PASS — bundleID parsed as `com.acme.foo`; app item is `.appBundle`/auto; exactly 3 `.appLeftover` items with `com.acme.foo.plist` and `com.acme.foo` auto-selected (no evidence) and `com.acme.foobar` not auto-selected with a non-empty evidence string.

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/AppUninstaller.swift Tests/CleanCoreTests/AppUninstallerTests.swift
    # Recommended commit message (run yourself):
    # feat(CleanCore): add AppUninstaller — parse CFBundleIdentifier and classify ~/Library leftovers (exact->auto, name/prefix/group->evidence)
    ```

### Task 11: MenuBarView — live monitor + memory info card

**Files:**
- Create: `Sources/CleanCore/Formatting.swift`
- Create: `Sources/CleanApp/MenuBarView.swift`
- Update: `Sources/CleanApp/CleanStatusApp.swift`
- Test: `Tests/CleanCoreTests/FormattingTests.swift`

**Interfaces:**
- Consumes (verbatim from FROZEN CONTRACT):
  - `public enum MemoryPressure: String, Sendable { case normal, warning, critical }`
  - `public struct MemorySample: Sendable { public let total: UInt64; public let used: UInt64; public let active: UInt64; public let inactive: UInt64; public let wired: UInt64; public let compressed: UInt64; public let swapUsed: UInt64; public let pressure: MemoryPressure }`
  - `@MainActor public final class MemoryMonitor: ObservableObject { @Published public private(set) var latest: MemorySample?; public init(); public func sample() -> MemorySample; public func start(onChange: @escaping (MemoryPressure) -> Void); public func stop() }`
  - `public struct DiskSample: Sendable { public let total: Int64; public let availableImportant: Int64 }`
  - `public struct DiskMetrics { public init(); public func sample(volume: URL) -> DiskSample? }`
- Produces (new pure helper in CleanCore — not in the frozen contract, additive only):
  - `public func humanReadableBytes(_ bytes: Int64) -> String`
  - `public func humanReadableBytes(_ bytes: UInt64) -> String`
  - `public func memoryUsagePercent(used: UInt64, total: UInt64) -> Int`
  - SwiftUI surface (`MenuBarView`, label view, placeholder sheets) — verified MANUALLY.

> NOTE: This task is mostly UI, so the real automated verification is on the **pure formatting/percent helpers** in `CleanCore`. The SwiftUI shell (`MenuBarView`, `CleanStatusApp`) is verified MANUALLY by building and running. The three Korean buttons (정크 = junk, 중복 = duplicate, 앱 삭제 = app delete) are state toggles that open **placeholder sheets** here; later tasks replace the sheet bodies. Per decision 2 the memory info card is **read-only — NO purge button**.

- [ ] **Step 1: Write the failing test** (pure helpers only)
    ```swift
    // Tests/CleanCoreTests/FormattingTests.swift
    import XCTest
    @testable import CleanCore

    final class FormattingTests: XCTestCase {

        func testBytesUnderOneKilobyteShowsRawBytes() {
            XCTAssertEqual(humanReadableBytes(Int64(0)), "0 B")
            XCTAssertEqual(humanReadableBytes(Int64(1)), "1 B")
            XCTAssertEqual(humanReadableBytes(Int64(1023)), "1023 B")
        }

        func testExactKilobyteHasNoDecimal() {
            // rounding rule: round to 1 decimal place, then drop a trailing ".0"
            XCTAssertEqual(humanReadableBytes(Int64(1024)), "1 KB")
        }

        func testFractionalKilobyteKeepsOneDecimal() {
            XCTAssertEqual(humanReadableBytes(Int64(1536)), "1.5 KB")   // 1536 / 1024 == 1.5
        }

        func testRoundingToOneDecimal() {
            // 1126 / 1024 = 1.0996... -> rounds to 1.1
            XCTAssertEqual(humanReadableBytes(Int64(1126)), "1.1 KB")
            // 1075 / 1024 = 1.0498... -> rounds to 1.0 -> "1 KB"
            XCTAssertEqual(humanReadableBytes(Int64(1075)), "1 KB")
        }

        func testLargerUnitsClimb() {
            XCTAssertEqual(humanReadableBytes(Int64(1024 * 1024)), "1 MB")
            XCTAssertEqual(humanReadableBytes(Int64(1024 * 1024 * 1024)), "1 GB")
            // 1.5 GB
            XCTAssertEqual(humanReadableBytes(Int64(1024 * 1024 * 1024) + Int64(512 * 1024 * 1024)), "1.5 GB")
        }

        func testUnsignedOverloadMatchesSigned() {
            XCTAssertEqual(humanReadableBytes(UInt64(1536)), "1.5 KB")
            XCTAssertEqual(humanReadableBytes(UInt64(1024)), "1 KB")
        }

        func testMemoryUsagePercent() {
            XCTAssertEqual(memoryUsagePercent(used: 0, total: 100), 0)
            XCTAssertEqual(memoryUsagePercent(used: 50, total: 100), 50)
            XCTAssertEqual(memoryUsagePercent(used: 100, total: 100), 100)
            // rounds to nearest int: 1/3 -> 33
            XCTAssertEqual(memoryUsagePercent(used: 1, total: 3), 33)
            // guard against divide-by-zero
            XCTAssertEqual(memoryUsagePercent(used: 10, total: 0), 0)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter FormattingTests`
    Expected: FAIL to **compile** with "cannot find 'humanReadableBytes' in scope" / "cannot find 'memoryUsagePercent' in scope" (the helpers do not exist yet).

- [ ] **Step 3a: Write the pure helpers**
    ```swift
    // Sources/CleanCore/Formatting.swift
    import Foundation

    /// Human-readable byte string with a fixed rounding rule:
    /// values < 1024 are shown as raw bytes ("0 B", "1023 B"); otherwise the value
    /// is divided by 1024 until it is < 1024 (or the largest unit is reached), then
    /// rounded to ONE decimal place. A trailing ".0" is dropped ("1 KB", not "1.0 KB").
    public func humanReadableBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        let negative = bytes < 0
        let magnitude = bytes == Int64.min ? UInt64(Int64.max) + 1 : UInt64(abs(bytes))

        if magnitude < 1024 {
            return "\(negative ? "-" : "")\(magnitude) B"
        }

        var value = Double(magnitude)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        // round to one decimal place
        let rounded = (value * 10).rounded() / 10
        let sign = negative ? "-" : ""
        if rounded == rounded.rounded() {
            return "\(sign)\(Int(rounded)) \(units[unitIndex])"
        } else {
            return "\(sign)" + String(format: "%.1f", rounded) + " \(units[unitIndex])"
        }
    }

    /// Unsigned convenience overload (memory sizes are UInt64 in the contract).
    public func humanReadableBytes(_ bytes: UInt64) -> String {
        let clamped = bytes > UInt64(Int64.max) ? Int64.max : Int64(bytes)
        return humanReadableBytes(clamped)
    }

    /// Memory usage as a whole-number percent, rounded to nearest. Returns 0 if total == 0.
    public func memoryUsagePercent(used: UInt64, total: UInt64) -> Int {
        guard total > 0 else { return 0 }
        let fraction = Double(used) / Double(total)
        return Int((fraction * 100).rounded())
    }
    ```

- [ ] **Step 3b: Write the menu-bar SwiftUI views**
    ```swift
    // Sources/CleanApp/MenuBarView.swift
    import SwiftUI
    import CleanCore

    // MARK: - Pressure presentation

    private extension MemoryPressure {
        var pillColor: Color {
            switch self {
            case .normal:   return .green
            case .warning:  return .yellow
            case .critical: return .red
            }
        }
        var koreanLabel: String {
            switch self {
            case .normal:   return "정상"
            case .warning:  return "주의"
            case .critical: return "위험"
            }
        }
    }

    // MARK: - Menu-bar label (always visible in the status bar)

    /// Compact label shown in the macOS menu bar: "<mem%> · <free disk>".
    /// Owns the sampling timer + pressure source so values stay live even when the
    /// popover window is closed.
    struct MenuBarLabel: View {
        @ObservedObject var memoryMonitor: MemoryMonitor

        @State private var sample: MemorySample?
        @State private var freeDisk: Int64 = 0
        @State private var pressure: MemoryPressure = .normal

        private let disk = DiskMetrics()
        private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: "memorychip")
                if let sample {
                    Text("\(memoryUsagePercent(used: sample.used, total: sample.total))% · \(humanReadableBytes(freeDisk)) free")
                } else {
                    Text("—")
                }
            }
            .onAppear {
                refresh()
                memoryMonitor.start { newPressure in
                    pressure = newPressure
                    refresh()
                }
            }
            .onDisappear { memoryMonitor.stop() }
            .onReceive(tick) { _ in refresh() }
        }

        private func refresh() {
            let s = memoryMonitor.sample()
            sample = s
            pressure = s.pressure
            if let d = disk.sample(volume: URL(fileURLWithPath: "/")) {
                freeDisk = d.availableImportant
            }
        }
    }

    // MARK: - Popover content

    struct MenuBarView: View {
        @ObservedObject var memoryMonitor: MemoryMonitor

        @State private var sample: MemorySample?
        @State private var diskSample: DiskSample?

        // Placeholder panel toggles (later tasks replace the sheet bodies).
        @State private var showJunk = false       // 정크
        @State private var showDuplicates = false  // 중복
        @State private var showAppDelete = false   // 앱 삭제

        private let disk = DiskMetrics()
        private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                memoryInfoCard
                Divider()
                diskRow
                Divider()
                actionButtons
            }
            .padding(16)
            .frame(width: 320)
            .onAppear(perform: refresh)
            .onReceive(tick) { _ in refresh() }
            .onReceive(memoryMonitor.$latest) { latest in
                if let latest { sample = latest }
            }
            .sheet(isPresented: $showJunk) {
                PlaceholderPanel(title: "정크 정리", message: "정크 스캔 패널은 이후 작업에서 연결됩니다.")
            }
            .sheet(isPresented: $showDuplicates) {
                PlaceholderPanel(title: "중복 파일", message: "중복 탐지 패널은 이후 작업에서 연결됩니다.")
            }
            .sheet(isPresented: $showAppDelete) {
                PlaceholderPanel(title: "앱 삭제", message: "앱 제거 패널은 이후 작업에서 연결됩니다.")
            }
        }

        // MARK: Sections

        private var header: some View {
            HStack {
                Text("CleanStatus").font(.headline)
                Spacer()
                if let sample {
                    pressurePill(sample.pressure)
                }
            }
        }

        private func pressurePill(_ pressure: MemoryPressure) -> some View {
            HStack(spacing: 4) {
                Circle().fill(pressure.pillColor).frame(width: 8, height: 8)
                Text(pressure.koreanLabel).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(pressure.pillColor.opacity(0.15), in: Capsule())
        }

        /// Read-only memory info card — NO purge button (decision 2).
        private var memoryInfoCard: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("메모리").font(.subheadline).bold()
                if let sample {
                    infoRow("사용량", "\(humanReadableBytes(sample.used)) / \(humanReadableBytes(sample.total))  (\(memoryUsagePercent(used: sample.used, total: sample.total))%)")
                    ProgressView(value: Double(sample.used), total: Double(max(sample.total, 1)))
                    infoRow("활성", humanReadableBytes(sample.active))
                    infoRow("비활성", humanReadableBytes(sample.inactive))
                    infoRow("와이어드", humanReadableBytes(sample.wired))
                    infoRow("압축됨", humanReadableBytes(sample.compressed))
                    infoRow("스왑 사용", humanReadableBytes(sample.swapUsed))
                } else {
                    Text("측정 중…").foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }

        private var diskRow: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("디스크").font(.subheadline).bold()
                if let diskSample {
                    infoRow("여유 공간", humanReadableBytes(diskSample.availableImportant))
                    infoRow("전체", humanReadableBytes(diskSample.total))
                } else {
                    Text("측정 중…").foregroundStyle(.secondary)
                }
            }
        }

        private var actionButtons: some View {
            HStack(spacing: 8) {
                Button("정크") { showJunk = true }
                Button("중복") { showDuplicates = true }
                Button("앱 삭제") { showAppDelete = true }
                Spacer()
                Button("종료") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(.secondary)
            }
        }

        private func infoRow(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            .font(.callout)
        }

        // MARK: Refresh

        private func refresh() {
            sample = memoryMonitor.sample()
            diskSample = disk.sample(volume: URL(fileURLWithPath: "/"))
        }
    }

    // MARK: - Placeholder sheet (replaced by real panels in later tasks)

    struct PlaceholderPanel: View {
        let title: String
        let message: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.title2).bold()
                Text(message).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 360, height: 180)
        }
    }
    ```

- [ ] **Step 3c: Wire the views into the app entry point**
    ```swift
    // Sources/CleanApp/CleanStatusApp.swift
    import SwiftUI
    import CleanCore

    @main
    struct CleanStatusApp: App {
        @StateObject private var memoryMonitor = MemoryMonitor()

        var body: some Scene {
            MenuBarExtra {
                MenuBarView(memoryMonitor: memoryMonitor)
            } label: {
                MenuBarLabel(memoryMonitor: memoryMonitor)
            }
            .menuBarExtraStyle(.window)
        }
    }
    ```

- [ ] **Step 4a: Run the pure-helper test to verify it passes**
    Run: `swift test --filter FormattingTests`
    Expected: PASS (all assertions; `1024 -> "1 KB"`, `1536 -> "1.5 KB"`, percent rounding).

- [ ] **Step 4b: MANUAL UI verification — build, run, observe**
    Run:
    ```bash
    swift build                       # fast compile check of the SwiftUI target
    scripts/build-app.sh              # produces the signed .app bundle
    open ./build/CleanStatus.app      # adjust path to whatever build-app.sh emits
    ```
    Expected observations (state each must be visible):
    1. A menu-bar item appears showing a memory chip icon plus text like `57% · 312 GB free` (a live percent and a human-readable free-disk figure, NOT "—" after the first second).
    2. The menu-bar text updates on its own roughly every 3 seconds (watch the percent drift); it does not freeze.
    3. Clicking the menu-bar item opens a ~320pt-wide window (`.window` style, not a classic menu).
    4. Top-right shows a **pressure pill**: a colored dot + Korean label — green `정상` under normal load. (To force a change you can run a memory-hungry process; the pill turns yellow `주의` / red `위험` and the dot color follows `MemoryMonitor.start`'s `onChange`.)
    5. The read-only **메모리** card shows 사용량 as `<used> / <total> (NN%)` with a progress bar, plus 활성 / 비활성 / 와이어드 / 압축됨 / 스왑 사용 rows — and has **NO purge/clean button** (decision 2).
    6. The **디스크** section shows 여유 공간 and 전체, both human-readable.
    7. The card values refresh about every 3 seconds while the window is open.
    8. Three buttons 정크 / 중복 / 앱 삭제 each open a placeholder sheet titled accordingly with a 닫기 button that dismisses it; 종료 quits the app.

- [ ] **Step 5: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/Formatting.swift \
            Sources/CleanApp/MenuBarView.swift \
            Sources/CleanApp/CleanStatusApp.swift \
            Tests/CleanCoreTests/FormattingTests.swift
    # Recommended commit message (USER runs `git commit`, not the implementer):
    #
    #   feat(ui): live menu-bar monitor + read-only memory card
    #
    #   - Add humanReadableBytes / memoryUsagePercent pure helpers in CleanCore (XCTest-covered)
    #   - MenuBarView: pressure pill, used/total + swap, free disk, read-only memory card (no purge, decision 2)
    #   - MenuBarLabel shows live mem% and free disk; 3s timer + MemoryMonitor.start drive updates
    #   - 정크 / 중복 / 앱 삭제 buttons open placeholder sheets (wired in later tasks)
    #   - MenuBarExtra(.window) wired in CleanStatusApp
    ```

### Task 12: JunkPanel (scan -> preview -> trash)

**Files:**
- Create: `Sources/CleanCore/SelectionSummary.swift`
- Create: `Sources/CleanApp/Panels/JunkPanel.swift`
- Edit: `Sources/CleanApp/MenuBarView.swift` (wire junk-cleanup button)
- Test: `Tests/CleanCoreTests/SelectionSummaryTests.swift`

**Interfaces:**
- Consumes (from FROZEN CONTRACT):
  - `public struct ScanItem: Identifiable, Sendable { public let id: UUID; public let url: URL; public let logicalSize: Int64; public let allocatedSize: Int64; public let kind: ItemKind; public let snapshot: StatSnapshot; public var isAutoSelected: Bool; public var evidence: String? }`
  - `public enum ItemKind: String, Sendable { case userCache, log, devJunk, duplicate, appLeftover, appBundle }`
  - `public struct Scanner { public init(ignore: IgnoreRules, probe: StatProbing) }`
  - `public struct DefaultStatProbe: StatProbing { public init() }`
  - `public struct IgnoreRules: Sendable { public static let \`default\`: IgnoreRules }`
  - `public struct JunkScanner { public init(roots: [JunkRoot], scanner: Scanner, isRunning: @escaping RunningCheck); public static func defaultRoots(home: URL) -> [JunkRoot]; public func scan() throws -> [ScanItem] }`
  - `public typealias RunningCheck = @Sendable (String) -> Bool`
  - `public struct SafeRemover { public init(probe: StatProbing, fileManager: FileManager); public func trash(_ items: [ScanItem]) -> TrashOutcome }`
  - `public struct TrashOutcome: Sendable { public let trashed: [URL]; public let skipped: [SkippedItem]; public let failed: [FailedItem]; public let reclaimedAllocated: Int64 }`
- Produces (new additive CleanCore helper — does NOT alter any frozen signature):
  - `public struct SelectionSummary: Equatable, Sendable { public let count: Int; public let logicalBytes: Int64; public let allocatedBytes: Int64; public init(count: Int, logicalBytes: Int64, allocatedBytes: Int64) }`
  - `public func selectionSummary(items: [ScanItem]) -> SelectionSummary`
  - SwiftUI view `JunkPanel` in `CleanApp` (UI; verified manually).

---

- [ ] **Step 1: Write the failing test**
    Test the pure, non-UI selection-summary logic extracted into CleanCore. No UI involved — real `ScanItem` fixtures, real assertions.

    ```swift
    // Tests/CleanCoreTests/SelectionSummaryTests.swift
    import XCTest
    @testable import CleanCore

    final class SelectionSummaryTests: XCTestCase {

        private func makeItem(logical: Int64, allocated: Int64, kind: ItemKind = .userCache) -> ScanItem {
            ScanItem(
                id: UUID(),
                url: URL(fileURLWithPath: "/tmp/clean-status-fixture/\(UUID().uuidString)"),
                logicalSize: logical,
                allocatedSize: allocated,
                kind: kind,
                snapshot: StatSnapshot(size: logical, mtime: 0, fileID: 1, deviceID: 1),
                isAutoSelected: true,
                evidence: nil
            )
        }

        func testEmptySelectionIsZero() {
            let summary = selectionSummary(items: [])
            XCTAssertEqual(summary, SelectionSummary(count: 0, logicalBytes: 0, allocatedBytes: 0))
        }

        func testSumsCountAndBothByteTotals() {
            let items = [
                makeItem(logical: 100, allocated: 4096),
                makeItem(logical: 250, allocated: 8192, kind: .log),
                makeItem(logical: 1, allocated: 4096, kind: .devJunk),
            ]
            let summary = selectionSummary(items: items)
            XCTAssertEqual(summary.count, 3)
            XCTAssertEqual(summary.logicalBytes, 351)
            XCTAssertEqual(summary.allocatedBytes, 16384)
        }

        func testSummaryReflectsOnlyPassedItems() {
            // Caller is responsible for filtering to the *selected* subset before calling.
            let all = [
                makeItem(logical: 10, allocated: 4096),
                makeItem(logical: 20, allocated: 4096),
                makeItem(logical: 30, allocated: 4096),
            ]
            let selected = Array(all.prefix(2))
            let summary = selectionSummary(items: selected)
            XCTAssertEqual(summary.count, 2)
            XCTAssertEqual(summary.logicalBytes, 30)
            XCTAssertEqual(summary.allocatedBytes, 8192)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter SelectionSummaryTests`
    Expected: FAIL — compile error / unresolved identifier: `cannot find 'selectionSummary' in scope` and `cannot find type 'SelectionSummary' in scope` (the helper does not exist yet).

- [ ] **Step 3a: Write minimal implementation — the testable CleanCore helper**
    ```swift
    // Sources/CleanCore/SelectionSummary.swift
    import Foundation

    /// Pure, UI-free summary of a set of selected scan items.
    /// The caller passes exactly the items that are currently selected.
    public struct SelectionSummary: Equatable, Sendable {
        public let count: Int
        public let logicalBytes: Int64
        public let allocatedBytes: Int64

        public init(count: Int, logicalBytes: Int64, allocatedBytes: Int64) {
            self.count = count
            self.logicalBytes = logicalBytes
            self.allocatedBytes = allocatedBytes
        }
    }

    /// Sum the count and byte totals of the given (already-filtered) items.
    public func selectionSummary(items: [ScanItem]) -> SelectionSummary {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        for item in items {
            logical &+= item.logicalSize
            allocated &+= item.allocatedSize
        }
        return SelectionSummary(count: items.count, logicalBytes: logical, allocatedBytes: allocated)
    }
    ```

- [ ] **Step 3b: Write minimal implementation — the SwiftUI panel**
    The view-model runs `JunkScanner.scan()` on a cancellable detached background `Task`, and `SafeRemover.trash` likewise off the main actor. Both `JunkScanner` and `SafeRemover` are reconstructed inside the detached closures from `Sendable` building blocks (`IgnoreRules.default`, `DefaultStatProbe`, a capture-free `@Sendable` running-check, and a `Sendable` `home: URL` / `[ScanItem]`), so nothing non-`Sendable` crosses an isolation boundary under Swift 6 strict concurrency.

    ```swift
    // Sources/CleanApp/Panels/JunkPanel.swift
    import SwiftUI
    import AppKit
    import CleanCore

    @MainActor
    final class JunkPanelModel: ObservableObject {
        @Published var items: [ScanItem] = []
        @Published var selectedIDs: Set<UUID> = []
        @Published var isScanning: Bool = false
        @Published var outcome: TrashOutcome?
        @Published var errorMessage: String?

        private let home: URL
        private var scanTask: Task<Void, Never>?

        init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
            self.home = home
        }

        /// Summary of the currently *selected* items (UI-free logic lives in CleanCore).
        var summary: SelectionSummary {
            selectionSummary(items: items.filter { selectedIDs.contains($0.id) })
        }

        var selectedItems: [ScanItem] {
            items.filter { selectedIDs.contains($0.id) }
        }

        func startScan() {
            scanTask?.cancel()
            outcome = nil
            errorMessage = nil
            isScanning = true
            let home = self.home
            scanTask = Task { [weak self] in
                do {
                    let result = try await Task.detached(priority: .userInitiated) { () throws -> [ScanItem] in
                        let probe = DefaultStatProbe()
                        let scanner = Scanner(ignore: .default, probe: probe)
                        let isRunning: RunningCheck = { bundleID in
                            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
                        }
                        let junk = JunkScanner(
                            roots: JunkScanner.defaultRoots(home: home),
                            scanner: scanner,
                            isRunning: isRunning
                        )
                        return try junk.scan()
                    }.value
                    guard let self else { return }
                    self.items = result
                    self.selectedIDs = Set(result.filter { $0.isAutoSelected }.map { $0.id })
                    self.isScanning = false
                } catch is CancellationError {
                    self?.isScanning = false
                } catch {
                    self?.errorMessage = error.localizedDescription
                    self?.isScanning = false
                }
            }
        }

        func cancelScan() {
            scanTask?.cancel()
            isScanning = false
        }

        func trashSelected() {
            let selected = selectedItems
            guard !selected.isEmpty else { return }
            Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { () -> TrashOutcome in
                    let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: FileManager.default)
                    return remover.trash(selected)
                }.value
                guard let self else { return }
                self.outcome = result
                let trashedSet = Set(result.trashed)
                self.items.removeAll { trashedSet.contains($0.url) }
                let remainingIDs = Set(self.items.map { $0.id })
                self.selectedIDs = self.selectedIDs.intersection(remainingIDs)
            }
        }
    }

    struct JunkPanel: View {
        @StateObject private var model = JunkPanelModel()

        private static let byteFormatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.countStyle = .file
            return f
        }()

        private func fmt(_ bytes: Int64) -> String {
            Self.byteFormatter.string(fromByteCount: bytes)
        }

        private var grouped: [(kind: ItemKind, items: [ScanItem])] {
            Dictionary(grouping: model.items, by: { $0.kind })
                .map { (kind: $0.key, items: $0.value) }
                .sorted { $0.kind.rawValue < $1.kind.rawValue }
        }

        private func label(for kind: ItemKind) -> String {
            switch kind {
            case .userCache:   return "User Caches"
            case .log:         return "Logs"
            case .devJunk:     return "Developer Junk"
            case .duplicate:   return "Duplicates"
            case .appLeftover: return "App Leftovers"
            case .appBundle:   return "Applications"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .padding(16)
            .frame(minWidth: 480, minHeight: 420)
        }

        private var header: some View {
            HStack {
                Text("Junk Cleanup").font(.headline)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancelScan() }
                } else {
                    Button("Scan") { model.startScan() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
            if model.items.isEmpty && !model.isScanning {
                Text("No items. Press Scan to look for reclaimable junk.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(grouped, id: \.kind) { section in
                        Section(label(for: section.kind)) {
                            ForEach(section.items) { item in
                                row(item)
                            }
                        }
                    }
                }
            }
        }

        private func row(_ item: ScanItem) -> some View {
            Toggle(isOn: Binding(
                get: { model.selectedIDs.contains(item.id) },
                set: { on in
                    if on { model.selectedIDs.insert(item.id) }
                    else { model.selectedIDs.remove(item.id) }
                }
            )) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.url.lastPathComponent)
                        if let evidence = item.evidence {
                            Text(evidence).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(fmt(item.allocatedSize)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)
        }

        private var footer: some View {
            HStack {
                let summary = model.summary
                Text("\(summary.count) selected · \(fmt(summary.allocatedBytes)) reclaimable")
                    .font(.subheadline)
                Spacer()
                if let outcome = model.outcome {
                    Text("Trashed \(outcome.trashed.count) · skipped \(outcome.skipped.count) · failed \(outcome.failed.count) · freed \(fmt(outcome.reclaimedAllocated))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Move to Trash") { model.trashSelected() }
                    .disabled(model.summary.count == 0 || model.isScanning)
            }
        }
    }
    ```

- [ ] **Step 3c: Wire the junk-cleanup button from MenuBarView**
    Add a `Window` scene keyed `"junk"` and an `openWindow` action behind the existing junk-cleanup button. (`MenuBarView` and the `App` entry point are produced by the menu-bar task; this is the additive wiring.)

    In the app entry point's `body` (the `Scene` builder), register the window:
    ```swift
    // Sources/CleanApp/<AppEntry>.swift  (inside `var body: some Scene { ... }`)
    Window("Junk Cleanup", id: "junk") {
        JunkPanel()
    }
    .windowResizability(.contentSize)
    ```

    In `MenuBarView`, open it from the junk-cleanup button:
    ```swift
    // Sources/CleanApp/MenuBarView.swift
    // add near the top of the view struct:
    @Environment(\.openWindow) private var openWindow

    // the junk-cleanup button action:
    Button("Junk Cleanup…") {
        openWindow(id: "junk")
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter SelectionSummaryTests`
    Expected: PASS (3 tests green).

- [ ] **Step 5: MANUAL UI verification (no automated UI test)**
    Build and run the app, then exercise the scan -> preview -> trash flow:
    ```bash
    swift build
    swift run CleanApp
    ```
    Precise expected observations:
    1. Click the menu-bar item, then choose **Junk Cleanup…** — the "Junk Cleanup" window opens.
    2. Click **Scan**. A progress spinner shows and a **Cancel** button appears; after completion the spinner disappears and a `List` shows items grouped under section headers (User Caches / Logs / Developer Junk). Each row has a checkbox (auto-selected items pre-checked), shows the item name, and its allocated size on the right.
    3. The footer reads `N selected · X.X MB reclaimable`; toggling a row's checkbox updates both the count and the reclaimable total immediately.
    4. (Cancel check) Re-run **Scan** and click **Cancel** mid-scan — the spinner disappears and no partial crash occurs.
    5. Click **Move to Trash**. The trashed rows disappear from the list and the footer shows `Trashed T · skipped S · failed F · freed Y.Y MB`.
    6. Open **Finder → Trash** (or run `open ~/.Trash`) and confirm the moved files/folders now appear in the Trash (proving `FileManager.trashItem` was used, not a hard delete).

- [ ] **Step 6: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/SelectionSummary.swift \
            Sources/CleanApp/Panels/JunkPanel.swift \
            Sources/CleanApp/MenuBarView.swift \
            Tests/CleanCoreTests/SelectionSummaryTests.swift
    # If the app-entry Window wiring lives in a separate file, stage it too, e.g.:
    # git add Sources/CleanApp/CleanApp.swift
    #
    # Recommended commit message (USER runs `git commit`):
    #   feat(app): JunkPanel scan→preview→trash + testable selectionSummary
    #
    #   - JunkPanel runs JunkScanner.scan() on a cancellable background Task,
    #     lists ScanItems grouped by kind with checkboxes (default isAutoSelected),
    #     shows per-item allocated size + running reclaimable total.
    #   - Move-to-Trash calls SafeRemover.trash and displays TrashOutcome counts/bytes.
    #   - Wired junk-cleanup button in MenuBarView to open the panel window.
    #   - Extracted UI-free selectionSummary(items:) -> SelectionSummary into CleanCore
    #     with XCTest coverage. UI verified manually (items listed; files appear in Finder Trash).
    ```

### Task 13: DuplicatePanel (folder pick -> scan -> grouped -> trash)

**Files:**
- Create: `Sources/CleanApp/Panels/DuplicatePanel.swift`
- Create: `Sources/CleanCore/DuplicateSelection.swift`
- Test: `Tests/CleanCoreTests/DuplicateSelectionTests.swift`

**Interfaces:**
- Consumes:
  - `public struct DuplicateFinder { public init(scanner: Scanner, probe: StatProbing); public func find(in roots: [URL]) throws -> [DuplicateGroup] }`
  - `public struct DuplicateGroup: Identifiable, Sendable { public let id: UUID; public let confidence: DuplicateConfidence; public let items: [ScanItem] }`
  - `public enum DuplicateConfidence: String, Sendable { case exact, cloneSuspected }`
  - `public struct Scanner { public init(ignore: IgnoreRules, probe: StatProbing) }`
  - `public struct IgnoreRules: Sendable { public static let default: IgnoreRules }`
  - `public struct DefaultStatProbe: StatProbing { public init() }`
  - `public struct SafeRemover { public init(probe: StatProbing, fileManager: FileManager); public func trash(_ items: [ScanItem]) -> TrashOutcome }`
  - `public struct TrashOutcome: Sendable { public let trashed: [URL]; public let skipped: [SkippedItem]; public let failed: [FailedItem]; public let reclaimedAllocated: Int64 }`
  - `public struct ScanItem: Identifiable, Sendable { public let id: UUID; public let url: URL; public let logicalSize: Int64; public let allocatedSize: Int64; public let kind: ItemKind; public let snapshot: StatSnapshot; public var isAutoSelected: Bool; public var evidence: String? }`
- Produces:
  - `public func autoSelectedItems(groups: [DuplicateGroup]) -> [ScanItem]` (pure helper in CleanCore)
  - `struct DuplicatePanel: View` (UI; verified MANUALLY)

- [ ] **Step 1: Write the failing test for the pure selection helper**
    ```swift
    import XCTest
    @testable import CleanCore

    final class DuplicateSelectionTests: XCTestCase {

        // Build a throwaway ScanItem with deterministic fields.
        private func makeItem(_ name: String, size: Int64) -> ScanItem {
            let url = URL(fileURLWithPath: "/tmp/clean-status-fixtures/\(name)")
            let snap = StatSnapshot(size: size, mtime: 1_000, fileID: 1, deviceID: 1)
            return ScanItem(
                id: UUID(),
                url: url,
                logicalSize: size,
                allocatedSize: size,
                kind: .duplicate,
                snapshot: snap,
                isAutoSelected: false,
                evidence: nil
            )
        }

        func testExactGroupContributesNonFirstItems() {
            let group = DuplicateGroup(
                id: UUID(),
                confidence: .exact,
                items: [makeItem("a", size: 10), makeItem("b", size: 10), makeItem("c", size: 10)]
            )
            let selected = autoSelectedItems(groups: [group])
            // Kept original (items[0]) excluded; the other two contributed.
            XCTAssertEqual(selected.count, 2)
            XCTAssertEqual(Set(selected.map { $0.url }), [group.items[1].url, group.items[2].url])
            XCTAssertFalse(selected.contains { $0.url == group.items[0].url })
        }

        func testCloneSuspectedGroupContributesNothing() {
            let group = DuplicateGroup(
                id: UUID(),
                confidence: .cloneSuspected,
                items: [makeItem("x", size: 20), makeItem("y", size: 20)]
            )
            let selected = autoSelectedItems(groups: [group])
            XCTAssertTrue(selected.isEmpty)
        }

        func testMixedGroupsOnlyExactContribute() {
            let exact = DuplicateGroup(
                id: UUID(),
                confidence: .exact,
                items: [makeItem("e1", size: 30), makeItem("e2", size: 30)]
            )
            let clone = DuplicateGroup(
                id: UUID(),
                confidence: .cloneSuspected,
                items: [makeItem("c1", size: 40), makeItem("c2", size: 40), makeItem("c3", size: 40)]
            )
            let selected = autoSelectedItems(groups: [exact, clone])
            XCTAssertEqual(selected.count, 1)
            XCTAssertEqual(selected.first?.url, exact.items[1].url)
        }

        func testEmptyInputYieldsEmpty() {
            XCTAssertTrue(autoSelectedItems(groups: []).isEmpty)
        }
    }
    ```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter DuplicateSelectionTests`
    Expected: FAIL — compile error / "cannot find 'autoSelectedItems' in scope" because `Sources/CleanCore/DuplicateSelection.swift` does not exist yet.

- [ ] **Step 3: Write the pure helper in CleanCore**
    ```swift
    // Sources/CleanCore/DuplicateSelection.swift
    import Foundation

    /// Default auto-selection across duplicate groups.
    ///
    /// - `.exact` groups: every member except the kept original (`items[0]`) is contributed.
    /// - `.cloneSuspected` groups: nothing is contributed (APFS clones share storage; trashing
    ///   one reclaims nothing and risks the user's intent). These must be reviewed manually.
    public func autoSelectedItems(groups: [DuplicateGroup]) -> [ScanItem] {
        var result: [ScanItem] = []
        for group in groups where group.confidence == .exact {
            guard group.items.count > 1 else { continue }
            result.append(contentsOf: group.items.dropFirst())
        }
        return result
    }
    ```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter DuplicateSelectionTests`
    Expected: PASS (4 tests).

- [ ] **Step 5: Write the DuplicatePanel SwiftUI view (UI — verified manually)**
    Create `Sources/CleanApp/Panels/DuplicatePanel.swift`. The panel: picks a folder via `NSOpenPanel`, runs `DuplicateFinder.find(in:)` on a cancellable background `Task`, renders each group with the kept original highlighted and other members checkable, visually flags `.cloneSuspected` groups (selected off by default, evidence shown), and trashes the user's selection via `SafeRemover`.
    ```swift
    // Sources/CleanApp/Panels/DuplicatePanel.swift
    import SwiftUI
    import AppKit
    import CleanCore

    @MainActor
    struct DuplicatePanel: View {

        private enum Phase: Equatable {
            case idle
            case scanning(URL)
            case results(URL)
            case failed(String)
        }

        @State private var phase: Phase = .idle
        @State private var groups: [DuplicateGroup] = []
        @State private var selected: Set<UUID> = []      // ScanItem.id values chosen for trash
        @State private var scanTask: Task<Void, Never>?
        @State private var outcomeText: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                content
                Divider()
                footer
            }
            .padding(16)
            .frame(width: 520, height: 560)
            .onDisappear { scanTask?.cancel() }
        }

        // MARK: - Header

        private var header: some View {
            HStack {
                Text("Duplicate Finder").font(.headline)
                Spacer()
                switch phase {
                case .scanning:
                    Button("Cancel") { cancelScan() }
                default:
                    Button("Choose Folder…") { chooseFolderAndScan() }
                }
            }
        }

        // MARK: - Content

        @ViewBuilder
        private var content: some View {
            switch phase {
            case .idle:
                placeholder("Choose a folder to scan for duplicate files.")
            case .scanning(let root):
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Scanning \(root.path)…").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder("Scan failed: \(message)")
            case .results(let root):
                if groups.isEmpty {
                    placeholder("No duplicates found in \(root.path).")
                } else {
                    resultsList
                }
            }
        }

        private func placeholder(_ text: String) -> some View {
            Text(text)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
        }

        private var resultsList: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        groupView(group)
                    }
                }
                .padding(.vertical, 4)
            }
        }

        @ViewBuilder
        private func groupView(_ group: DuplicateGroup) -> some View {
            let isClone = group.confidence == .cloneSuspected
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: isClone ? "exclamationmark.triangle.fill" : "doc.on.doc")
                        .foregroundStyle(isClone ? Color.orange : Color.secondary)
                    Text(isClone ? "Clone suspected — review manually" : "Exact duplicates")
                        .font(.subheadline.bold())
                        .foregroundStyle(isClone ? Color.orange : Color.primary)
                }
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    memberRow(item: item, isKept: index == 0, isClone: isClone)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isClone ? Color.orange.opacity(0.08) : Color.gray.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isClone ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
            )
        }

        @ViewBuilder
        private func memberRow(item: ScanItem, isKept: Bool, isClone: Bool) -> some View {
            HStack(alignment: .top, spacing: 8) {
                if isKept {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .help("Kept original")
                } else {
                    Toggle("", isOn: bindingFor(item.id))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                        .font(.callout)
                        .fontWeight(isKept ? .semibold : .regular)
                    Text(item.url.deletingLastPathComponent().path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let evidence = item.evidence {
                        Text(evidence)
                            .font(.caption2)
                            .foregroundStyle(isClone ? Color.orange : Color.secondary)
                    }
                }
                Spacer()
                Text(byteString(item.allocatedSize))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .background(isKept ? Color.yellow.opacity(0.10) : Color.clear)
        }

        // MARK: - Footer

        private var footer: some View {
            VStack(alignment: .leading, spacing: 6) {
                if let outcomeText {
                    Text(outcomeText).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("\(selected.count) selected").font(.caption)
                    Spacer()
                    Button("Move Selected to Trash") { trashSelected() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected.isEmpty)
                }
            }
        }

        // MARK: - Selection binding

        private func bindingFor(_ id: UUID) -> Binding<Bool> {
            Binding(
                get: { selected.contains(id) },
                set: { isOn in
                    if isOn { selected.insert(id) } else { selected.remove(id) }
                }
            )
        }

        // MARK: - Actions

        private func chooseFolderAndScan() {
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false
            openPanel.prompt = "Scan"
            openPanel.message = "Choose a folder to scan for duplicates"
            guard openPanel.runModal() == .OK, let root = openPanel.url else { return }
            startScan(root: root)
        }

        private func startScan(root: URL) {
            scanTask?.cancel()
            groups = []
            selected = []
            outcomeText = nil
            phase = .scanning(root)

            scanTask = Task {
                let probe = DefaultStatProbe()
                let scanner = Scanner(ignore: .default, probe: probe)
                let finder = DuplicateFinder(scanner: scanner, probe: probe)
                do {
                    let found = try finder.find(in: [root])
                    if Task.isCancelled { return }
                    await MainActor.run {
                        groups = found
                        // Default selection: exact-group non-originals only; clones excluded.
                        selected = Set(autoSelectedItems(groups: found).map { $0.id })
                        phase = .results(root)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await MainActor.run {
                        phase = .failed(error.localizedDescription)
                    }
                }
            }
        }

        private func cancelScan() {
            scanTask?.cancel()
            scanTask = nil
            phase = .idle
        }

        private func trashSelected() {
            let items = groups
                .flatMap { $0.items }
                .filter { selected.contains($0.id) }
            guard !items.isEmpty else { return }

            let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: .default)
            let outcome: TrashOutcome = remover.trash(items)

            outcomeText = summary(of: outcome)

            // Drop trashed ids from selection and re-scan-free pruning of groups.
            let trashedSet = Set(outcome.trashed)
            groups = groups.compactMap { group in
                let remaining = group.items.filter { !trashedSet.contains($0.url) }
                guard remaining.count >= 2 else { return nil }
                return DuplicateGroup(id: group.id, confidence: group.confidence, items: remaining)
            }
            let remainingIDs = Set(groups.flatMap { $0.items }.map { $0.id })
            selected = selected.intersection(remainingIDs)
        }

        private func summary(of outcome: TrashOutcome) -> String {
            var parts: [String] = []
            parts.append("Trashed \(outcome.trashed.count) (\(byteString(outcome.reclaimedAllocated)) reclaimed)")
            if !outcome.skipped.isEmpty { parts.append("skipped \(outcome.skipped.count)") }
            if !outcome.failed.isEmpty { parts.append("failed \(outcome.failed.count)") }
            return parts.joined(separator: ", ")
        }

        private func byteString(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }
    ```
    Wire the duplicate button from `MenuBarView` to present this panel (open in its own window). In `MenuBarView.swift`, add an `@Environment(\.openWindow) private var openWindow` and a button whose action calls `openWindow(id: "duplicate-panel")`, then register a matching `Window("Duplicate Finder", id: "duplicate-panel") { DuplicatePanel() }` (or `WindowGroup`) in the app's `Scene`. If `MenuBarView` already routes panels through an existing enum/state mechanism (established in the MenuBarView task), add a `.duplicate` case there instead and present `DuplicatePanel()` — do not duplicate the windowing approach.

- [ ] **Step 6: Manual UI verification**
    Build and run, then exercise the flow by hand (this panel has no automated UI test; the pure logic is covered by `DuplicateSelectionTests`).
    Run:
    ```bash
    swift build
    swift run CleanApp
    ```
    Setup fixtures (in a separate terminal) so there is something to find:
    ```bash
    mkdir -p ~/dupe-demo/sub
    printf 'identical-content-AAAA' > ~/dupe-demo/one.txt
    printf 'identical-content-AAAA' > ~/dupe-demo/sub/two.txt   # exact duplicate
    cp -c ~/dupe-demo/one.txt ~/dupe-demo/clone.txt 2>/dev/null || true   # APFS clone (cloneSuspected)
    ```
    Expected observations:
    1. From the menu-bar item, the Duplicate button opens the Duplicate Finder window.
    2. "Choose Folder…" opens an `NSOpenPanel` restricted to directories; pick `~/dupe-demo`.
    3. While scanning, a spinner with "Scanning …/dupe-demo…" appears and the header shows a working "Cancel" button. Clicking Cancel returns to the idle placeholder and stops work.
    4. Results list shows an "Exact duplicates" group: the first member (`one.txt`) is highlighted with a star ("Kept original", no checkbox), the other member (`two.txt`) has a checkbox that is pre-checked. The footer reads "1 selected".
    5. If the APFS clone was created, a separate orange-bordered "Clone suspected — review manually" group appears; its members are NOT pre-checked and each shows clone evidence text. The footer count does NOT include clone members.
    6. With `two.txt` checked, "Move Selected to Trash" is enabled. Clicking it moves `two.txt` to the Finder Trash (verify it is gone from disk and present in `~/.Trash`), the footer prints "Trashed 1 (… reclaimed)", and the now-singleton exact group disappears from the list.
    7. Re-running the scan after editing one file's contents and trying to trash it shows it reported under "skipped" (changed since scan), proving the SafeRemover re-stat guard. (`/Library` and `/System` are never reachable because folder choice is user-driven and SafeRemover only trashes — never removes.)

- [ ] **Step 7: Stage (user commits)**
    ```bash
    git add Sources/CleanCore/DuplicateSelection.swift \
            Sources/CleanApp/Panels/DuplicatePanel.swift \
            Tests/CleanCoreTests/DuplicateSelectionTests.swift
    # Recommended commit message (USER runs `git commit`):
    # feat(app): DuplicatePanel folder-scan duplicate review + trash
    #
    # - NSOpenPanel folder pick -> cancellable DuplicateFinder.find Task
    # - exact groups: keep first, pre-check rest; cloneSuspected flagged, never auto-selected, evidence shown
    # - trash selection via SafeRemover; show TrashOutcome summary
    # - extract pure autoSelectedItems(groups:) into CleanCore + XCTest
    # - wire Duplicate button from MenuBarView; UI verified manually
    ```

### Task 14: UninstallPanel (drop .app → leftovers → trash) + FDA onboarding

**Files:**
- Create: `Sources/CleanCore/FullDiskAccess.swift` (pure, testable classifier)
- Create: `Sources/CleanApp/FullDiskAccess.swift` (FDA onboarding sheet + open-Settings action)
- Create: `Sources/CleanApp/Panels/UninstallPanel.swift` (the uninstall UI)
- Edit: `Sources/CleanApp/MenuBarView.swift` (wire the app-delete button)
- Test: `Tests/CleanCoreTests/FullDiskAccessTests.swift`

**Interfaces:**
- Consumes (FROZEN CONTRACT):
  - `AppUninstaller.init(scanner: Scanner, home: URL)` / `func plan(for appURL: URL) throws -> UninstallPlan`
  - `UninstallPlan { let app: ScanItem; let bundleID: String; let leftovers: [ScanItem] }`
  - `ScanItem { let id: UUID; let url: URL; let logicalSize: Int64; let allocatedSize: Int64; let kind: ItemKind; var isAutoSelected: Bool; var evidence: String? }`
  - `Scanner.init(ignore: IgnoreRules, probe: StatProbing)`, `IgnoreRules.default`, `DefaultStatProbe.init()`
  - `SafeRemover.init(probe: StatProbing, fileManager: FileManager)` / `func trash(_ items: [ScanItem]) -> TrashOutcome`
  - `TrashOutcome { let trashed: [URL]; let skipped: [SkippedItem]; let failed: [FailedItem]; let reclaimedAllocated: Int64 }`
- Produces (new CleanCore public surface introduced by this task — not in the frozen contract, additive only):
  - `public enum FullDiskAccessClassifier { public static func needsFullDiskAccess(errno code: Int32) -> Bool; public static func needsFullDiskAccess(for error: Error) -> Bool }`
  - SwiftUI: `UninstallPanel` (CleanApp), `FullDiskAccessSheet` (CleanApp) — manually verified.

---

- [ ] **Step 1: Write the failing test** (the pure classifier — this is the extracted non-UI logic)

```swift
import XCTest
import Foundation
@testable import CleanCore

final class FullDiskAccessTests: XCTestCase {

    // EPERM (POSIX errno 1) -> true
    func testEPERMErrnoNeedsFullDiskAccess() {
        XCTAssertTrue(FullDiskAccessClassifier.needsFullDiskAccess(errno: EPERM))
    }

    // EACCES (13) also indicates a permission wall -> true
    func testEACCESErrnoNeedsFullDiskAccess() {
        XCTAssertTrue(FullDiskAccessClassifier.needsFullDiskAccess(errno: EACCES))
    }

    // A generic "not found" (ENOENT / 2) is NOT a permission problem -> false
    func testNotFoundErrnoDoesNotNeedFullDiskAccess() {
        XCTAssertFalse(FullDiskAccessClassifier.needsFullDiskAccess(errno: ENOENT))
    }

    // POSIXError.EPERM value -> true
    func testPOSIXErrorEPERM() {
        let err: Error = POSIXError(.EPERM)
        XCTAssertTrue(FullDiskAccessClassifier.needsFullDiskAccess(for: err))
    }

    // Foundation's Cocoa permission error (NSFileReadNoPermissionError = 257) -> true
    func testCocoaNoPermissionError() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        XCTAssertTrue(FullDiskAccessClassifier.needsFullDiskAccess(for: err))
    }

    // EPERM nested under NSUnderlyingErrorKey of a Cocoa error -> true (real shape from FileManager)
    func testUnderlyingPOSIXEPERM() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil)
        let err = NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadUnknownError,
                          userInfo: [NSUnderlyingErrorKey: underlying])
        XCTAssertTrue(FullDiskAccessClassifier.needsFullDiskAccess(for: err))
    }

    // A generic "no such file" Cocoa error (260) -> false
    func testCocoaNoSuchFileError() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil)
        XCTAssertFalse(FullDiskAccessClassifier.needsFullDiskAccess(for: err))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
    Run: `swift test --filter FullDiskAccessTests`
    Expected: FAIL to compile with "cannot find 'FullDiskAccessClassifier' in scope" (the type does not exist yet).

- [ ] **Step 3: Write minimal implementation**

`Sources/CleanCore/FullDiskAccess.swift` (pure, no UI, no AppKit — fully testable):

```swift
import Foundation

/// Pure classification of whether a scan/IO failure is caused by missing Full Disk Access
/// (a sandbox/TCC permission wall) versus an ordinary error (e.g. file not found).
///
/// macOS reports a TCC/permission denial as POSIX `EPERM` (errno 1). Foundation's
/// `FileManager` surfaces this as `NSFileReadNoPermissionError` (NSCocoaErrorDomain 257),
/// often with the raw POSIX error nested under `NSUnderlyingErrorKey`
/// (NSPOSIXErrorDomain, code 1). `EACCES` (13) is the classic BSD-permission denial and is
/// treated the same way for onboarding purposes. `ENOENT` (not found) is NOT a permission issue.
public enum FullDiskAccessClassifier {

    /// Map a raw POSIX errno to whether it indicates a permission wall.
    public static func needsFullDiskAccess(errno code: Int32) -> Bool {
        return code == EPERM || code == EACCES
    }

    /// Map an arbitrary `Error` (typically thrown by `FileManager` / `Scanner`) to whether it
    /// indicates a missing Full Disk Access permission. Unwraps Cocoa, POSIX, and nested errors.
    public static func needsFullDiskAccess(for error: Error) -> Bool {
        // Swift-typed POSIX error.
        if let posix = error as? POSIXError {
            return needsFullDiskAccess(errno: posix.code.rawValue)
        }

        let nsError = error as NSError

        switch nsError.domain {
        case NSPOSIXErrorDomain:
            return needsFullDiskAccess(errno: Int32(truncatingIfNeeded: nsError.code))

        case NSCocoaErrorDomain:
            if nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError {
                return true
            }
            // Drill into the wrapped underlying error (FileManager nests the POSIX cause here).
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return needsFullDiskAccess(for: underlying)
            }
            return false

        default:
            // Some lower-level APIs report directly via the OSStatus/Mach domains; ignore those.
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return needsFullDiskAccess(for: underlying)
            }
            return false
        }
    }
}
```

`Sources/CleanApp/FullDiskAccess.swift` (onboarding sheet + open-Settings action — verified URL):

```swift
import SwiftUI
import AppKit

/// Cross-cutting Full Disk Access onboarding. Presented as a sheet whenever a scan/uninstall
/// fails with a permission error (see `FullDiskAccessClassifier`).
@MainActor
struct FullDiskAccessSheet: View {
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Full Disk Access Required", systemImage: "lock.shield")
                .font(.headline)

            Text("CleanStatus needs Full Disk Access to scan and clean files under your "
                 + "~/Library folder. Grant access in System Settings, then return here and retry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("System Settings → Privacy & Security → Full Disk Access → enable CleanStatus.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open System Settings") { FullDiskAccessSheet.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Retry") { onRetry() }
                Button("Close") { onDismiss() }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Verified deep link to the Full Disk Access pane of Privacy & Security.
    /// `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
```

`Sources/CleanApp/Panels/UninstallPanel.swift`:

```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CleanCore

@MainActor
struct UninstallPanel: View {
    /// Home directory used by AppUninstaller to locate leftovers (defaults to the real home).
    let home: URL

    @State private var plan: UninstallPlan?
    @State private var selection: Set<UUID> = []
    @State private var outcome: TrashOutcome?
    @State private var errorMessage: String?
    @State private var showFDASheet = false
    @State private var lastDroppedURL: URL?
    @State private var isDropTargeted = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let plan {
                planView(plan)
            } else {
                dropZone
            }

            if let outcome {
                outcomeView(outcome)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 460)
        .sheet(isPresented: $showFDASheet) {
            FullDiskAccessSheet(
                onRetry: {
                    showFDASheet = false
                    if let url = lastDroppedURL { load(appURL: url) }
                },
                onDismiss: { showFDASheet = false }
            )
        }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Label("Uninstall App", systemImage: "trash.square")
                .font(.headline)
            Spacer()
            Button("Choose .app…") { chooseApp() }
            if plan != nil {
                Button("Reset") { reset() }
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 120)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.largeTitle)
                    Text("Drop an application here, or click “Choose .app…”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
    }

    private func planView(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row(for: plan.app, isApp: true)

            Divider()

            if plan.leftovers.isEmpty {
                Text("No leftover files found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Leftovers (\(plan.leftovers.count))")
                    .font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.leftovers) { item in
                            row(for: item, isApp: false)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack {
                Text(selectionSummary(plan))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move \(selection.count) Item(s) to Trash") { trashSelected(plan) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
        }
    }

    private func row(for item: ScanItem, isApp: Bool) -> some View {
        let bound = Binding<Bool>(
            get: { selection.contains(item.id) },
            set: { isOn in
                if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
            }
        )
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: bound)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: isApp ? "app.badge" : "doc")
                    Text(item.url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(byteString(item.allocatedSize))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let evidence = item.evidence {
                    Text("⚠︎ \(evidence)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func outcomeView(_ outcome: TrashOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Trashed \(outcome.trashed.count) • Skipped \(outcome.skipped.count) • Failed \(outcome.failed.count)")
                .font(.footnote.bold())
            Text("Reclaimed \(byteString(outcome.reclaimedAllocated))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(outcome.skipped, id: \.url) { s in
                Text("Skipped \(s.url.lastPathComponent): \(s.reason)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(outcome.failed, id: \.url) { f in
                Text("Failed \(f.url.lastPathComponent): \(f.message)")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            load(appURL: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { return }
            Task { @MainActor in self.load(appURL: url) }
        }
        return true
    }

    private func load(appURL: URL) {
        errorMessage = nil
        outcome = nil
        lastDroppedURL = appURL
        let scanner = Scanner(ignore: .default, probe: DefaultStatProbe())
        let uninstaller = AppUninstaller(scanner: scanner, home: home)
        do {
            let newPlan = try uninstaller.plan(for: appURL)
            plan = newPlan
            // Auto-check exact matches; leave ambiguous ones unchecked.
            var preselected = Set<UUID>()
            if newPlan.app.isAutoSelected { preselected.insert(newPlan.app.id) }
            for item in newPlan.leftovers where item.isAutoSelected {
                preselected.insert(item.id)
            }
            selection = preselected
        } catch {
            if FullDiskAccessClassifier.needsFullDiskAccess(for: error) {
                showFDASheet = true
            } else {
                errorMessage = "Could not read app: \(error.localizedDescription)"
            }
        }
    }

    private func trashSelected(_ plan: UninstallPlan) {
        let all = [plan.app] + plan.leftovers
        let chosen = all.filter { selection.contains($0.id) }
        let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: .default)
        outcome = remover.trash(chosen)
    }

    private func reset() {
        plan = nil
        selection = []
        outcome = nil
        errorMessage = nil
        lastDroppedURL = nil
    }

    private func selectionSummary(_ plan: UninstallPlan) -> String {
        let all = [plan.app] + plan.leftovers
        let total = all.filter { selection.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.allocatedSize }
        return "Selected \(selection.count) of \(all.count) • \(byteString(total))"
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
```

`Sources/CleanApp/MenuBarView.swift` — wire the app-delete button (add this Button inside the existing menu content, plus a `@State` flag and a popover/sheet to host the panel):

```swift
// --- add to MenuBarView's @State block ---
@State private var showUninstall = false

// --- add this Button where the menu actions live ---
Button {
    showUninstall = true
} label: {
    Label("Uninstall App…", systemImage: "trash.square")
}

// --- attach to the menu's root container view (e.g. the outermost VStack) ---
.sheet(isPresented: $showUninstall) {
    UninstallPanel()
}
```

- [ ] **Step 4: Run test to verify it passes**
    Run: `swift test --filter FullDiskAccessTests`
    Expected: PASS (all 7 cases — EPERM/EACCES/POSIXError/Cocoa-no-permission/nested-EPERM → true; ENOENT/no-such-file → false).

    **Manual UI verification (UninstallPanel + FDA sheet — no automated UI test):**
    1. Build & run: `swift build && swift run CleanApp`
    2. Open the menu-bar item → click **Uninstall App…**.
    3. Click **Choose .app…**, pick an app from `/Applications` (or drag a `.app` onto the drop zone). Expected: the app row appears checked, and leftover rows appear — exact `CFBundleIdentifier` matches are pre-checked; ambiguous (name-only / prefix / shared-group) rows are unchecked and show an orange "⚠︎ <evidence>" line.
    4. Confirm the summary line shows "Selected N of M • <size>" and updates as you toggle rows.
    5. Click **Move N Item(s) to Trash**. Expected: items appear in Finder's Trash (never hard-deleted — SafeRemover uses `trashItem`); the outcome line shows Trashed/Skipped/Failed counts and reclaimed bytes.
    6. FDA path: temporarily revoke Full Disk Access (System Settings → Privacy & Security → Full Disk Access → disable CleanStatus), then load an app whose leftover scan hits `~/Library`. Expected: the **Full Disk Access Required** sheet appears; **Open System Settings** opens the Full Disk Access pane (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`); after granting and clicking **Retry**, the plan loads.

- [ ] **Step 5: Stage (user commits)**

```bash
git add Sources/CleanCore/FullDiskAccess.swift \
        Sources/CleanApp/FullDiskAccess.swift \
        Sources/CleanApp/Panels/UninstallPanel.swift \
        Sources/CleanApp/MenuBarView.swift \
        Tests/CleanCoreTests/FullDiskAccessTests.swift
# Recommended commit message (run yourself):
# feat(app): UninstallPanel (drop .app -> leftovers -> trash) + Full Disk Access onboarding
#
# - UninstallPanel: NSOpenPanel/drag-drop .app, AppUninstaller.plan, exact matches
#   auto-checked, ambiguous leftovers shown with evidence, trash via SafeRemover.
# - FullDiskAccessClassifier (CleanCore): pure errno/Error -> needsFullDiskAccess map
#   (EPERM/EACCES/NSFileReadNoPermissionError -> true; ENOENT/notFound -> false).
# - FullDiskAccessSheet: opens Privacy_AllFiles pane via NSWorkspace.
# - Wire Uninstall App… button from MenuBarView.
```
