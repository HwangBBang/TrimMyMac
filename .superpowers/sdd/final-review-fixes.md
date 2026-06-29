# Final-review fix pass

## Commands run

```
./scripts/test.sh        → 71 tests in 14 suites passed (0.093s)
swift build -c release   → Build complete! (5.19s)
./scripts/build-app.sh   → done: /Applications/CleanStatus.app (v0.1.0 build 1)
```

## Fixes applied

- **Fix 1 — JunkPanel isScanning desync**: Added `Phase` enum (`.idle/.scanning/.results/.failed`) to `JunkPanelModel`; replaced `@Published var isScanning: Bool` with `@Published var phase: Phase`; derived `var isScanning: Bool` computed from phase; removed all direct `isScanning = …` writes including the stale `self?.isScanning = false` in the `CancellationError` catch — now matches `DuplicatePanelModel` exactly.
- **Fix 2 — SafeRemover re-stat deviceID**: Added `&& current.deviceID == item.snapshot.deviceID` to the `unchanged` equality guard in `SafeRemover.trash(_:)` so TOCTOU check is device-scoped.
- **Fix 3 — DuplicatePanel home default**: Added `openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser` in `chooseFolderAndScan()` so the picker opens inside `~` by default.
- **Fix 4 — UninstallPanel detached trash**: Replaced synchronous `remover.trash(chosen)` on `@MainActor` with a `Task.detached` inner task and a wrapping `Task` that posts `phase = .done(plan, outcome)` back on `@MainActor`; added `private var trashTask` to hold the wrapper.
- **Fix 5 — Scanner `any` existential**: Changed `private let probe: StatProbing` and its init parameter to `any StatProbing` in `Scanner.swift`.
