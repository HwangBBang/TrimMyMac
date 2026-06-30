<div align="center">

<img src="assets/AppIcon.png" width="120" alt="TrimMyMac icon">

# TrimMyMac

**A lightweight macOS menu-bar cleaner that never deletes anything — it only moves to Trash.**

Memory & disk at a glance, plus junk cleanup, duplicate finding, and app uninstalling —
built around a strict, test-enforced safety model.

</div>

---

## What it does

TrimMyMac sits in your menu bar as the squeegee glyph next to `MEM x% · SSD y%`, and opens a popover with four tools.

| Tool | What it does |
|------|--------------|
| **Menu-bar monitor** | Live memory pressure + disk usage. Metrics match [exelban/stats](https://github.com/exelban/stats): memory `used = active + inactive + speculative + wired + compressed − purgeable − external`, SSD `used% = (total − availableImportant) / total`. |
| **Junk cleanup** | Scans user caches, logs, and developer junk under your home directory and lets you review before trashing. |
| **Duplicate finder** | Folder-scan duplicate review. Collapses hard links and *probes* APFS clones — clones are surfaced but **never auto-selected**. |
| **App uninstaller** | Drop a `.app` → finds its leftovers (caches, preferences, app-support, containers) → trashes them. Exact bundle-ID matches are auto-selected; ambiguous matches require your confirmation. |
| **Memory card** | **Read-only.** Shows pressure and a breakdown — there is no "purge"/"free RAM" button by design. |

## Safety model

Every destructive path goes through `SafeRemover` and is covered by tests. The six invariants:

1. **Trash-only** — items are moved to Trash (`NSWorkspace.recycle`), never `removeItem`. Nothing is unrecoverable.
2. **You-chosen targets, no blanket sweep** — junk scanning is confined to `~`; the duplicate finder scans the folder *you* pick; the uninstaller trashes the `.app` *you* select plus its `~/Library` leftovers (so it reaches `/Applications` by design). There is no whole-disk sweep — every target is one you chose, and the scan never follows symlinks out of the chosen root.
3. **TOCTOU guard** — each selected item is re-`stat`'d at its own path immediately before trashing (identity/size/mtime/device); if that drifted since the scan, it's skipped. This guards the item itself, not a deep content-diff of a directory tree.
4. **Hard-link & clone safety** — hard links are excluded; APFS clones are never auto-selected.
5. **Exact-match uninstall** — only exact bundle-ID leftovers are auto-selected; anything ambiguous is left for you to decide.
6. **Memory is read-only** — no purging, no swapping, no "speed up your Mac" tricks.

## Requirements

- **macOS 26 (Tahoe)** on **Apple Silicon**
- **Swift 6** toolchain — works with **Command Line Tools only** (full Xcode not required)
- Some scans need **Full Disk Access** (granted via System Settings → Privacy & Security). If a scan can't read a location, the app flags it instead of silently under-reporting.

## Build & install

```bash
./scripts/build-app.sh
```

This compiles a release build, assembles `TrimMyMac.app` (with `AppIcon.icns`), code-signs it,
and installs to `/Applications/TrimMyMac.app`. Then:

```bash
open /Applications/TrimMyMac.app
```

### Code signing

The build looks for a self-signed identity named **`TrimMyMac Self-Signed`**. With it, the app's
Designated Requirement stays constant across rebuilds, so **Full Disk Access survives rebuilds**.
Without it, the build falls back to ad-hoc signing — functional, but FDA must be re-granted on
every rebuild. See [`docs/codesign-setup.md`](docs/codesign-setup.md) to create the identity once.

## Running tests

Tests use **Swift Testing** (not XCTest, which Command Line Tools don't ship). Plain `swift test`
silently skips them — use the wrapper, which adds the required framework search path:

```bash
./scripts/test.sh
```

**106 tests** across 16 suites cover the safety invariants and core logic.

## Architecture

```
Sources/
  TrimCore/          # pure, testable engine — no UI
    SafeRemover, JunkScanner, DuplicateFinder, AppUninstaller,
    MemoryMonitor, DiskMetrics, StatProbing, IgnoreRules, …
  TrimMyMacApp/      # SwiftUI + AppKit menu-bar app
    TrimMyMacApp.swift     # @main, MenuBarExtra + windows
    MenuBarView.swift      # menu-bar label + popover
    MenuBarIconAsset.swift # embedded template glyph (squeegee)
    Panels/                # Junk / Duplicate / Uninstall panels
```

All cleanup logic lives in `TrimCore` so it can be unit-tested without a UI; `TrimMyMacApp` is a
thin SwiftUI shell. The app is a menu-bar agent (`LSUIElement`) — no Dock icon.

## License

[MIT](LICENSE) © 2026 BYEONGHUN HWANG. Personal project.
