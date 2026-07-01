# FDA 안내 UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바 팝오버에 Full Disk Access 상태를 능동 감지해 표시하고, 첫 팝오버 오픈 시 정직한 FDA 온보딩을 1회 보여준다.

**Architecture:** 순수 판별·게이트 로직은 TrimCore(`FullDiskAccessStatus`/`FullDiskAccessGate`)에 두고 단위테스트한다. 앱 계층은 얇은 `FullDiskAccessModel`(ObservableObject) + `FullDiskAccessProbe`(실제 syscall)로 그 순수 로직을 소비하고, 팝오버 affordance와 온보딩 Window에 바인딩한다. 기존 반응형 배너/시트는 유지하되 딥링크를 단일 함수로 통합한다.

**Tech Stack:** Swift Package (TrimCore 라이브러리 + TrimMyMacApp 실행), SwiftUI (MenuBarExtra `.window`), swift-testing(`@Suite`/`@Test`/`#expect`), Darwin(libproc/FileManager).

## Global Constraints

- 테스트 실행은 반드시 `./scripts/test.sh`(CommandLineTools에 Testing.framework `-F` 주입). 맨 `swift test`는 swift-testing 테스트를 건너뛴다.
- 앱 타깃(TrimMyMacApp)에는 테스트 타깃이 없다 → 앱 계층 타입은 단위테스트 불가. 순수 로직은 TrimCore(TrimCoreTests)에 두고 테스트한다.
- UI 문구는 한글 우선.
- `FullDiskAccessProbe`는 **non-sandboxed LSUIElement 앱** 전제(App Sandbox면 EPERM/EACCES는 컨테이너 제한이므로 재검토).
- `unknown` 상태를 절대 `granted`로 취급/표시하지 않는다.
- FDA 딥링크 URL(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`)은 `FullDiskAccessProbe.openSettings()` 단일 출처만 사용한다.
- `Sources/TrimCore/ScanDiagnostics.swift`와 스캔 로직은 건드리지 않는다(스코프 제외).
- 커밋은 Claude 직접, 한글 메시지, co-author 트레일러 없음.

---

## File Structure

- `Sources/TrimCore/FullDiskAccess.swift` (수정) — `FullDiskAccessStatus` enum + `FullDiskAccessStatus.from(probeError:)` + `FDAAffordance` enum + `FullDiskAccessGate`. 순수·테스트 대상.
- `Sources/TrimMyMacApp/FullDiskAccess.swift` (수정) — `FullDiskAccessProbe`(system probe + openSettings) + `FullDiskAccessModel`(ObservableObject) + `OnboardingView`; 기존 `FullDiskAccessSheet` 한글화·딥링크 통합.
- `Sources/TrimMyMacApp/TrimMyMacApp.swift` (수정) — `@StateObject fdaModel`, 온보딩 `Window` 씬, MenuBarLabel/MenuBarView에 모델 전달.
- `Sources/TrimMyMacApp/MenuBarView.swift` (수정) — status별 affordance(strip/quietLink/hidden), 첫 팝오버 온보딩 트리거, didBecomeActive 재감지.
- `Sources/TrimMyMacApp/Panels/JunkPanel.swift`, `DuplicatePanel.swift` (수정) — 인라인 딥링크 → `openSettings()`.
- `Tests/TrimCoreTests/FullDiskAccessTests.swift` (수정) — status/gate 순수 테스트 추가.

---

### Task 1: FullDiskAccessStatus (tri-state) + probe-error 매핑

**Files:**
- Modify: `Sources/TrimCore/FullDiskAccess.swift`
- Test: `Tests/TrimCoreTests/FullDiskAccessTests.swift`

**Interfaces:**
- Consumes: 기존 `FullDiskAccessClassifier.needsFullDiskAccess(for:)`
- Produces: `public enum FullDiskAccessStatus { case granted, denied, unknown }`, `public static func FullDiskAccessStatus.from(probeError: Error?) -> FullDiskAccessStatus`

- [ ] **Step 1: 실패 테스트 작성** — `Tests/TrimCoreTests/FullDiskAccessTests.swift` 끝(마지막 `}` 뒤)에 새 suite 추가:

```swift
@Suite("FullDiskAccessStatus")
struct FullDiskAccessStatusTests {
    @Test func nilErrorIsGranted() {
        #expect(FullDiskAccessStatus.from(probeError: nil) == .granted)
    }
    @Test func epermIsDenied() {
        #expect(FullDiskAccessStatus.from(probeError: POSIXError(.EPERM)) == .denied)
    }
    @Test func eaccesIsDenied() {
        #expect(FullDiskAccessStatus.from(probeError: POSIXError(.EACCES)) == .denied)
    }
    @Test func cocoaNoPermissionIsDenied() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        #expect(FullDiskAccessStatus.from(probeError: err) == .denied)
    }
    @Test func enoentIsUnknownNotGranted() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        #expect(FullDiskAccessStatus.from(probeError: err) == .unknown)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `./scripts/test.sh --filter "FullDiskAccessStatus"`
Expected: 빌드 실패 — `cannot find 'FullDiskAccessStatus' in scope` (심볼 없음).

- [ ] **Step 3: 최소 구현** — `Sources/TrimCore/FullDiskAccess.swift`에서 `public enum FullDiskAccessClassifier { ... }` 블록의 닫는 `}` **뒤**에 추가:

```swift
/// Three-state Full Disk Access result. `unknown` is never treated as `granted`,
/// so a genuinely-denied user whose probe returns an unexpected error is not hidden.
public enum FullDiskAccessStatus: Equatable, Sendable {
    case granted, denied, unknown

    /// Maps a probe read outcome to a status:
    /// nil error → granted; a permission wall (EPERM/EACCES/Cocoa no-permission) → denied;
    /// anything else (e.g. ENOENT) → unknown. We never guess `granted` from an error.
    public static func from(probeError error: Error?) -> FullDiskAccessStatus {
        guard let error else { return .granted }
        return FullDiskAccessClassifier.needsFullDiskAccess(for: error) ? .denied : .unknown
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `./scripts/test.sh --filter "FullDiskAccessStatus"`
Expected: PASS (5 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/TrimCore/FullDiskAccess.swift Tests/TrimCoreTests/FullDiskAccessTests.swift
git commit -m "feat(fda): tri-state FullDiskAccessStatus + probe-error 매핑 (unknown을 granted로 안 접음)"
```

---

### Task 2: FullDiskAccessGate (온보딩/affordance 순수 게이트)

**Files:**
- Modify: `Sources/TrimCore/FullDiskAccess.swift`
- Test: `Tests/TrimCoreTests/FullDiskAccessTests.swift`

**Interfaces:**
- Consumes: `FullDiskAccessStatus` (Task 1)
- Produces: `public enum FDAAffordance { case strip, quietLink, hidden }`, `FullDiskAccessGate.shouldShowOnboarding(seen: Bool, status: FullDiskAccessStatus) -> Bool`, `FullDiskAccessGate.affordance(for: FullDiskAccessStatus) -> FDAAffordance`

> 참고: `.none` 대신 `.hidden`을 쓴다(Optional `.none`과의 모호성 회피).

- [ ] **Step 1: 실패 테스트 작성** — `FullDiskAccessTests.swift` 끝에 추가:

```swift
@Suite("FullDiskAccessGate")
struct FullDiskAccessGateTests {
    @Test func onboardingOnlyWhenDeniedAndUnseen() {
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: false, status: .denied) == true)
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: true,  status: .denied) == false)
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: false, status: .granted) == false)
        #expect(FullDiskAccessGate.shouldShowOnboarding(seen: false, status: .unknown) == false)
    }
    @Test func affordanceMapping() {
        #expect(FullDiskAccessGate.affordance(for: .denied) == .strip)
        #expect(FullDiskAccessGate.affordance(for: .unknown) == .quietLink)
        #expect(FullDiskAccessGate.affordance(for: .granted) == .hidden)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `./scripts/test.sh --filter "FullDiskAccessGate"`
Expected: 빌드 실패 — `cannot find 'FullDiskAccessGate' in scope`.

- [ ] **Step 3: 최소 구현** — `Sources/TrimCore/FullDiskAccess.swift`의 `FullDiskAccessStatus` enum 뒤에 추가:

```swift
/// What the popover should render for a given FDA status.
public enum FDAAffordance: Equatable, Sendable {
    case strip      // denied: amber "디스크 기능 제한" + [켜기]
    case quietLink  // unknown: no-alarm "설정 열기" link
    case hidden     // granted: nothing
}

/// Pure UI-gating decisions for Full Disk Access.
public enum FullDiskAccessGate {
    /// Onboarding shows once, only when denial is positively confirmed.
    public static func shouldShowOnboarding(seen: Bool, status: FullDiskAccessStatus) -> Bool {
        !seen && status == .denied
    }
    public static func affordance(for status: FullDiskAccessStatus) -> FDAAffordance {
        switch status {
        case .denied:  return .strip
        case .unknown: return .quietLink
        case .granted: return .hidden
        }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `./scripts/test.sh --filter "FullDiskAccessGate"`
Expected: PASS (2 tests).

- [ ] **Step 5: 전체 회귀 확인**

Run: `./scripts/test.sh`
Expected: 마지막 줄 `Test run with N tests in ... suites passed` (기존 126 + Task1·2 신규 7 = 133). 실패 0.

- [ ] **Step 6: 커밋**

```bash
git add Sources/TrimCore/FullDiskAccess.swift Tests/TrimCoreTests/FullDiskAccessTests.swift
git commit -m "feat(fda): FullDiskAccessGate — 온보딩(denied·미열람만)·affordance 순수 게이트"
```

---

### Task 3: FullDiskAccessProbe + FullDiskAccessModel (앱 계층)

**Files:**
- Modify: `Sources/TrimMyMacApp/FullDiskAccess.swift`

**Interfaces:**
- Consumes: `FullDiskAccessStatus.from(probeError:)` (Task 1)
- Produces: `enum FullDiskAccessProbe { static func system() -> FullDiskAccessStatus; static func openSettings() }`, `@MainActor final class FullDiskAccessModel: ObservableObject { @Published private(set) var status: FullDiskAccessStatus; @Published var onboardingRequestedThisLaunch: Bool; init(probe:); func refresh() }`

> 앱 타깃엔 테스트 타깃이 없다 → 단위테스트 없이 빌드로 검증. 로직은 Task 1의 테스트된 순수 헬퍼에 위임되어 있어 얇다. 실동작은 Task 6 스모크에서 확인.

- [ ] **Step 1: 구현 추가** — `Sources/TrimMyMacApp/FullDiskAccess.swift` 상단 `import AppKit` 아래, `struct FullDiskAccessSheet` **앞**에 추가:

```swift
import TrimCore

/// Real Full Disk Access probe. Reads a TCC-protected directory present on every Mac
/// but unreadable without FDA. NON-SANDBOXED LSUIElement app premise: under App Sandbox,
/// EPERM/EACCES would mean container limits (not FDA) and this must be revisited.
enum FullDiskAccessProbe {
    static func system() -> FullDiskAccessStatus {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC")
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return .granted
        } catch {
            return FullDiskAccessStatus.from(probeError: error)
        }
    }

    /// Deep link to the Full Disk Access pane (single source; was duplicated 3×).
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Shared, always-current FDA status for the popover affordance + onboarding gate.
/// Follows the app's monitor pattern (MemoryMonitor/ProcessMonitor/UpdaterModel).
@MainActor
final class FullDiskAccessModel: ObservableObject {
    @Published private(set) var status: FullDiskAccessStatus
    /// In-memory per-launch guard so onAppear/didBecomeActive can't open onboarding twice.
    @Published var onboardingRequestedThisLaunch = false

    private let probe: () -> FullDiskAccessStatus

    init(probe: @escaping () -> FullDiskAccessStatus = FullDiskAccessProbe.system) {
        self.probe = probe
        self.status = probe()   // synchronous initial state — no default-false race
    }

    func refresh() { status = probe() }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!`, 에러 0.

- [ ] **Step 3: 커밋**

```bash
git add Sources/TrimMyMacApp/FullDiskAccess.swift
git commit -m "feat(fda): FullDiskAccessProbe(TCC probe·딥링크) + FullDiskAccessModel(동기 init·refresh)"
```

---

### Task 4: FullDiskAccessSheet 한글화 + 딥링크 단일 출처 통합

**Files:**
- Modify: `Sources/TrimMyMacApp/FullDiskAccess.swift` (`FullDiskAccessSheet`)
- Modify: `Sources/TrimMyMacApp/Panels/JunkPanel.swift:175-179`
- Modify: `Sources/TrimMyMacApp/Panels/DuplicatePanel.swift` (permissionBanner 내 인라인 URL)

**Interfaces:**
- Consumes: `FullDiskAccessProbe.openSettings()` (Task 3)

- [ ] **Step 1: FullDiskAccessSheet 한글화 + openSettings 통합** — `Sources/TrimMyMacApp/FullDiskAccess.swift`의 `struct FullDiskAccessSheet` 본문을 아래로 교체(기존 `static func openPrivacySettings()`는 삭제):

```swift
@MainActor
struct FullDiskAccessSheet: View {
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("전체 디스크 접근 필요", systemImage: "lock.shield")
                .font(.headline)

            Text("TrimMyMac이 ~/Library 하위 파일을 스캔·정리하려면 전체 디스크 접근이 필요합니다. "
                 + "System Settings에서 켠 뒤 돌아와 다시 시도하세요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("System Settings → Privacy & Security → Full Disk Access → TrimMyMac 켜기.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("macOS가 요청하면 앱을 다시 열어야 반영될 수 있어요.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("설정 열기") { FullDiskAccessProbe.openSettings() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("다시 시도") { onRetry() }
                Button("닫기") { onDismiss() }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
```

- [ ] **Step 2: JunkPanel 배너 딥링크 교체** — `Sources/TrimMyMacApp/Panels/JunkPanel.swift`의 `permissionBanner` 내 버튼 클로저를 교체:

```swift
            Button("권한 설정 열기") {
                FullDiskAccessProbe.openSettings()
            }
            .controlSize(.small)
```

- [ ] **Step 3: DuplicatePanel 배너 딥링크 교체** — `Sources/TrimMyMacApp/Panels/DuplicatePanel.swift`의 `permissionBanner` 내 인라인 `URL(string: "x-apple.systempreferences:...")` + `NSWorkspace.shared.open` 블록을 `FullDiskAccessProbe.openSettings()` 호출로 교체(문구 "권한 설정 열기"·"이번 결과 일부" 톤 유지).

- [ ] **Step 4: 빌드 + 회귀 확인**

Run: `swift build && ./scripts/test.sh`
Expected: `Build complete!`; 테스트 `... passed`(개수 불변, 133). `openPrivacySettings` 미참조 에러 없어야 함(3곳 전부 교체됨).

- [ ] **Step 5: 커밋**

```bash
git add Sources/TrimMyMacApp/FullDiskAccess.swift Sources/TrimMyMacApp/Panels/JunkPanel.swift Sources/TrimMyMacApp/Panels/DuplicatePanel.swift
git commit -m "refactor(fda): FullDiskAccessSheet 한글화 + 딥링크 openSettings() 단일 출처 통합"
```

---

### Task 5: OnboardingView + 온보딩 Window + App 배선

**Files:**
- Modify: `Sources/TrimMyMacApp/FullDiskAccess.swift` (`OnboardingView` 추가)
- Modify: `Sources/TrimMyMacApp/TrimMyMacApp.swift`

**Interfaces:**
- Consumes: `FullDiskAccessModel` (Task 3), `FullDiskAccessProbe.openSettings()` (Task 3)
- Produces: `OnboardingView` (self-dismissing); `TrimMyMacApp`가 `@StateObject fdaModel`을 소유하고 `Window(id:"onboarding")` 제공 + MenuBarLabel/MenuBarView에 `fdaModel` 전달

- [ ] **Step 1: OnboardingView 추가** — `Sources/TrimMyMacApp/FullDiskAccess.swift` 끝에 추가:

```swift
/// First-popover-open onboarding. Marks `onboarding.fdaSeen` on APPEAR (not on button
/// click) so closing via X/Cmd-W/quit still counts as shown → shows exactly once.
@MainActor
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TrimMyMac").font(.title2).bold()
            Text("메모리·CPU·압력 모니터링과 최적화는 지금 바로 동작합니다.")
                .fixedSize(horizontal: false, vertical: true)
            Text("정크 정리·중복 파일·앱 삭제처럼 디스크를 뒤지는 기능만 전체 디스크 접근(FDA)이 필요합니다.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("지금 허용") { FullDiskAccessProbe.openSettings(); dismiss() }
                    .buttonStyle(.borderedProminent)
                Button("나중에") { dismiss() }
            }
            Text("macOS가 요청하면 앱을 다시 열어야 반영될 수 있어요. 나중에 팝오버에서 언제든 켤 수 있어요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { UserDefaults.standard.set(true, forKey: "onboarding.fdaSeen") }
    }
}
```

- [ ] **Step 2: App에 모델·창 배선** — `Sources/TrimMyMacApp/TrimMyMacApp.swift`에서 `@StateObject private var updater = UpdaterModel()` 아래에 추가:

```swift
    @StateObject private var fdaModel = FullDiskAccessModel()
```

같은 파일 `MenuBarExtra { ... }`의 라벨/콘텐츠 호출에 `fdaModel`을 전달하도록 수정:

```swift
        MenuBarExtra {
            MenuBarView(memoryMonitor: memoryMonitor, cpuMonitor: cpuMonitor,
                        processMonitor: processMonitor,
                        updater: updater, fdaModel: fdaModel)
        } label: {
            MenuBarLabel(memoryMonitor: memoryMonitor, cpuMonitor: cpuMonitor,
                         processMonitor: processMonitor, fdaModel: fdaModel)
        }
        .menuBarExtraStyle(.window)
```

그리고 `Settings { ... }` 씬 **뒤**(마지막 `}` 앞)에 온보딩 Window 씬 추가:

```swift
        Window("환영", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
```

- [ ] **Step 3: 빌드 확인 (Task 6 전까지 MenuBarView/Label 시그니처 불일치로 실패 예상)**

Run: `swift build`
Expected: `MenuBarView`/`MenuBarLabel`에 `fdaModel` 파라미터가 아직 없어 **컴파일 에러**(`extra argument 'fdaModel'`). 이는 Task 6에서 해소된다. (원자적 커밋을 원하면 Step 4를 Task 6과 합쳐도 됨.)

- [ ] **Step 4: (Task 6 완료 후) 커밋** — 이 태스크의 파일은 Task 6과 함께 빌드가 성립하므로, 커밋은 Task 6 Step 6에서 함께 수행한다.

---

### Task 6: MenuBarView affordance + 첫 팝오버 온보딩 트리거 + didBecomeActive

**Files:**
- Modify: `Sources/TrimMyMacApp/MenuBarView.swift` (`MenuBarLabel`, `MenuBarView`)

**Interfaces:**
- Consumes: `FullDiskAccessModel` (Task 3), `FullDiskAccessGate` / `FDAAffordance` (Task 2), `FullDiskAccessProbe.openSettings()` (Task 3)

- [ ] **Step 1: MenuBarLabel에 모델 + didBecomeActive 재감지** — `Sources/TrimMyMacApp/MenuBarView.swift`의 `struct MenuBarLabel: View {` 내 `@ObservedObject var processMonitor: ProcessMonitor` 아래에 추가:

```swift
    @ObservedObject var fdaModel: FullDiskAccessModel
```

같은 뷰 `body`의 `.onReceive(tick) { _ in refresh() }` 아래에 추가:

```swift
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fdaModel.refresh()
        }
```

- [ ] **Step 2: MenuBarView에 모델 + affordance/온보딩 상태** — `struct MenuBarView: View {` 내 `@ObservedObject var updater: UpdaterModel` 아래에 추가:

```swift
    @ObservedObject var fdaModel: FullDiskAccessModel
    @AppStorage("onboarding.fdaSeen") private var fdaSeen = false
```

- [ ] **Step 3: affordance 스트립을 헤더 아래에 삽입** — `MenuBarView.body`의 `header` 바로 다음 줄(`Divider()` 앞)에 삽입:

```swift
            fdaAffordance
```

그리고 `MenuBarView`에 뷰 프로퍼티 추가(예: `pressurePill` 근처):

```swift
    @ViewBuilder
    private var fdaAffordance: some View {
        switch FullDiskAccessGate.affordance(for: fdaModel.status) {
        case .strip:
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.orange)
                Text("전체 디스크 접근 꺼짐 — 디스크 기능 제한").font(.caption)
                Spacer()
                Button("켜기") { FullDiskAccessProbe.openSettings() }.controlSize(.small)
            }
            .padding(8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .quietLink:
            Button("전체 디스크 접근 설정 열기") { FullDiskAccessProbe.openSettings() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .hidden:
            EmptyView()
        }
    }
```

- [ ] **Step 4: 첫 팝오버 온보딩 트리거 + refresh를 onAppear에** — `MenuBarView.body`의 기존 `.onAppear(perform: refresh)`를 아래로 교체:

```swift
        .onAppear {
            refresh()
            fdaModel.refresh()
            if !fdaModel.onboardingRequestedThisLaunch,
               FullDiskAccessGate.shouldShowOnboarding(seen: fdaSeen, status: fdaModel.status) {
                fdaModel.onboardingRequestedThisLaunch = true
                openWindow(id: "onboarding")
            }
        }
```

(참고: `openWindow`는 이 뷰에 이미 `@Environment(\.openWindow) private var openWindow`로 존재한다.)

- [ ] **Step 5: 빌드 + 전체 회귀**

Run: `swift build && ./scripts/test.sh`
Expected: `Build complete!`; 테스트 `... 133 tests ... passed`, 실패 0. (Task 5의 App 변경과 이 태스크로 시그니처가 맞아 빌드 성립.)

- [ ] **Step 6: Task 5 + 6 함께 커밋**

```bash
git add Sources/TrimMyMacApp/TrimMyMacApp.swift Sources/TrimMyMacApp/FullDiskAccess.swift Sources/TrimMyMacApp/MenuBarView.swift
git commit -m "feat(fda): 팝오버 affordance(strip/quietLink/hidden) + 첫 팝오버 온보딩 1회 + didBecomeActive 재감지"
```

- [ ] **Step 7: 앱 빌드 + 수동 스모크** (앱 계층은 단위테스트 불가 — 실동작 확인)

Run: `./scripts/build-app.sh && open /Applications/TrimMyMac.app`
확인:
- FDA 미허용 상태에서 메뉴바 팝오버 처음 열기 → **온보딩 창 1회** 표시(정직 문구 + [지금 허용]/[나중에]). 닫고 다시 팝오버 열어도 **재노출 안 됨**.
- 팝오버 헤더 아래 **앰버 "디스크 기능 제한" 스트립 + [켜기]**.
- [켜기]/[지금 허용] → System Settings FDA 창 열림.
- FDA를 켜고 (필요 시 앱 재실행) 팝오버 다시 열기 → 스트립 **사라짐**.
- 정크/중복 패널의 "권한 설정 열기"도 동일 동작(딥링크 통합 확인).

---

## Self-Review

**1. Spec coverage:**
- §4.1 tri-state/probeStatus/Gate/FDAAffordance → Task 1·2. ✅
- §4.1 FullDiskAccessModel(동기 init) + FullDiskAccessProbe → Task 3. ✅
- §4.2 probe 지점(com.apple.TCC) → Task 3. ✅
- §4.3 재감지(init/onAppear/didBecomeActive) → Task 3(init)·6(onAppear·didBecomeActive). ✅
- §4.4 affordance strip/quietLink/hidden → Task 6. ✅
- §4.5 첫 팝오버 온보딩·fdaSeen on appear·per-launch 가드·정직 문구 → Task 5·6. ✅
- §4.6 딥링크 통합·한글화·배너 유지 → Task 4. ✅
- §5 테스트(probeStatus/gate) → Task 1·2. ✅ (앱 계층 unit 불가 → 빌드+스모크로 대체, Global Constraints에 명시.)
- §2 ScanDiagnostics 불변 → 어떤 태스크도 건드리지 않음. ✅

**2. Placeholder scan:** "적절히 처리" 류 없음. 모든 코드 스텝에 실제 코드 포함. ✅

**3. Type consistency:** `FullDiskAccessStatus`(granted/denied/unknown), `FullDiskAccessStatus.from(probeError:)`, `FDAAffordance`(strip/quietLink/hidden), `FullDiskAccessGate.shouldShowOnboarding(seen:status:)`·`affordance(for:)`, `FullDiskAccessModel.status`·`refresh()`·`onboardingRequestedThisLaunch`, `FullDiskAccessProbe.system()`·`openSettings()` — Task 1→6 전 구간 시그니처 일치. ✅

**주의(구현자):** Task 5는 단독 빌드가 실패한다(MenuBarView/Label 시그니처가 Task 6에서 맞춰짐). Task 5·6은 한 커밋으로 완결한다(Task 6 Step 6). Task 1~4는 각자 독립 빌드·커밋 가능.
