# TrimMyMac — 정직한 리소스 최적화 + 모니터/설정 개편 (설계)

- **날짜**: 2026-06-30
- **브랜치**: `feature/resource-optimize`
- **상태**: 승인됨 — 구현 계획(writing-plans) 대기
- **관련 검증**: 워크플로우 `macos-memory-optimization-value` (20 에이전트, 6면 리서치 + 4명제 × 3렌즈 적대적 반증)

---

## 1. 배경 / 동기

사용자 요청 3건:

1. **"정상" 표지가 무의미** — 팝오버 헤더 우측 메모리 압력 pill이 평소 거의 항상 "정상"이라 정보가치가 없음.
2. **CleanMyMac식 메모리 최적화를 제대로 탑재하고 싶다 + 진짜 가치 검증 필요.**
3. **설정 UX가 불편** — 팝오버 내 접이식 `DisclosureGroup`이 답답함. 별도 모달/창 희망.

사용자가 명시한 최적화 목표(복수): **체감 성능 개선 / 리소스 점유 가시화 + 직접 종료 / CleanMyMac 기능 패리티 / 원클릭 "정리됨" 만족감** — 네 가지 전부.

---

## 2. 검증 평결 (요약)

**결론: macOS의 "메모리 최적화 / RAM 비우기"는 2026년 적정 사양 Apple Silicon Mac에서 측정 가능한 성능 가치가 없다.**

- 핵심 명제 "free RAM 양은 성능 신호가 아니다 — memory pressure가 신호다"는 3개 렌즈 적대적 검증을 모두 통과. Apple 1차 문서가 직접 뒷받침:
  > "When you have free or unused memory, your computer performance does not necessarily improve. macOS obtains the best performance by efficiently using and managing all of your computer's memory." — [Apple Activity Monitor 가이드](https://support.apple.com/guide/activity-monitor/check-if-your-mac-needs-more-ram-actmntr34865/mac)
- `sudo purge`(대부분 클리너가 감싸는 명령)는 16GB M3에서 200–600MB만 회수하고 파일 캐시를 버려 이후 수 분간 I/O를 저하시킴 ([sweepformac](https://www.sweepformac.com/guides/mac-purge-command/)).
- iStat Menus·Stats(38k★)·Activity Monitor 그 누구도 purge 버튼을 넣지 않음 — 부재 자체가 정당성의 증거.
- **기존 코드의 `decision 2: no purge button`은 옳은 결정이었고, 검증이 이를 정당화함.**

**지적 정직성**: 4개 명제 중 핵심(p1)만 완전 통과했고, p2~p4는 *절대적 표현*("오직 ~만", "이득이 전혀 없다") 때문에 엣지 케이스(RAM 초과 워크로드, ML/GPU 캐시, zram, 커널 자체 압력 완화)로 반증됨. 즉 "메모리 관리는 절대 무의미"가 아니라, **"적정 사양에서 free-RAM/purge 버튼은 placebo"**가 정확한 범위.

### 기능 매트릭스

| 후보 기능 | 판정 | 근거 |
|---|---|---|
| 원클릭 "RAM 비우기/최적화"(purge) | 🔴 PLACEBO / HARMFUL | 적정사양 이득 0, 캐시 버려 I/O 저하, 200–600MB |
| 메모리 압축 강제 트리거 | 🔴 HARMFUL | CPU만 소모, OS가 더 잘 균형 |
| 캐시/inactive 청소 | 🔴 HARMFUL | 커널이 무비용 즉시 회수 → 조기 폐기 역효과 |
| **메모리 hog 프로세스 종료**(확인 후) | 🟢 REAL | 전문가가 인정한 유일하게 효과적인 행동 |
| **Memory-pressure 알림**(지속 red만) | 🟢 REAL | Apple 승인 신호; green/yellow는 무시가 정답 |
| **프로세스별 메모리 가시성** | 🟢 REAL | iStat/Stats도 핵심으로 제공 |
| **Swap/pressure 히스토리** | 🟢 REAL | "RAM 증설 필요?" 의사결정 신호 |

---

## 3. 목표 / 비목표

### 목표 — 4가지 사용자 가치를 정직하게 충족

| 사용자 목표 | 정직한 구현 |
|---|---|
| 체감 성능 개선 | hog 프로세스 graceful 종료 = 유일한 진짜 레버 |
| 점유 가시화 + 직접 종료 | top 메모리 소비자(앱·AI세션) → 원탭 종료 |
| CleanMyMac 패리티 | "최적화" 버튼은 **존재**하되 진짜 일을 함 |
| 원클릭 만족감 | 누르면 *"Claude Code 종료 → 8.2GB 작업집합 해제"* 같은 **실측 결과** (가짜 수치쇼 ✗) |

핵심 프레임 전환: **"청소(cleaning)" → "진단·통제(diagnose & control)".**

### 비목표 (REFUSE)

- 원클릭 "RAM 비우기/free-RAM/purge" 버튼.
- 캐시/inactive 메모리 강제 청소, 압축 강제 트리거.
- 상시 백그라운드 "메모리 최적화".
- (이 spec 범위 밖) Developer ID 서명, 기타 기존 미착수 항목.

---

## 4. 아키텍처 개요

```
TrimCore (로직, 테스트 대상)
 ├─ ProcessMonitor      [신규]  top 메모리 소비자 산출 + graceful 종료
 ├─ MemoryMonitor       [확장]  압력/swap 히스토리 링버퍼 + 지속-red 판정
 ├─ AgentSessionMonitor [재사용] enumerateUserProcesses / taskInfo / aggregate
 ├─ JunkScanner·SafeRemover [재사용] 옵션 정크 정리 연계
 └─ RunningApps         [재사용] NSRunningApplication graceful terminate

TrimMyMacApp (UI)
 ├─ MenuBarView         [수정]  pill 재설계, 설정 DisclosureGroup 제거, "최적화" 버튼
 ├─ OptimizePanel       [신규]  Window id:"optimize"
 ├─ SettingsView        [신규]  Settings Scene (탭형)
 └─ TrimMyMacApp        [수정]  Settings Scene + Optimize Window 등록
```

**불변식(기존 유지)**: 단일 샘플러(`MenuBarLabel`)가 1초 간격으로 delta 기반 모니터를 샘플하고, 팝오버·윈도우는 `@Published`를 **읽기만** 한다. `ProcessMonitor`도 delta CPU를 가지므로 이 규칙을 따른다(메모리 RSS는 비-delta라 어디서 읽어도 무방하나, 일관성 위해 동일 샘플러가 구동).

---

## 5. 컴포넌트 상세

### 5.1 `ProcessMonitor` (TrimCore, 신규)

**책임**: 사용자 소유 프로세스 중 메모리 점유 상위(top-N by RSS)를 GUI 앱 + 감지된 AI 세션 통합으로 산출하고, 선택 프로세스를 graceful하게 종료한다. 권한·sudo 불필요(전부 same-uid; `AgentSessionMonitor`가 동일 메커니즘으로 검증됨).

**타입**:

```swift
enum ProcessKind { case app, agent, process }   // GUI 앱 / AI 세션 / 기타 사용자 프로세스

struct ProcessUsage: Identifiable, Sendable {
    let id: Int32            // 대표 pid
    let displayName: String  // 앱 localizedName / AgentKind.displayName / comm
    let bundleID: String?    // GUI 앱이면 채움 (종료 경로 결정)
    let kind: ProcessKind
    let rss: UInt64          // 프로세스 트리 합산 resident bytes
    let cpu: Int             // 코어 1개 기준 % (AgentSessionMonitor 방식)
}

enum QuitResult { case requested, notFound, excluded, failed }
```

**인터페이스(@MainActor 클래스, `@Published var top: [ProcessUsage]`)**:
- `func sample(limit: Int = 8)` — 단일 샘플러가 호출. `enumerateUserProcesses` + `taskInfo(RSS)` + 트리 합산(aggregate 일반화) → RSS desc 상위 N.
- `func quit(_ usage: ProcessUsage) -> QuitResult` — `.app`/`bundleID` → `NSRunningApplication.terminate()`(via RunningApps); 그 외 → `kill(pid, SIGTERM)`. 제외 목록에 걸리면 `.excluded`.

**순수/nonisolated 헬퍼(단위 테스트 대상)**:
- `aggregateByApp(records, appByPid) -> [ProcessUsage]` — pid를 GUI 앱/AI세션/기타로 귀속하고 트리 합산. (기존 `aggregate`를 일반화)
- `topN(_:limit:) -> [ProcessUsage]` — RSS desc, tie-break cpu desc, pid asc.
- `isExcluded(name:bundleID:pid:) -> Bool` — 자기 자신 + 핵심 시스템 프로세스(`Finder`, `Dock`, `WindowServer`, `loginwindow`, `SystemUIServer`, `ControlCenter` 등) 종료 차단.

**이름 해석**: GUI 앱은 `NSWorkspace.shared.runningApplications`의 `processIdentifier → localizedName/bundleID`. 멀티프로세스 앱(브라우저 등)은 ppid 트리로 헬퍼 프로세스를 대표 앱에 합산(가능 범위). AI 세션은 기존 분류 재사용. 매핑 실패 시 `comm`.

### 5.2 `MemoryMonitor` 확장

- **히스토리 링버퍼**: `struct MemoryHistory { samples: [(pressure, swapUsed, usedRatio)] }` 최근 N(기본 120, 1초 → 2분). 순수 append/trim 로직.
- **지속-red 판정(순수)**: `static func sustainedCritical(_ history:, window: TimeInterval) -> Bool` — 최근 `window` 동안 압력이 연속 `.critical`인지. 배지/알림 트리거에만 사용. **`used RAM 높음`은 트리거가 아님.**

### 5.3 "정상" pill 재설계 (항목 1)

`MenuBarView.pressurePill` 동작 변경:

| 압력 | 표시 |
|---|---|
| `.normal` | **숨김** (또는 아주 작은 무채색 점) — "정상" 상시 라벨 제거 |
| `.warning` | 🟡 주의 + 탭 가능 |
| `.critical` | 🔴 위험 · *(top 소비자 1개 미리보기, 예: "Claude Code")* + 탭 가능 |

- 탭 → `openWindow(id: "optimize")`.
- 팝오버 헤더에 압력/swap **sparkline**(5.2 히스토리) 추가.

### 5.4 `OptimizePanel` (신규 Window `id: "optimize"`)

레이아웃:
```
┌─ 메모리 최적화 ───────────────────────────┐
│ 🔴 메모리 압력: 위험      [▁▂▅▇▇]  swap 3.1GB  │
│ ⓘ 빈 RAM은 낭비된 RAM입니다 — 우리는 '비우지' 않습니다 │
│                                            │
│ 가장 많이 쓰는 프로세스                       │
│   Claude Code        8.2 GB   [종료]        │
│   Google Chrome      5.4 GB   [종료]        │
│   Xcode              4.1 GB   [종료]        │
│                                            │
│ ☐ 정크도 함께 정리 (실제 디스크 회수)           │
│                 [선택 항목 정리]              │
└────────────────────────────────────────┘
```
- top 소비자는 `ProcessMonitor.top` 읽기. 행별 "종료"는 confirm alert 후 `quit()`.
- 옵션 체크 시 기존 `JunkScanner`/`SafeRemover` 흐름 연계(진짜 디스크 회수, 휴지통 기반).
- **결과 토스트(실측)**: 종료한 프로세스의 RSS를 "작업집합 해제 N GB"로 표기. 절대 "RAM 비움" 표현 쓰지 않음.
- **purge 버튼 없음**(decision 2 유지). 팝오버의 read-only 메모리 카드는 모니터로 유지.

### 5.5 `SettingsView` + Settings Scene (항목 3, 확정)

- `TrimMyMacApp`에 `Settings { SettingsView() }` 추가 → ⌘, + 시스템 표준 위치.
- 팝오버 `DisclosureGroup("설정")` 제거 → `SettingsLink { Button("설정…") }`.
- `TabView` 탭: **일반 / 메뉴바 / AI / 업데이트**.
  - 메뉴바: `showCPU/showMEM/showSSD` 이전.
  - AI: `agentsEnabled` 이전.
  - 일반: (향후) 압력 알림 임계 등 수용 여지.
  - 업데이트: 버전 표기 + Sparkle "업데이트 확인" — 팝오버 `updateRow`를 여기로 **이전하고 팝오버에서는 제거**(업데이트는 일일 백그라운드 체크도 있어 수동 확인 빈도가 낮음).

---

## 6. 데이터 흐름

```
MenuBarLabel.tick(1s)
  → memoryMonitor.sample()         (+ 히스토리 append)
  → cpuMonitor.sample()
  → processMonitor.sample()        (~3초마다, agentMonitor처럼 throttle)
  → @Published 갱신
       ↑ 읽기 전용
  MenuBarView(pill·카드·sparkline) · OptimizePanel(top 리스트) · SettingsView
```
단일 샘플러 규칙 유지. `OptimizePanel`/`MenuBarView`는 샘플하지 않고 `@Published`만 읽는다.

---

## 7. 안전

- **graceful only**: `NSRunningApplication.terminate()` 또는 `SIGTERM`. **`forceTerminate`/`SIGKILL` 금지** → 앱이 미저장 작업 프롬프트를 띄울 수 있음.
- **항상 사용자 확인**: 자동 종료 없음. 행별 종료는 confirm alert.
- **범위 제한**: same-uid 프로세스만(이미 `enumerateUserProcesses`가 필터). GUI 앱 + 감지된 AI 세션만 노출(데몬·시스템 프로세스 비노출).
- **제외 목록**: 자기 자신, `Finder`, `Dock`, `WindowServer`, `loginwindow`, `SystemUIServer`, `ControlCenter` 등 종료 차단(`isExcluded`).
- **비가역 손실 0 원칙 유지**: 종료는 사용자가 재실행 가능 → 앱의 기존 안전 모델(휴지통·확인·복구가능)과 일관.

---

## 8. 테스트

기존 106개(16 suites) 스타일대로 TrimCore 순수 로직 위주:

- `ProcessMonitor`: `aggregateByApp`(트리 합산·앱 귀속), `topN`(정렬·tie-break), `isExcluded`(제외 목록).
- `MemoryMonitor`: 히스토리 링버퍼 append/trim, `sustainedCritical`(지속-red 판정 경계값).
- UI(pill 상태 전환, OptimizePanel, SettingsView): 수동 스모크 + 가능한 범위 ViewInspector류 없이 순수 로직 분리로 커버.

`swift test` / CI(macos-26) 그린 유지가 완료 기준.

---

## 9. 결정 기록

1. **decision 2 (no purge button) 유지** — 검증이 정당화.
2. **"최적화"는 별도 Window**(`id:"optimize"`) — 팝오버 과밀 회피.
3. **정크 정리 연계 = 옵션 체크박스** — 강제 아님.
4. **pill: normal 숨김** — 상시 "정상" 제거, 의미 있을 때만 노출.
5. **결과 표기 = 실측 "작업집합 해제"** — placebo 수치 금지.
6. 새 작업은 **최신 main에서 분기**(`feature/resource-optimize`) → feature/trimmymac-v1 재분기 방지.

---

## 10. 범위

- **포함**: 위 5.1–5.5 (ProcessMonitor, MemoryMonitor 확장, pill 재설계, OptimizePanel, Settings Scene).
- **제외(별도 작업)**: Developer ID 코드서명, UninstallPanel F4 배너 배선, 정식 릴리스 발행, AI 세션 정렬/합계 UX.
