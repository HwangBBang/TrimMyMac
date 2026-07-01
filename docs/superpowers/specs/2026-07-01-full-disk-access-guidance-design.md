# 전체 디스크 접근(FDA) 안내 UX — 설계

- 날짜: 2026-07-01
- 브랜치: feature/fda-guidance
- 상태: 설계 확정 (cx-review 반영본), 구현 계획 대기
- 리뷰: Codex `gpt-5.5 xhigh` 독립 리뷰(GATE: BLOCK, MUST 2) → Phase 2 3렌즈 교차검증 반영

## 1. 문제

TrimMyMac의 디스크 기능(정크 정리·중복 파일·앱 삭제)은 macOS **전체 디스크 접근(Full Disk Access, FDA)** 권한이 있어야 `~/Library` 하위를 스캔·정리할 수 있다. 현재 앱은 이 권한을 **능동적으로 안내하지 않는다**:

- FDA UX가 전부 **반응형(reactive)** 이다 — 스캔이 권한 거부를 만나거나 삭제가 실패해야만 안내가 뜬다.
- 항상 보이는 주 표면인 **메뉴바 팝오버에는 FDA 표시가 전혀 없다** — 사용자는 실패를 겪기 전까지 권한이 필요한지조차 모른다.
- 첫 실행 온보딩이 없다.

사용자는 직접 System Settings를 파고들어 FDA를 켜야 했고, 앱이 이를 안내해야 한다고 요청했다.

## 2. 목표 / 비목표

### 목표
- **능동 감지**: 실패를 유발하지 않고 FDA 상태(**허용/거부/불명**)를 파악한다.
- **팝오버 상시 affordance**: 거부면 켜기 유도, 불명이면 조용한 설정 링크, 허용이면 아무것도 표시 안 함.
- **온보딩**: 사용자가 팝오버를 처음 열 때 1회, FDA를 정직하게 안내하는 단일 시트.
- **허용 후 해제**: 사용자가 System Settings에서 켜고 돌아오면(그리고 macOS 반영 후) 안내가 사라진다.
- **정직 프레이밍**: FDA는 디스크 기능에만 필요하고 모니터링·최적화는 FDA 없이 동작한다는 사실을 숨기지 않는다. 상태 불명을 "허용됨"으로 위장하지 않는다.

### 비목표 (YAGNI)
- 멀티스텝 온보딩 마법사.
- 온보딩 재노출 토글/설정.
- 자동 권한 부여 (macOS TCC 설계상 불가 — 사용자만 가능).
- 스캔/정리 로직 변경. **`ScanDiagnostics.isPermissionError`를 `FullDiskAccessClassifier`로 통합하는 DRY 클린업은 반응형 스캐너 경로를 건드리므로 이 기능에서 제외**(별도 클린업으로 분리; cx-review needs-codex-recall 항목).
- 로그인 시 자동 팝업 창(포커스 탈취) — 온보딩은 첫 팝오버 오픈 컨텍스트에서만.

## 3. 현재 상태 (있는 것)

- `TrimCore/FullDiskAccess.swift` — `FullDiskAccessClassifier`: 임의의 `Error`가 TCC 권한 벽(`EPERM`/`EACCES`, `NSFileReadNoPermissionError` 등)인지 순수 판별. **재사용한다.**
- `TrimMyMacApp/FullDiskAccess.swift` — `FullDiskAccessSheet`: 설명 + "Open System Settings" 딥링크 + Retry/Close. 현재 **영어**. UninstallPanel에서 삭제 실패 시 `.sheet`로 사용.
- `JunkPanel`/`DuplicatePanel` — 스캔이 못 읽은 위치가 있으면 앰버 **permissionBanner**("N곳 못 읽음, 결과 일부"). 딥링크 URL 인라인 중복.
- FDA 딥링크 URL(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`)이 **3곳에 중복**.
- 별개의 `ScanDiagnostics.isPermissionError`(ScanDiagnostics.swift)가 존재 — 이번 스코프에서 **건드리지 않는다**.

## 4. 설계

### 4.1 컴포넌트

**`FullDiskAccessStatus`** (신규, `TrimCore/FullDiskAccess.swift`, 순수 enum)
```
enum FullDiskAccessStatus { case granted, denied, unknown }
```
- `unknown`을 절대 `granted`로 접지 않는다 — 진짜 거부 상태를 은폐하지 않기 위함(MUST1).

**`FullDiskAccessModel`** (신규, `TrimMyMacApp/FullDiskAccess.swift`, `@MainActor ObservableObject`)
- `@Published private(set) var status: FullDiskAccessStatus`
- `private let probe: () -> FullDiskAccessStatus` — 주입 가능(테스트용 fake)
- `func refresh()` — probe 실행 → `status` 갱신
- `init(probe: ... = FullDiskAccessProbe.system)` — **init에서 동기 probe 1회**로 초기 상태 확정(기본 false로 시작해 첫 probe 전 게이트가 오평가되는 경쟁 제거). 동기 probe는 서브-ms 디렉토리 읽기.
- 기존 모니터 패턴(`MemoryMonitor`/`ProcessMonitor`/`UpdaterModel`)과 동일. `TrimMyMacApp`에서 `@StateObject` 1개 생성 → 팝오버·온보딩이 공유 구독.
- `status`는 **sticky 아님**(매 refresh마다 최신 반영) — 상태를 속이지 않는다.

**`FullDiskAccessProbe`** (신규, app)
- `static func system() -> FullDiskAccessStatus` — `~/Library/Application Support/com.apple.TCC` 디렉토리 읽기를 시도하고 결과를 `probeStatus(error:)`(순수, TrimCore)로 해석. 실제 syscall은 이 한 곳에만. **주석에 "non-sandboxed LSUIElement 앱 전제" 명시**(App Sandbox 도입 시 EPERM/EACCES는 FDA 부족이 아니라 컨테이너 제한 → 그땐 별도 상태 필요).
- `static func openSettings()` — FDA 딥링크를 여는 단일 함수(기존 `FullDiskAccessSheet.openPrivacySettings` 대체·통합).

**`FullDiskAccessGate`** (신규, `TrimCore/FullDiskAccess.swift`, 순수)
- `static func shouldShowOnboarding(seen: Bool, status: FullDiskAccessStatus) -> Bool` → `!seen && status == .denied` (불명/허용에는 온보딩 안 띄움)
- `enum FDAAffordance { case strip, quietLink, none }`
- `static func affordance(for status: FullDiskAccessStatus) -> FDAAffordance` → `.denied → .strip`("디스크 기능 제한" 앰버 스트립), `.unknown → .quietLink`(알람 없는 "설정 열기"), `.granted → .none`

**`probeStatus(error:)`** (신규, `TrimCore/FullDiskAccess.swift`, 순수)
- `error == nil` → `.granted`
- `FullDiskAccessClassifier.needsFullDiskAccess(for:)` == true → `.denied`
- 그 외 에러(예: `ENOENT`) → `.unknown` (판단 불가를 허용으로 위장하지 않음)

### 4.2 감지 프로브
- 프로브 지점: **`~/Library/Application Support/com.apple.TCC`** — 모든 맥에 존재하고 사용자 홈 안이지만 FDA 없이는 읽기가 `EPERM`으로 막히는 표준 지점.
- 성공 → `.granted`, `EPERM/EACCES` → `.denied`, 그 외 → `.unknown`. 판별은 순수 헬퍼가 담당.

### 4.3 재감지 트리거
- 앱/모델 init 시 동기 probe 1회 (초기 상태 확정).
- 팝오버 `MenuBarView.onAppear` — affordance 갱신 + 온보딩 판단.
- `NSApplication.didBecomeActiveNotification` — 사용자가 System Settings에서 켜고 앱으로 돌아오면 재감지 → affordance 갱신.
- **주의(정직)**: macOS는 실행 중 앱에 FDA를 부여하면 재시작 전까지 반영되지 않는 경우가 많다. 따라서 didBecomeActive 재감지가 여전히 `.denied`를 읽을 수 있으므로, "즉시 사라짐"을 약속하지 않고 **재시작 가능성을 문구로 정직 고지**한다(§4.5, §4.6).

### 4.4 UI — 팝오버 affordance (MenuBarView)
- 헤더 divider 바로 아래, `status`에 따라:
  - `.denied` → **슬림 앰버 스트립 1줄**: `🔒 전체 디스크 접근 꺼짐 — 디스크 기능 제한` + **[켜기]**(→ `openSettings()`)
  - `.unknown` → **알람 없는 조용한 링크**: "전체 디스크 접근 설정 열기"(스트립/경고 스타일 없음)
  - `.granted` → **표시 없음**(nag 안 함). didBecomeActive/onAppear 재감지로 반영.
- 문구는 스캔 배너("이번 결과 일부")와 구분: strip은 **사전 안내**("디스크 기능 제한").

### 4.5 UI — 온보딩 시트 (첫 팝오버 오픈)
- **트리거**: `MenuBarView.onAppear`에서 `shouldShowOnboarding(seen:status:)`이 참이면 `openWindow(id:"onboarding")`. 팝오버 컨텍스트라 `openWindow`가 확실히 동작하고, 사용자가 방금 메뉴바를 눌러 **앱이 이미 frontmost** → `NSApp.activate` 불필요(로그인 포커스 탈취 없음).
- **게이트**: `@AppStorage("onboarding.fdaSeen") == false` **AND** `status == .denied`. 허용/불명이면 안 띄운다(있는 걸 또 묻지 않음).
- **정확히 1회 보장(MUST2)**: `onboarding.fdaSeen = true`를 **버튼 클릭이 아니라 창을 실제로 여는 시점(OnboardingView.onAppear)** 에 기록한다. 추가로 `TrimMyMacApp`에 인메모리 `hasRequestedOnboardingThisLaunch` 가드를 두어 onAppear/didBecomeActive 이중 트리거를 한 실행에서 1회로 제한. → X/Cmd-W/종료로 닫아도 재노출 안 됨.
- 내용(정직 프레이밍):
  > **TrimMyMac**
  > 메모리·CPU·압력 모니터링과 최적화는 **지금 바로** 동작합니다.
  > 정크 정리·중복 파일·앱 삭제처럼 디스크를 뒤지는 기능만 **전체 디스크 접근(FDA)** 이 필요합니다.
  >
  > [지금 허용] [나중에]
  > _macOS가 요청하면 앱을 다시 열어야 반영될 수 있어요. 나중에 팝오버에서 언제든 켤 수 있어요._
- [지금 허용] → `openSettings()` + 닫기. [나중에] → 닫기. (둘 다 이미 표시 시점에 `fdaSeen=true` 기록됨.)

### 4.6 기존 반응형 정리 (작업 중 코드의 타깃 개선)
- 딥링크 URL 3곳 중복 → `FullDiskAccessProbe.openSettings()` 한 곳으로 통합, 전부 호출로 교체.
- `FullDiskAccessSheet` 문구 **한글화**(배너와 톤 통일). 필요 시 재시작 가능성 한 줄 추가.
- 배너/시트 자체는 유지 — "스캔이 N곳 못 읽음 / 결과 일부"라는 별개 역할. 문구 확정: 배너="이번 결과 일부", strip="디스크 기능 제한".
- **`ScanDiagnostics.isPermissionError` 통합은 이번 스코프 제외**(§2 비목표).

## 5. 테스트 (TDD)

순수 로직은 TrimCore로 내려 결정론적으로 테스트한다. `Tests/TrimCoreTests/FullDiskAccessTests.swift`(기존) 확장:
- `probeStatus(error:)` — nil→`.granted` / `EPERM` NSError→`.denied` / `EACCES`→`.denied` / 비권한 에러(ENOENT)→`.unknown`.
- `FullDiskAccessGate.shouldShowOnboarding(seen:status:)` — seen×{granted,denied,unknown} 조합; `.denied && !seen`만 true.
- `FullDiskAccessGate.affordance(for:)` — granted→none / denied→strip / unknown→quietLink.
- 실제 syscall 프로브·모델 배선은 얇게: 로직은 위 순수 헬퍼가 담당, 앱단은 호출만. 필요 시 `FullDiskAccessModel`을 fake probe로 주입해 `status` 반영·init 동기확정 확인.

## 6. 건드리는 파일
- `Sources/TrimCore/FullDiskAccess.swift` — `FullDiskAccessStatus` enum + `probeStatus(error:)` + `FullDiskAccessGate` 순수 추가.
- `Sources/TrimMyMacApp/FullDiskAccess.swift` — `FullDiskAccessModel` + `FullDiskAccessProbe` + `OnboardingView`; `FullDiskAccessSheet` 한글화·딥링크 통합.
- `Sources/TrimMyMacApp/TrimMyMacApp.swift` — `@StateObject fdaModel`, 온보딩 `Window("환영", id:"onboarding")` 씬, `didBecomeActive` 배선, `hasRequestedOnboardingThisLaunch` 가드, MenuBarView에 모델 전달.
- `Sources/TrimMyMacApp/MenuBarView.swift` — status별 affordance(strip/quietLink/none) + `onAppear` 온보딩 트리거.
- `Sources/TrimMyMacApp/Panels/{JunkPanel,DuplicatePanel}.swift` — 인라인 딥링크 → `openSettings()` 호출로 교체(문구는 결과-진단 유지).
- `Tests/TrimCoreTests/FullDiskAccessTests.swift` — 순수 probeStatus/게이트 테스트 확장.
- **불변**: `Sources/TrimCore/ScanDiagnostics.swift`(스코프 제외), 스캔 로직.

## 7. 정직성 노트
FDA는 디스크 기능에만 필요하고 모니터링·최적화는 없어도 동작한다. 온보딩·affordance는 이를 명시하며, 이미 허용된 상태면 아무것도 요구하지 않는다. 상태 불명을 허용으로 위장하지 않고(tri-state), 자동 해제도 macOS 재시작 요구 가능성을 정직하게 고지한다. purge 버튼을 거부한 것과 같은 원칙 — 사용자에게 필요 이상을 강요하거나 상태를 왜곡하지 않는다.

## 8. cx-review 반영 요약 (2026-07-01)
Codex 독립 리뷰(GATE: BLOCK, MUST 2) + Phase 2 3렌즈 교차검증 결과 반영:
- **MUST1** → `probeResultIsGranted:Bool`을 tri-state `FullDiskAccessStatus`로 교체(§4.1). unknown을 granted로 접지 않음.
- **MUST2** → `fdaSeen`을 창 표시 시점 기록 + 인메모리 per-launch 가드(§4.5).
- **SHOULD(순서 경쟁)** → init 동기 probe로 초기 상태 확정(§4.1).
- **SHOULD(openWindow@launch)** → 온보딩 트리거를 **첫 팝오버 오픈**으로 결정(사용자 결정) → launch-time openWindow/NSApp.activate 불필요(§4.5).
- **SHOULD(비샌드박스)** → probe 주석/테스트에 전제 명시(§4.1).
- **QUESTION(자동 해제)** → 재시작 가능성 정직 문구 채택(§4.3/4.5).
- **SHOULD(ScanDiagnostics 통합)** → 스코프 제외/defer(§2, needs-codex-recall).
- **NICE(배너 vs strip)** → 문구 구분 명시(§4.4/4.6).
