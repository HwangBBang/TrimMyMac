# 전체 디스크 접근(FDA) 안내 UX — 설계

- 날짜: 2026-07-01
- 브랜치: feature/resource-optimize (또는 후속 브랜치)
- 상태: 설계 확정, 구현 계획 대기

## 1. 문제

TrimMyMac의 디스크 기능(정크 정리·중복 파일·앱 삭제)은 macOS **전체 디스크 접근(Full Disk Access, FDA)** 권한이 있어야 `~/Library` 하위를 스캔·정리할 수 있다. 현재 앱은 이 권한을 **능동적으로 안내하지 않는다**:

- FDA UX가 전부 **반응형(reactive)** 이다 — 스캔이 권한 거부를 만나거나 삭제가 실패해야만 안내가 뜬다.
- 항상 보이는 주 표면인 **메뉴바 팝오버에는 FDA 표시가 전혀 없다** — 사용자는 실패를 겪기 전까지 권한이 필요한지조차 모른다.
- 첫 실행 온보딩이 없다.

사용자는 직접 System Settings를 파고들어 FDA를 켜야 했고, 앱이 이를 안내해야 한다고 요청했다.

## 2. 목표 / 비목표

### 목표
- **능동 감지**: 실패를 유발하지 않고 FDA 부여 여부를 파악한다.
- **팝오버 상시 affordance**: 미허용이면 팝오버에 켜기 유도를 표시하고, 허용되면 조용히 사라진다.
- **첫 실행 온보딩**: 첫 실행 시 1회, FDA를 정직하게 안내하는 단일 시트.
- **허용 후 자동 해제**: 사용자가 System Settings에서 켜고 돌아오면 안내가 자동으로 사라진다.
- **정직 프레이밍**: FDA는 디스크 기능에만 필요하고 모니터링·최적화는 FDA 없이 동작한다는 사실을 숨기지 않는다.

### 비목표 (YAGNI)
- 멀티스텝 온보딩 마법사.
- 온보딩 재노출 토글/설정.
- 자동 권한 부여 (macOS TCC 설계상 불가 — 사용자만 가능).
- 스캔/정리 로직 변경.
- 기존 반응형 배너/시트 제거 (별개 역할이라 유지).

## 3. 현재 상태 (있는 것)

- `TrimCore/FullDiskAccess.swift` — `FullDiskAccessClassifier`: 임의의 `Error`가 TCC 권한 벽(`EPERM`/`EACCES`, `NSFileReadNoPermissionError` 등)인지 순수 판별. **재사용한다.**
- `TrimMyMacApp/FullDiskAccess.swift` — `FullDiskAccessSheet`: 설명 + "Open System Settings" 딥링크 + Retry/Close. 현재 **영어**. UninstallPanel에서 삭제 실패 시 `.sheet`로 사용.
- `JunkPanel`/`DuplicatePanel` — 스캔이 못 읽은 위치가 있으면 앰버 **permissionBanner**("N곳 못 읽음, 결과 일부"). 딥링크 URL 인라인 중복.
- FDA 딥링크 URL(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`)이 **3곳에 중복**.

## 4. 설계

### 4.1 컴포넌트

**`FullDiskAccessModel`** (신규, `TrimMyMacApp/FullDiskAccess.swift`, `@MainActor ObservableObject`)
- `@Published private(set) var isGranted: Bool`
- `private let probe: () -> Bool` — 주입 가능(테스트용 fake)
- `func refresh()` — probe 실행 → `isGranted` 갱신
- `init(probe: @escaping () -> Bool = FullDiskAccessProbe.system)`
- 기존 모니터 패턴(`MemoryMonitor`/`ProcessMonitor`/`UpdaterModel`)과 동일. `TrimMyMacApp`에서 `@StateObject` 1개 생성 → 팝오버·온보딩이 공유 구독.
- `isGranted`는 **sticky 아님**(매 refresh마다 최신 반영) — 허용/취소 상태를 속이지 않는다.

**`FullDiskAccessProbe`** (신규, app)
- `static func system() -> Bool` — `~/Library/Application Support/com.apple.TCC` 디렉토리 읽기를 시도하고, 결과를 `probeResultIsGranted(error:)`(순수, TrimCore)로 해석. 실제 syscall은 이 한 곳에만.
- `static func openSettings()` — FDA 딥링크를 여는 단일 함수(기존 `FullDiskAccessSheet.openPrivacySettings` 대체·통합).

**`FullDiskAccessGate`** (신규, `TrimCore/FullDiskAccess.swift`, 순수)
- `static func shouldShowOnboarding(seen: Bool, granted: Bool) -> Bool` → `!seen && !granted`
- `static func shouldShowAffordance(granted: Bool) -> Bool` → `!granted`

**`probeResultIsGranted(error:)`** (신규, `TrimCore/FullDiskAccess.swift`, 순수)
- `error == nil` → `true`(granted)
- `FullDiskAccessClassifier.needsFullDiskAccess(for:)` == true → `false`(미허용)
- 그 외 에러(예: 이론상 `ENOENT`) → `true`(판단 불가 시 granted로 간주 — 오탐으로 사용자를 괴롭히지 않음)

### 4.2 감지 프로브

- 프로브 지점: **`~/Library/Application Support/com.apple.TCC`** — 모든 맥에 존재하고 사용자 홈 안이지만 FDA 없이는 읽기가 `EPERM`으로 막히는 표준 지점.
- 성공 → granted, `EPERM/EACCES` → 미허용. 판별은 순수 헬퍼가 담당.

### 4.3 재감지 트리거
- 앱 시작 시 1회 (온보딩 판단용).
- 팝오버 `.onAppear`.
- `NSApplication.didBecomeActiveNotification` — 사용자가 System Settings에서 켜고 앱으로 돌아오면 자동 재감지 → affordance/시트 자동 해제.

### 4.4 UI — 팝오버 affordance (MenuBarView)
- 헤더 divider 바로 아래 **슬림 스트립 1줄**, `!isGranted`일 때만 표시.
- 내용: `🔒 전체 디스크 접근 꺼짐 — 디스크 정리 제한` + **[켜기]**(→ `FullDiskAccessProbe.openSettings()`). 기존 배너와 같은 앰버 톤.
- granted면 완전히 숨김(nag 없음).

### 4.5 UI — 첫 실행 온보딩 시트
- **게이트**: `@AppStorage("onboarding.fdaSeen") == false` **AND** 미허용(`!isGranted`)일 때만. 첫 실행에 이미 허용돼 있으면 띄우지 않는다.
- 표시: 전용 `Window("환영", id: "onboarding")` 씬. 시작 시점 훅(`MenuBarLabel.onAppear` — `openWindow` 사용 가능 여부를 구현 중 검증; 불가하면 첫 팝오버 오픈 시로 폴백)에서 조건 충족 시 오픈.
- 내용(정직 프레이밍):
  > **TrimMyMac**
  > 메모리·CPU·압력 모니터링과 최적화는 **지금 바로** 동작합니다.
  > 정크 정리·중복 파일·앱 삭제처럼 디스크를 뒤지는 기능만 **전체 디스크 접근(FDA)** 이 필요합니다.
  >
  > [지금 허용] [나중에]
  > _나중에 팝오버에서 언제든 켤 수 있어요._
- [지금 허용] → `openSettings()` + 닫기. [나중에] → 닫기. 둘 중 무엇이든 `onboarding.fdaSeen = true` 설정 → 재노출 없음.

### 4.6 기존 반응형 정리 (작업 중 코드의 타깃 개선)
- 딥링크 URL 3곳 중복 → `FullDiskAccessProbe.openSettings()` 한 곳으로 통합, 전부 호출로 교체.
- `FullDiskAccessSheet` 문구 **한글화**(배너와 톤 통일).
- 배너/시트 자체는 유지 — "스캔이 N곳 못 읽음 / 결과 일부"라는 별개 역할.

## 5. 테스트 (TDD)

순수 로직은 TrimCore로 내려 결정론적으로 테스트한다. `Tests/TrimCoreTests/FullDiskAccessTests.swift`(기존) 확장:
- `FullDiskAccessGate.shouldShowOnboarding` — seen/granted 4조합.
- `FullDiskAccessGate.shouldShowAffordance` — granted true/false.
- `probeResultIsGranted(error:)` — nil / `EPERM` NSError / `EACCES` / 비권한 에러(ENOENT) 각 케이스.
- 실제 syscall 프로브·모델 배선은 얇게: 로직은 위 순수 헬퍼가 담당, 앱단은 호출만. 필요 시 `FullDiskAccessModel`을 fake probe로 주입해 `isGranted` 반영 확인(앱 테스트 타깃 가능 범위 내).

## 6. 건드리는 파일
- `Sources/TrimCore/FullDiskAccess.swift` — `FullDiskAccessGate` + `probeResultIsGranted(error:)` 순수 추가.
- `Sources/TrimMyMacApp/FullDiskAccess.swift` — `FullDiskAccessModel` + `FullDiskAccessProbe` + `OnboardingView`; `FullDiskAccessSheet` 한글화·딥링크 통합.
- `Sources/TrimMyMacApp/TrimMyMacApp.swift` — `@StateObject fdaModel`, 온보딩 `Window` 씬, `didBecomeActive` 배선, MenuBarView에 모델 전달.
- `Sources/TrimMyMacApp/MenuBarView.swift` — affordance 스트립.
- `Sources/TrimMyMacApp/Panels/{JunkPanel,DuplicatePanel}.swift` — 인라인 딥링크 → `openSettings()` 호출로 교체.
- `Tests/TrimCoreTests/FullDiskAccessTests.swift` — 순수 게이트/프로브 결과 테스트 확장.

## 7. 정직성 노트
FDA는 디스크 기능에만 필요하고 모니터링·최적화는 없어도 동작한다. 온보딩·affordance는 이를 명시하며, 이미 허용된 상태면 아무것도 요구하지 않는다. purge 버튼을 거부한 것과 같은 원칙 — 사용자에게 필요 이상을 강요하거나 상태를 왜곡하지 않는다.
