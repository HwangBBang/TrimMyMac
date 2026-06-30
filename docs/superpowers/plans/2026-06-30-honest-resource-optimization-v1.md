# Honest Resource Optimization (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an honest, read-only resource-optimization surface — pressure-first menu-bar pill, pressure/swap history, a "최적화" diagnosis window with view-only top memory consumers and safe disk reclaim, and a native Settings window — without any process-termination (deferred to a signed v-next).

**Architecture:** New `ProcessMonitor` (TrimCore) owns a single same-uid process enumeration off the main actor and publishes top consumers by `phys_footprint` plus an agent-session projection (subsuming the old `AgentSessionMonitor` sampler). `MemoryMonitor` gains a timestamped pressure/swap ring buffer with a pure time-based `sustainedCritical` check. UI adds a redesigned pressure pill, a header sparkline, an `OptimizePanel` window (diagnosis + a button into the existing review-based junk flow), and a `Settings` scene. The 1 s `MenuBarLabel` timer is the single sampler; all views are read-only.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Darwin (`sysctl`, `proc_pidinfo`, `proc_pid_rusage`), Swift Testing (`import Testing`).

## Global Constraints

- Platform: macOS 26 / Apple Silicon. Swift 6.
- Tests: Swift Testing (`@Suite`/`@Test`/`#expect`), `@testable import TrimCore`. Run locally with `./scripts/test.sh` (CLT wrapper) or `swift test`; CI runs `swift test` on macos-26. Green is the completion bar.
- Commits: Claude commits directly, Korean message, **no co-author trailer** (repo policy).
- NO process termination in v1 (no `kill`, no `NSRunningApplication.terminate()` calls on the resource path). Top consumers are **view-only**.
- NO purge / free-RAM / "N GB freed" number. Per-process memory is shown as "사용 중 X" using `phys_footprint` (never summed `resident_size`).
- Disk reclaim reuses the existing review-before-trash flow (`JunkScanner` → `ScanItem` list → user selection → `SafeRemover.trash`). No hidden auto-trash.
- Single sampler invariant: the 1 s `MenuBarLabel` timer is the only place that calls `*.sample()` and appends history. Popover/windows read `@Published` state only.

---

### Task 1: MemoryMonitor pressure/swap history + sustainedCritical

**Files:**
- Modify: `Sources/TrimCore/MemoryMonitor.swift`
- Test: `Tests/TrimCoreTests/MemoryHistoryTests.swift` (create)

**Interfaces:**
- Consumes: existing `MemoryPressure` enum, `MemoryMonitor`.
- Produces:
  - `MemoryMonitor.PressureSample` — `struct PressureSample: Sendable, Equatable { let time: Date; let pressure: MemoryPressure; let swapUsed: UInt64; let usedRatio: Double }`
  - `static func trimmed(_ samples: [PressureSample], keeping window: TimeInterval, now: Date) -> [PressureSample]`
  - `static func sustainedCritical(_ samples: [PressureSample], now: Date, window: TimeInterval, maxGap: TimeInterval) -> Bool`
  - `MemoryMonitor.history: [PressureSample]` (`@Published private(set)`), appended only via `appendHistory(now:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TrimCoreTests/MemoryHistoryTests.swift`:

```swift
import Testing
import Foundation
@testable import TrimCore

@Suite("MemoryHistory")
struct MemoryHistoryTests {
    typealias S = MemoryMonitor.PressureSample
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func sample(_ offset: TimeInterval, _ p: MemoryPressure) -> S {
        S(time: t0.addingTimeInterval(offset), pressure: p, swapUsed: 0, usedRatio: 0.5)
    }

    @Test func trimmedDropsOldSamples() {
        let samples = [sample(0, .normal), sample(60, .normal), sample(115, .normal)]
        let kept = MemoryMonitor.trimmed(samples, keeping: 120, now: t0.addingTimeInterval(120))
        // cutoff = 0; sample(0) is exactly at cutoff (kept), all within window
        #expect(kept.count == 3)
        let kept2 = MemoryMonitor.trimmed(samples, keeping: 30, now: t0.addingTimeInterval(120))
        #expect(kept2.isEmpty)   // newest is at 115, cutoff is 90 → none within 30s... 115>=90 so 1
    }

    @Test func trimmedKeepsWithinWindow() {
        let samples = [sample(0, .normal), sample(100, .normal), sample(115, .normal)]
        let kept = MemoryMonitor.trimmed(samples, keeping: 30, now: t0.addingTimeInterval(120))
        #expect(kept.map(\.time) == [samples[1].time, samples[2].time]) // 100,115 >= 90
    }

    @Test func sustainedCriticalTrueWhenAllCriticalSpanningWindow() {
        let samples = (0...12).map { sample(Double($0) * 10, .critical) } // 0..120, 10s apart
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == true)
    }

    @Test func sustainedCriticalFalseWhenAnyNonCritical() {
        var samples = (0...12).map { sample(Double($0) * 10, .critical) }
        samples[5] = sample(50, .warning)
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == false)
    }

    @Test func sustainedCriticalFalseOnSleepGap() {
        // critical at 0..20, then a 100s gap (sleep), then critical at 120
        let samples = [sample(0, .critical), sample(10, .critical),
                       sample(20, .critical), sample(120, .critical)]
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == false)   // gap 20→120 exceeds maxGap
    }

    @Test func sustainedCriticalFalseWhenWindowNotYetSpanned() {
        let samples = [sample(110, .critical), sample(115, .critical), sample(120, .critical)]
        let ok = MemoryMonitor.sustainedCritical(samples, now: t0.addingTimeInterval(120),
                                                 window: 120, maxGap: 15)
        #expect(ok == false)   // oldest recent sample only 10s before now, < 120s window
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter MemoryHistory`
Expected: FAIL — `PressureSample`, `trimmed`, `sustainedCritical` not defined.

- [ ] **Step 3: Implement the history types + pure functions**

In `Sources/TrimCore/MemoryMonitor.swift`, add inside `MemoryMonitor` (after the existing `memoryBytes` helper). Add `import Foundation` is already present.

```swift
// MARK: - Pressure/swap history (pure, testable)

public struct PressureSample: Sendable, Equatable {
    public let time: Date
    public let pressure: MemoryPressure
    public let swapUsed: UInt64
    public let usedRatio: Double
    public init(time: Date, pressure: MemoryPressure, swapUsed: UInt64, usedRatio: Double) {
        self.time = time; self.pressure = pressure; self.swapUsed = swapUsed; self.usedRatio = usedRatio
    }
}

/// Drops samples older than `window` seconds before `now`.
nonisolated public static func trimmed(_ samples: [PressureSample],
                                       keeping window: TimeInterval,
                                       now: Date) -> [PressureSample] {
    let cutoff = now.addingTimeInterval(-window)
    return samples.filter { $0.time >= cutoff }
}

/// True only if every sample within `window` is `.critical`, the samples actually
/// span the window, and no consecutive gap exceeds `maxGap` (rejects sleep/timer pauses).
nonisolated public static func sustainedCritical(_ samples: [PressureSample],
                                                 now: Date,
                                                 window: TimeInterval,
                                                 maxGap: TimeInterval) -> Bool {
    let cutoff = now.addingTimeInterval(-window)
    let recent = samples.filter { $0.time >= cutoff }.sorted { $0.time < $1.time }
    guard let first = recent.first, recent.count >= 2 else { return false }
    guard now.timeIntervalSince(first.time) >= window else { return false }
    guard recent.allSatisfy({ $0.pressure == .critical }) else { return false }
    for i in 1..<recent.count where recent[i].time.timeIntervalSince(recent[i-1].time) > maxGap {
        return false
    }
    return true
}
```

Then add the stored history (after `@Published public private(set) var latest: MemorySample?`):

```swift
@Published public private(set) var history: [PressureSample] = []
/// Default retention window for the sparkline / sustained-critical check.
public static let historyWindow: TimeInterval = 120
```

And an append entry point (after `sample()`), called ONLY by the 1 s sampler (Task 8):

```swift
/// Appends a history point from the latest sample. Call from the single 1 s sampler only.
public func appendHistory(now: Date = Date()) {
    guard let s = latest else { return }
    let ratio = s.total > 0 ? Double(s.used) / Double(s.total) : 0
    let point = PressureSample(time: now, pressure: s.pressure, swapUsed: s.swapUsed, usedRatio: ratio)
    history = Self.trimmed(history + [point], keeping: Self.historyWindow, now: now)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MemoryHistory`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TrimCore/MemoryMonitor.swift Tests/TrimCoreTests/MemoryHistoryTests.swift
git commit -m "feat(memory): 압력/swap 타임스탬프 히스토리 + 시간기반 sustainedCritical"
```

---

### Task 2: ProcessMonitor pure helpers (footprint, aggregate, topN, noise filter)

**Files:**
- Create: `Sources/TrimCore/ProcessMonitor.swift`
- Test: `Tests/TrimCoreTests/ProcessMonitorTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `enum ProcessKind: Sendable { case app, agent, process }`
  - `struct ProcessUsage: Identifiable, Sendable { let id: String; let displayName: String; let bundleID: String?; let kind: ProcessKind; let footprint: UInt64; let cpu: Int }`
  - `struct RawProc: Sendable { let pid: Int32; let name: String; let bundleID: String?; let kind: ProcessKind; let footprint: UInt64 }`
  - `static func aggregate(_ procs: [RawProc]) -> [ProcessUsage]` (apps grouped by bundleID, agents/processes by pid)
  - `static func topN(_ usages: [ProcessUsage], limit: Int) -> [ProcessUsage]` (footprint desc, name asc)
  - `static func isNoiseDaemon(_ comm: String) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/TrimCoreTests/ProcessMonitorTests.swift`:

```swift
import Testing
@testable import TrimCore

@Suite("ProcessMonitor")
struct ProcessMonitorTests {
    typealias Raw = ProcessMonitor.RawProc

    @Test func aggregateGroupsAppsByBundleID() {
        let procs = [
            Raw(pid: 10, name: "Google Chrome", bundleID: "com.google.Chrome", kind: .app, footprint: 1000),
            Raw(pid: 11, name: "Google Chrome Helper", bundleID: "com.google.Chrome", kind: .app, footprint: 2000),
            Raw(pid: 20, name: "Xcode", bundleID: "com.apple.dt.Xcode", kind: .app, footprint: 4000),
        ]
        let usages = ProcessMonitor.aggregate(procs)
        #expect(usages.count == 2)
        let chrome = usages.first { $0.bundleID == "com.google.Chrome" }!
        #expect(chrome.footprint == 3000)            // helpers summed under the app
        #expect(chrome.displayName == "Google Chrome")
    }

    @Test func aggregateKeepsAgentsAndProcessesSeparate() {
        let procs = [
            Raw(pid: 100, name: "Claude Code", bundleID: nil, kind: .agent, footprint: 8000),
            Raw(pid: 200, name: "node",        bundleID: nil, kind: .process, footprint: 1500),
            Raw(pid: 201, name: "node",        bundleID: nil, kind: .process, footprint: 1200),
        ]
        let usages = ProcessMonitor.aggregate(procs)
        #expect(usages.count == 3)                   // not merged by name; keyed by pid
    }

    @Test func topNSortsByFootprintThenName() {
        let usages = [
            ProcessUsage(id: "a", displayName: "Zed", bundleID: nil, kind: .process, footprint: 100, cpu: 0),
            ProcessUsage(id: "b", displayName: "Aero", bundleID: nil, kind: .process, footprint: 100, cpu: 0),
            ProcessUsage(id: "c", displayName: "Big", bundleID: nil, kind: .process, footprint: 999, cpu: 0),
        ]
        let top = ProcessMonitor.topN(usages, limit: 2)
        #expect(top.map(\.displayName) == ["Big", "Aero"])  // footprint desc, then name asc
    }

    @Test func isNoiseDaemonFiltersKnownHelpers() {
        #expect(ProcessMonitor.isNoiseDaemon("cfprefsd") == true)
        #expect(ProcessMonitor.isNoiseDaemon("distnoted") == true)
        #expect(ProcessMonitor.isNoiseDaemon("node") == false)
        #expect(ProcessMonitor.isNoiseDaemon("python3") == false)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProcessMonitor`
Expected: FAIL — `ProcessMonitor` not defined.

- [ ] **Step 3: Implement the pure helpers**

Create `Sources/TrimCore/ProcessMonitor.swift` (live sampling added in Task 3 — this step is the pure core only):

```swift
import Foundation

public enum ProcessKind: Sendable, Equatable { case app, agent, process }

public struct ProcessUsage: Identifiable, Sendable, Equatable {
    public let id: String        // app=bundleID, agent/process="pid:<n>"
    public let displayName: String
    public let bundleID: String?
    public let kind: ProcessKind
    public let footprint: UInt64 // phys_footprint bytes (NOT summed resident_size)
    public let cpu: Int
    public init(id: String, displayName: String, bundleID: String?,
                kind: ProcessKind, footprint: UInt64, cpu: Int) {
        self.id = id; self.displayName = displayName; self.bundleID = bundleID
        self.kind = kind; self.footprint = footprint; self.cpu = cpu
    }
}

extension ProcessMonitor {
    public struct RawProc: Sendable {
        public let pid: Int32
        public let name: String
        public let bundleID: String?
        public let kind: ProcessKind
        public let footprint: UInt64
        public init(pid: Int32, name: String, bundleID: String?, kind: ProcessKind, footprint: UInt64) {
            self.pid = pid; self.name = name; self.bundleID = bundleID; self.kind = kind; self.footprint = footprint
        }
    }

    /// Apps fold together by bundleID (sum helper footprints); agents and bare
    /// processes stay individual (keyed by pid).
    nonisolated public static func aggregate(_ procs: [RawProc]) -> [ProcessUsage] {
        var byKey: [String: ProcessUsage] = [:]
        var order: [String] = []
        for p in procs {
            let key: String
            if p.kind == .app, let bundle = p.bundleID { key = "bundle:\(bundle)" }
            else { key = "pid:\(p.pid)" }
            if let existing = byKey[key] {
                byKey[key] = ProcessUsage(id: existing.id, displayName: existing.displayName,
                                          bundleID: existing.bundleID, kind: existing.kind,
                                          footprint: existing.footprint + p.footprint, cpu: existing.cpu)
            } else {
                let id = p.bundleID.map { "bundle:\($0)" } ?? "pid:\(p.pid)"
                byKey[key] = ProcessUsage(id: id, displayName: p.name, bundleID: p.bundleID,
                                          kind: p.kind, footprint: p.footprint, cpu: 0)
                order.append(key)
            }
        }
        return order.compactMap { byKey[$0] }
    }

    nonisolated public static func topN(_ usages: [ProcessUsage], limit: Int) -> [ProcessUsage] {
        Array(usages.sorted {
            $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.displayName < $1.displayName
        }.prefix(limit))
    }

    nonisolated public static func isNoiseDaemon(_ comm: String) -> Bool {
        let known: Set<String> = [
            "cfprefsd", "distnoted", "pboard", "UserEventAgent", "launchd",
            "logd", "mds", "mds_stores", "mdworker", "trustd", "secd", "nsurlsessiond",
        ]
        return known.contains(comm)
    }
}
```

Then declare the class stub so `extension ProcessMonitor` resolves (Swift is order-independent within a file; live `sample()` is filled in Task 3):

```swift
import AppKit

@MainActor
public final class ProcessMonitor: ObservableObject {
    @Published public private(set) var top: [ProcessUsage] = []
    @Published public private(set) var agentSessions: [ProcessUsage] = []
    public init() {}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProcessMonitor`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/TrimCore/ProcessMonitor.swift Tests/TrimCoreTests/ProcessMonitorTests.swift
git commit -m "feat(process): ProcessMonitor 순수 헬퍼 — footprint 집계·topN·노이즈 필터"
```

---

### Task 3: ProcessMonitor live sampling (single enumeration, phys_footprint, agent projection)

**Files:**
- Modify: `Sources/TrimCore/ProcessMonitor.swift`
- Test: `Tests/TrimCoreTests/ProcessMonitorTests.swift` (add live smoke)

**Interfaces:**
- Consumes: `AgentSessionMonitor.enumerateUserProcesses()`, `AgentSessionMonitor.processArgs(_:)`, `AgentSessionMonitor.classify(comm:argv:)` (all existing static), Task 2 helpers.
- Produces: `ProcessMonitor.sample(limit:agentsEnabled:)` populating `top` and `agentSessions`; `static func physFootprint(_ pid: Int32) -> UInt64?`.

- [ ] **Step 1: Add the live-smoke test**

Append to `ProcessMonitorTests.swift`:

```swift
    @Test @MainActor func liveSampleDoesNotCrash() {
        let m = ProcessMonitor()
        m.sample(limit: 8, agentsEnabled: true)
        #expect(m.top.count <= 8)
        for u in m.top { #expect(u.footprint > 0) }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ProcessMonitor`
Expected: FAIL — `sample(limit:agentsEnabled:)` not defined.

- [ ] **Step 3: Implement live sampling**

Add to `ProcessMonitor.swift`. `physFootprint` uses `proc_pid_rusage` (RUSAGE_INFO_V2):

```swift
extension ProcessMonitor {
    /// phys_footprint (matches Activity Monitor's Memory column) for a same-uid pid.
    nonisolated public static func physFootprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reb in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, reb)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// Single enumeration pass. Builds top consumers (apps + agents + notable bare
    /// processes) by phys_footprint, plus an agent-only projection. Heavy work is
    /// done synchronously here; Task 8 calls this from the 1 s sampler. (A future
    /// optimization can move collection to a utility queue; v1 keeps it simple but
    /// gates frequency in Task 8.)
    public func sample(limit: Int = 8, agentsEnabled: Bool = true) {
        let procs = AgentSessionMonitor.enumerateUserProcesses()   // same-uid only
        let pidToApp = Self.appsByPid()                            // pid -> (name, bundleID)

        // Footprint floor so the bare-process view isn't daemon noise.
        let floor: UInt64 = 200 * 1024 * 1024   // 200 MB

        var raws: [RawProc] = []
        var agentRaws: [RawProc] = []
        for pr in procs {
            guard let fp = Self.physFootprint(pr.pid) else { continue }

            // App?
            if let app = pidToApp[pr.pid] {
                raws.append(RawProc(pid: pr.pid, name: app.name, bundleID: app.bundleID, kind: .app, footprint: fp))
                continue
            }
            // Agent? (classify only plausible candidates to stay cheap)
            let lc = pr.comm.lowercased()
            let candidate = lc == "claude" || lc == "codex" || lc == "node" || lc == "deno" || lc == "bun"
                || lc.contains("claude") || lc.contains("codex")
            if agentsEnabled, candidate,
               let kind = AgentSessionMonitor.classify(comm: pr.comm, argv: AgentSessionMonitor.processArgs(pr.pid)) {
                let raw = RawProc(pid: pr.pid, name: kind.displayName, bundleID: nil, kind: .agent, footprint: fp)
                raws.append(raw); agentRaws.append(raw)
                continue
            }
            // Bare user process: only if notable and not obvious daemon noise.
            if fp >= floor, !Self.isNoiseDaemon(pr.comm) {
                raws.append(RawProc(pid: pr.pid, name: pr.comm, bundleID: nil, kind: .process, footprint: fp))
            }
        }

        top = Self.topN(Self.aggregate(raws), limit: limit)
        agentSessions = Self.aggregate(agentRaws).sorted { $0.footprint > $1.footprint }
    }

    /// Maps each GUI app's pid to its display name + bundleID (regular & accessory apps).
    nonisolated static func appsByPid() -> [Int32: (name: String, bundleID: String?)] {
        var out: [Int32: (String, String?)] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            out[pid] = (app.localizedName ?? app.bundleIdentifier ?? "App", app.bundleIdentifier)
        }
        return out
    }
}
```

> NOTE on app helper trees: this v1 maps only the GUI app's main pid (NSWorkspace pid). Multi-process apps whose helpers reparent to launchd (Safari/WebKit XPC) under-count; this is the documented v1 limitation (spec §5.1). Do not attempt tree-walk attribution in v1.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ProcessMonitor`
Expected: PASS (5 tests). Then full suite: `swift test` → all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrimCore/ProcessMonitor.swift Tests/TrimCoreTests/ProcessMonitorTests.swift
git commit -m "feat(process): ProcessMonitor 라이브 샘플링 — 단일 enumeration + phys_footprint + 에이전트 projection"
```

---

### Task 4: Pressure pill redesign (muted dot / warning / critical + tap)

**Files:**
- Modify: `Sources/TrimMyMacApp/MenuBarView.swift:190-198` (`pressurePill`) and `:180-188` (`header`)

**Interfaces:**
- Consumes: `MemoryPressure`, `memoryMonitor.latest`, `processMonitor.top` (passed in Task 8), `openWindow`.
- Produces: redesigned `pressurePill` that hides text at `.normal`, surfaces a tappable button at `.warning`/`.critical`.

- [ ] **Step 1: Replace `pressurePill`**

Replace the existing `pressurePill(_:)` in `MenuBarView.swift` with a pressure-state-aware version. (Add `@ObservedObject var processMonitor: ProcessMonitor` to `MenuBarView` — wired in Task 8.)

```swift
@ViewBuilder
private func pressurePill(_ pressure: MemoryPressure) -> some View {
    switch pressure {
    case .normal:
        // Muted presence dot — not a permanent "정상" label.
        Circle().fill(.secondary.opacity(0.35)).frame(width: 6, height: 6)
            .accessibilityLabel("메모리 압력 정상")
    case .warning, .critical:
        Button {
            openWindow(id: "optimize")
        } label: {
            HStack(spacing: 4) {
                Circle().fill(pressure.pillColor).frame(width: 8, height: 8)
                Text(pressure.koreanLabel).font(.caption).bold()
                if pressure == .critical, let top = processMonitor.top.first {
                    Text("· \(top.displayName)").font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(pressure.pillColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("메모리 압력이 높습니다 — 최적화 열기")
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds (after Task 8 wires `processMonitor`; if building this task alone, temporarily pass a `ProcessMonitor()` — final wiring in Task 8).

- [ ] **Step 3: Manual smoke**

Build the app (`./scripts/build-app.sh`), open the popover. Under normal pressure the header shows only a small grey dot (no "정상" text). Verify VoiceOver reads "메모리 압력 정상" on the dot.

- [ ] **Step 4: Commit**

```bash
git add Sources/TrimMyMacApp/MenuBarView.swift
git commit -m "feat(menubar): 압력 pill 재설계 — normal 무채색 점·warning/critical 탭하면 최적화"
```

---

### Task 5: Pressure/swap sparkline in the popover header

**Files:**
- Create: `Sources/TrimMyMacApp/Sparkline.swift`
- Modify: `Sources/TrimMyMacApp/MenuBarView.swift` (header)

**Interfaces:**
- Consumes: `memoryMonitor.history` ([PressureSample]).
- Produces: `Sparkline` view rendering `usedRatio` over time; flat placeholder when < 2 samples.

- [ ] **Step 1: Create the Sparkline view**

```swift
import SwiftUI
import TrimCore

/// Minimal line chart of memory used-ratio history. Flat baseline until enough samples.
struct Sparkline: View {
    let samples: [MemoryMonitor.PressureSample]
    var body: some View {
        GeometryReader { geo in
            let pts = samples
            Path { path in
                guard pts.count >= 2 else {
                    let y = geo.size.height * 0.9
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                    return
                }
                let maxR = max(pts.map(\.usedRatio).max() ?? 1, 0.0001)
                for (i, s) in pts.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                    let y = geo.size.height * (1 - CGFloat(s.usedRatio / maxR))
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(.secondary, lineWidth: 1)
        }
        .frame(width: 56, height: 16)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Add it to the header**

In `MenuBarView.header`, place the sparkline before the pill:

```swift
private var header: some View {
    HStack {
        Text("TrimMyMac").font(.headline)
        Spacer()
        Sparkline(samples: memoryMonitor.history)
        if let sample = memoryMonitor.latest {
            pressurePill(sample.pressure)
        }
    }
}
```

- [ ] **Step 3: Build + smoke**

Run: `swift build` → Expected: builds.
Run app, open popover, leave it ~10 s: the sparkline goes from flat to a small live line.

- [ ] **Step 4: Commit**

```bash
git add Sources/TrimMyMacApp/Sparkline.swift Sources/TrimMyMacApp/MenuBarView.swift
git commit -m "feat(menubar): 헤더에 압력/사용률 sparkline"
```

---

### Task 6: OptimizePanel window (diagnosis + view-only consumers + safe disk reclaim entry)

**Files:**
- Create: `Sources/TrimMyMacApp/Panels/OptimizePanel.swift`
- Modify: `Sources/TrimMyMacApp/MenuBarView.swift` (`actionButtons` — promote 최적화)
- Modify: `Sources/TrimMyMacApp/TrimMyMacApp.swift` (register Window id "optimize")

**Interfaces:**
- Consumes: `memoryMonitor.latest`/`.history`, `processMonitor.top`, `Formatting.humanReadableBytes`, `openWindow`.
- Produces: `OptimizePanel` view; an accent "최적화" button in the popover.

- [ ] **Step 1: Create OptimizePanel**

```swift
import SwiftUI
import TrimCore

struct OptimizePanel: View {
    @ObservedObject var memoryMonitor: MemoryMonitor
    @ObservedObject var processMonitor: ProcessMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var showEducation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pressureHeader
            Divider()
            diskSection
            Divider()
            consumersSection
        }
        .padding(20)
        .frame(width: 380)
    }

    private var pressureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let p = memoryMonitor.latest?.pressure {
                    Circle().fill(p.pillColor).frame(width: 10, height: 10)
                    Text("메모리 압력: \(p.koreanLabel)").font(.headline)
                }
                Spacer()
                Sparkline(samples: memoryMonitor.history)
                if let swap = memoryMonitor.latest?.swapUsed {
                    Text("swap \(humanReadableBytes(swap))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                showEducation.toggle()
            } label: {
                Label("빈 RAM은 낭비된 RAM입니다 — 우리는 '비우지' 않습니다", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showEducation {
                Text("macOS는 남는 메모리를 캐시로 채워 성능을 냅니다. '빈 RAM'을 늘리는 건 성능을 올리지 않습니다. 그래서 가짜 'RAM 비우기' 대신, 실제로 회수되는 디스크 정크를 정리하고 무엇이 메모리를 쓰는지 보여줍니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("디스크 정크 회수").font(.subheadline).bold()
            Text("실제로 되돌릴 수 있는 공간을 회수합니다 (검토 후 휴지통).")
                .font(.caption).foregroundStyle(.secondary)
            Button("디스크 정크 정리…") { openWindow(id: "junk") }
                .controlSize(.large)
        }
    }

    private var consumersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("메모리 많이 쓰는 프로세스 (보기 전용)").font(.subheadline).bold()
            if processMonitor.top.isEmpty {
                Text("측정 중…").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(processMonitor.top) { u in
                    HStack {
                        Text(u.displayName).font(.callout).lineLimit(1)
                        Spacer()
                        Text("사용 중 \(humanReadableBytes(u.footprint))")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("v1은 보기 전용입니다. 종료 기능은 서명 후 추가됩니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Promote the 최적화 button in the popover**

In `MenuBarView.actionButtons`, make 최적화 a prominent accent button above the secondary row:

```swift
private var actionButtons: some View {
    VStack(spacing: 8) {
        Button {
            openWindow(id: "optimize")
        } label: {
            Label("최적화", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        HStack(spacing: 8) {
            Button("정크 정리") { openWindow(id: "junk") }
            Button("중복 파일") { openWindow(id: "duplicates") }
            Button("앱 삭제") { openWindow(id: "uninstall") }
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Register the window**

In `TrimMyMacApp.swift`, add after the `uninstall` Window (pass the shared monitors — final instances wired in Task 8):

```swift
        Window("최적화", id: "optimize") {
            OptimizePanel(memoryMonitor: memoryMonitor, processMonitor: processMonitor)
        }
        .windowResizability(.contentSize)
```

- [ ] **Step 4: Build + smoke**

Run: `swift build` → builds (needs Task 8's `processMonitor` @StateObject; if building alone, add it temporarily).
Run app: popover shows a prominent 최적화 button → opens the window showing pressure, sparkline, swap, a "디스크 정크 정리…" button (opens JunkPanel), and a view-only top-consumers list with "사용 중 X". Confirm there is NO quit button.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrimMyMacApp/Panels/OptimizePanel.swift Sources/TrimMyMacApp/MenuBarView.swift Sources/TrimMyMacApp/TrimMyMacApp.swift
git commit -m "feat(optimize): 최적화 패널 — 진단 + 보기전용 소비자 + 검토식 디스크 회수 진입"
```

---

### Task 7: Settings scene (2 tabs) + remove DisclosureGroup + keep update-available affordance

**Files:**
- Create: `Sources/TrimMyMacApp/SettingsView.swift`
- Modify: `Sources/TrimMyMacApp/MenuBarView.swift` (`settingsSection` → `SettingsLink`; `updateRow`)
- Modify: `Sources/TrimMyMacApp/TrimMyMacApp.swift` (add `Settings` scene)

**Interfaces:**
- Consumes: `@AppStorage` keys `menubar.showCPU/showMEM/showSSD`, `agents.enabled`; `UpdaterModel`.
- Produces: `SettingsView` with 2 tabs; popover keeps a compact update-available affordance.

- [ ] **Step 1: Create SettingsView (2 tabs)**

```swift
import SwiftUI
import TrimCore

struct SettingsView: View {
    @ObservedObject var updater: UpdaterModel
    @AppStorage("menubar.showCPU") private var showCPU = true
    @AppStorage("menubar.showMEM") private var showMEM = true
    @AppStorage("menubar.showSSD") private var showSSD = true
    @AppStorage("agents.enabled") private var agentsEnabled = true

    var body: some View {
        TabView {
            Form {
                Section("메뉴바 표시") {
                    Toggle("CPU", isOn: $showCPU)
                    Toggle("메모리", isOn: $showMEM)
                    Toggle("디스크", isOn: $showSSD)
                }
                Section("AI 세션") {
                    Toggle("AI 세션 추적", isOn: $agentsEnabled)
                }
            }
            .tabItem { Label("일반", systemImage: "gearshape") }

            Form {
                LabeledContent("버전", value: appVersion)
                Button("업데이트 확인") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
        }
        .frame(width: 360, height: 240)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
```

- [ ] **Step 2: Replace popover settings + update row**

In `MenuBarView.swift`, delete `settingsSection` (the `DisclosureGroup`). Replace `updateRow` with a version + a SettingsLink + an update-available affordance only when Sparkle has one:

```swift
private var updateRow: some View {
    HStack {
        Text("v\(appVersion)").font(.caption).foregroundStyle(.secondary)
        if updater.updateAvailable {
            Button("업데이트 있음") { updater.checkForUpdates() }
                .controlSize(.small).buttonStyle(.borderedProminent)
        }
        Spacer()
        SettingsLink { Text("설정…") }
            .controlSize(.small)
    }
}
```

Remove `settingsSection` from `body` and remove the now-unused `@AppStorage` metric toggles from `MenuBarView` (they live in `SettingsView` now; `MenuBarLabel` keeps its own copies). Keep `appVersion`.

> If `UpdaterModel` has no `updateAvailable: Bool`, add one: in `Sources/TrimMyMacApp/Updater.swift`, publish `@Published var updateAvailable = false` and set it from Sparkle's `updater(_:didFindValidUpdate:)` delegate (SPUUpdaterDelegate). If wiring the delegate is out of scope, default it to `false` (affordance simply never shows) and note it as a follow-up.

- [ ] **Step 3: Add Settings scene**

In `TrimMyMacApp.swift` body, add:

```swift
        Settings {
            SettingsView(updater: updater)
        }
```

- [ ] **Step 4: Build + smoke**

Run: `swift build` → builds.
Run app: ⌘, (and the "설정…" button) opens a 2-tab Settings window (일반 / 업데이트). The popover no longer has the inline DisclosureGroup. Toggling metrics in Settings changes the menu-bar label.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrimMyMacApp/SettingsView.swift Sources/TrimMyMacApp/MenuBarView.swift Sources/TrimMyMacApp/TrimMyMacApp.swift Sources/TrimMyMacApp/Updater.swift
git commit -m "feat(settings): 네이티브 Settings 창(2탭) + 팝오버 DisclosureGroup 제거 + 업데이트 있음 affordance"
```

---

### Task 8: Wire the single sampler (ProcessMonitor) + retire AgentSessionMonitor sampling

**Files:**
- Modify: `Sources/TrimMyMacApp/TrimMyMacApp.swift` (add `@StateObject processMonitor`, pass everywhere)
- Modify: `Sources/TrimMyMacApp/MenuBarView.swift` (`MenuBarLabel.refresh` drives the single sampler + history append; `MenuBarView` agent section reads `processMonitor.agentSessions`)

**Interfaces:**
- Consumes: `ProcessMonitor`, `MemoryMonitor.appendHistory`, all prior tasks.
- Produces: a single 1 s sampler that samples memory (+history), CPU, and processes; popover/windows read-only.

- [ ] **Step 1: Add ProcessMonitor to the app + pass to views**

In `TrimMyMacApp.swift`:

```swift
    @StateObject private var processMonitor = ProcessMonitor()
```

Pass `processMonitor:` to `MenuBarView`, `MenuBarLabel`, and `OptimizePanel` (Optimize window already references it from Task 6).

- [ ] **Step 2: Drive the single sampler in `MenuBarLabel.refresh`**

Replace `MenuBarLabel.refresh()` so it owns memory history + process sampling, and remove the separate `agentMonitor.sample(...)` call:

```swift
    private func refresh() {
        memSample = memoryMonitor.sample()
        memoryMonitor.appendHistory()                 // single append site (Task 1)
        diskSample = disk.sample(volume: URL(fileURLWithPath: "/"))
        cpuMonitor.sample()

        // Process enumeration is heavier; throttle to ~every 3rd tick. Gate the full
        // scan: always sample when an Optimize/popover surface may show it OR pressure
        // is not normal; otherwise still refresh occasionally for the critical preview.
        agentTick &+= 1
        if agentTick % 3 == 1 {
            processMonitor.sample(limit: 8, agentsEnabled: agentsEnabled)
        }
    }
```

`MenuBarLabel` keeps `@AppStorage("agents.enabled") private var agentsEnabled`. Remove the `agentMonitor` parameter usage for sampling (the type can stay injected if other code needs it, but it is no longer sampled).

- [ ] **Step 3: Point the popover AI section at ProcessMonitor**

In `MenuBarView.agentSection`, read `processMonitor.agentSessions` instead of `agentMonitor.sessions`:

```swift
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 세션").font(.subheadline).bold()
            let shown = Array(processMonitor.agentSessions.prefix(8))
            if shown.isEmpty {
                Text("감지된 세션 없음").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(shown) { s in
                    HStack {
                        Text(s.displayName).font(.callout)
                        Spacer()
                        Text(humanReadableBytes(s.footprint)).font(.callout).monospacedDigit()
                    }
                }
            }
        }
    }
```

Remove the now-unused `@StateObject agentMonitor` from `TrimMyMacApp` and the `AgentSessionMonitor` parameters from `MenuBarView`/`MenuBarLabel` (the class stays in TrimCore for its static helpers reused by `ProcessMonitor`).

- [ ] **Step 4: Build, run full tests, manual smoke**

Run: `swift build` → builds clean (no unused-parameter errors).
Run: `swift test` → ALL green (existing + new).
Run app (`./scripts/build-app.sh`): one sampler at 1 s; popover AI section + Optimize consumers both populate; no double CPU/enumeration cost. Confirm memory pill/sparkline/optimize all live.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrimMyMacApp/TrimMyMacApp.swift Sources/TrimMyMacApp/MenuBarView.swift
git commit -m "refactor(monitor): 단일 샘플러로 ProcessMonitor 구동 + AgentSessionMonitor 샘플링 은퇴"
```

---

## Self-Review

**Spec coverage** (spec v2 §5):
- §5.1 ProcessMonitor (read-only, phys_footprint, single enumeration, app/agent/process, bundleID identity) → Tasks 2, 3, 8. ✓
- §5.2 MemoryMonitor history (timestamp, single append, time-based sustainedCritical) → Task 1, append wired in Task 8. ✓
- §5.3 pill (muted dot / warning / critical + tap, critical preview) → Task 4; sparkline → Task 5. ✓
- §5.4 OptimizePanel (pressure + sparkline + view-only consumers + review-based disk reclaim + progressive education + no purge/quit) → Task 6. ✓
- §5.5 Settings (2 tabs, SettingsLink, remove DisclosureGroup, update-available affordance) → Task 7. ✓
- §6 single sampler / read-only views → Task 8. ✓
- §10 v-next (process termination) → intentionally NOT in this plan. ✓

**Placeholder scan:** None. Every code step ships compile-ready Swift. (Watch the one bridging call — `proc_pid_rusage` rebind in Task 3 — and verify it compiles on the macos-26 toolchain; the idiom used is the standard one.)

**Type consistency:** `ProcessUsage` fields (`id/displayName/bundleID/kind/footprint/cpu`) are used identically in Tasks 2/3/6/8. `PressureSample` fields (`time/pressure/swapUsed/usedRatio`) match across Task 1 and Sparkline (Task 5). `sample(limit:agentsEnabled:)` signature matches between Task 3 (def) and Task 8 (call). `appendHistory(now:)` matches Task 1 (def) and Task 8 (call).

**Risk note (no silent caps):** `sustainedCritical` is implemented and tested but v1 has no alert/badge consumer yet (pill reacts to live `.pressure`, not the sustained check). Wiring a sustained-red badge/notification is a deliberate v1.x follow-up, not dropped silently. The Settings `updateAvailable` affordance degrades to never-shown if the Sparkle delegate isn't wired (called out in Task 7 Step 2).
