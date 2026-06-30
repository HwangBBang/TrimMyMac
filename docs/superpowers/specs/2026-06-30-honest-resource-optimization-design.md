# TrimMyMac — 정직한 리소스 최적화 + 모니터/설정 개편 (설계 v2)

- **날짜**: 2026-06-30
- **브랜치**: `feature/resource-optimize`
- **상태**: 리뷰 게이트 통과(gstack 3렌즈 + Codex `gpt-5.5 xhigh`), 사용자 결정 반영 → 구현 계획(writing-plans) 대기
- **관련 검증**: 워크플로우 `macos-memory-optimization-value` (20 에이전트)
- **리뷰 한 줄 요약**: Codex `GATE: BLOCK (MUST 8건)` — **v1에서 프로세스 종료를 빼고 Developer ID 서명 후로 연기**함으로써 종료 관련 MUST를 전부 해소했고, 나머지는 자동결정으로 반영. (§11)

---

## 1. 배경 / 동기

사용자 요청 3건:
1. **"정상" 표지가 무의미** — 메모리 압력 pill이 평소 거의 항상 "정상"이라 정보가치 없음.
2. **CleanMyMac식 메모리 최적화 + 진짜 가치 검증.**
3. **설정 UX 불편** — 팝오버 내 접이식 `DisclosureGroup`.

사용자가 명시한 최적화 목표(복수 전부): 체감 성능 개선 / 리소스 점유 가시화 + 직접 종료 / CleanMyMac 패리티 / 원클릭 "정리됨" 만족감.

---

## 2. 검증 평결 (요약)

**macOS의 "메모리 최적화 / RAM 비우기"는 2026년 적정 사양 Apple Silicon Mac에서 측정 가능한 성능 가치가 없다.**

- "free RAM 양은 성능 신호가 아니다 — memory pressure가 신호다"가 3개 렌즈 적대적 검증을 통과. Apple 1차 문서 직접 인용:
  > "When you have free or unused memory, your computer performance does not necessarily improve." — [Apple Activity Monitor 가이드](https://support.apple.com/guide/activity-monitor/check-if-your-mac-needs-more-ram-actmntr34865/mac)
- `purge`는 16GB M3에서 200–600MB만 회수 + 캐시 버려 I/O 저하 ([sweepformac](https://www.sweepformac.com/guides/mac-purge-command/)).
- iStat·Stats(38k★)·Activity Monitor 누구도 purge 버튼 없음 → 부재가 정당성의 증거.
- **기존 `decision 2: no purge button`은 옳았고 검증이 정당화.**

### 기능 매트릭스

| 후보 | 판정 | 근거 |
|---|---|---|
| 원클릭 "RAM 비우기/최적화"(purge) | 🔴 PLACEBO/HARMFUL | 적정사양 이득 0, 캐시 버려 I/O 저하 |
| 메모리 압축 강제 트리거 | 🔴 HARMFUL | CPU만 소모 |
| 캐시/inactive 청소 | 🔴 HARMFUL | 커널이 무비용 즉시 회수 |
| **메모리 hog 프로세스 종료**(확인) | 🟢 REAL | 전문가가 인정한 유일 효과적 행동 |
| **Memory-pressure 알림**(지속 red) | 🟢 REAL | Apple 승인 신호 |
| **프로세스별 메모리 가시성** | 🟢 REAL | iStat/Stats 핵심 |
| **Swap/pressure 히스토리** | 🟢 REAL | "RAM 증설?" 의사결정 |
| **디스크 정크 회수**(검토식) | 🟢 REAL·무희생 | 진짜 GB, 되돌림 가능(휴지통) |

---

## 3. 목표 / 비목표 + 범위 결정

### 4가지 사용자 가치 — v1에서의 정직한 충족

| 사용자 목표 | v1 구현 |
|---|---|
| 원클릭 만족감 | **디스크 정크 회수**(검토식, 진짜·지속되는 GB) = 무희생 만족감 |
| 점유 가시화 | top 메모리 소비자 **보기 전용** + 압력/swap 히스토리 |
| 체감 성능 개선 | (v-next) hog 프로세스 종료 = 유일한 진짜 레버 — **Developer ID 서명 후** |
| CleanMyMac 패리티 | "최적화" 버튼은 **존재**하되 진짜 일(디스크 회수)을 함 |

### 이름/포지셔닝 (결정: 하이브리드)
- 진입 버튼은 친숙한 **"최적화"**(만족감), 패널 제목·결과 문구는 **정직**(가짜 수치 없음). "만족감 + 정직" 동시 요구를 만족.

### 비목표 (REFUSE)
- 원클릭 "RAM 비우기/purge" 버튼, 캐시 강제 청소, 압축 강제, 상시 백그라운드 최적화.
- **(v1 한정) 프로세스 종료** — §10/§11 참조. Developer ID 서명·notarize 전까지 미출시.

---

## 4. 아키텍처 개요

```
TrimCore (로직, 테스트 대상)
 ├─ ProcessMonitor      [신규]  단일 enumeration 소유 + top 소비자(보기 전용, v1)
 │                              ※ AgentSessionMonitor를 흡수(분류기/projection으로 강등)
 ├─ MemoryMonitor       [확장]  timestamp 히스토리 링버퍼 + 시간기반 sustained-red
 ├─ JunkScanner·SafeRemover [재사용] "검토 후 휴지통" 디스크 회수
 └─ RunningApps         [재사용] (v-next 종료용)

TrimMyMacApp (UI)
 ├─ MenuBarView         [수정]  pill 재설계, 설정 DisclosureGroup 제거, "최적화" 버튼
 ├─ OptimizePanel       [신규]  Window id:"optimize" (v1: 진단 + 디스크 회수, 보기 전용 소비자)
 ├─ SettingsView        [신규]  Settings Scene (2탭)
 └─ TrimMyMacApp        [수정]  Settings Scene + Optimize Window 등록
```

**단일 샘플러 불변식(강화)**: enumeration·CPU delta 캐시는 **ProcessMonitor 하나만** 소유한다(AgentSessionMonitor와 이중 샘플링 금지). 무거운 proc 수집은 **메인액터 밖**(detached/utility) 에서 하고, delta 계산·`@Published` 갱신만 MainActor. 팝오버/윈도우는 읽기만.

---

## 5. 컴포넌트 상세

### 5.1 `ProcessMonitor` (TrimCore, 신규) — v1: 보기 전용

**책임**: 사용자 소유 프로세스 중 메모리 점유 상위(top-N)를 GUI 앱 + 인식된 AI 세션 통합으로 산출·표시한다. **v1에는 종료 기능 없음**(보기 전용). 단일 enumeration 패스를 소유하고 거기서 AI 세션을 derive한다.

```swift
enum ProcessKind { case app, agent, process }  // app=GUI, agent=AI세션, process=기타 사용자 프로세스
// v1은 보기 전용이므로 세 종류 모두 표시(가시성=정직). 명백한 시스템 데몬은 노이즈 필터.
// 종료 allowlist(v-next)는 app(.regular)+agent에만 적용 — process는 보기 전용으로만 남는다.
struct ProcessUsage: Identifiable, Sendable {
    let id: String           // 안정 identity: app=bundleID, agent=root pid 문자열
    let displayName: String
    let bundleID: String?
    let kind: ProcessKind
    let footprint: UInt64    // phys_footprint (Activity Monitor 일치) — RSS 합산 아님
    // cpu는 표시 top-N 행에 한해 선택 계산 (전체 prevCPU 부킹 안 함)
}
```

- 수집: 기존 `enumerateUserProcesses`(same-uid sysctl) 1회 → 각 pid의 메모리는 **`proc_pid_rusage(RUSAGE_INFO_V2).ri_phys_footprint`** 사용(공유페이지 과대계상하는 `pti_resident_size` 합산 ✗). GUI 앱 identity는 `NSRunningApplication`의 bundleID, 트리 귀속 실패(예: WebKit XPC reparent) helper는 표시에서 제외/주석.
- AI 세션: 기존 `classify`/`aggregate` 로직을 ProcessMonitor가 흡수해 derive. `AgentSessionMonitor`는 순수 분류기 helper로 강등하거나 `ProcessMonitor.agentSessions` projection으로 대체.
- 성능: 전체 same-uid proc 스캔은 utility 큐에서. 정상 압력·윈도우 미개방 시 full 스캔을 게이트(피크 빈도↓).
- 순수 헬퍼(테스트): `topN`(footprint desc), `aggregateByApp`(bundleID 귀속).
- **(v-next) 종료 API는 §10에 분리.** v1 코드엔 quit 경로를 만들지 않는다(미출시 dead path 금지).

### 5.2 `MemoryMonitor` 확장

- **히스토리 링버퍼**: `struct Sample { time: Date; pressure; swapUsed; usedRatio }` 최근 ~2분. **append는 `MenuBarLabel` 1초 tick 단일 경로에서만** (팝오버 `sample()` 호출은 append 안 함 → 팝오버 개폐가 판정 오염 금지).
- **지속-red 판정(순수, 시간기반)**: `static func sustainedCritical(_ samples: [Sample], window: TimeInterval) -> Bool` — 윈도우 내 연속 `.critical`. **슬립/타이머 갭이 낀 윈도우는 거짓 트리거 방지로 배제.** `used RAM 높음`은 트리거 아님.

### 5.3 "정상" pill 재설계 (항목 1)

| 압력 | 표시 |
|---|---|
| `.normal` | **작은 무채색 점**(완전 숨김 아님 — 메뉴바 존재감 유지, accessibility label 보강) |
| `.warning` | 🟡 주의 + 탭 가능 |
| `.critical` | 🔴 위험 · (top 소비자 1개 미리보기) + 탭 가능 |

탭 → `openWindow(id:"optimize")`. 팝오버 헤더에 압력/swap **sparkline**(쿨드 상태=플랫 플레이스홀더, 충분 샘플 전까지).

### 5.4 "최적화" 패널 (신규 Window `id:"optimize"`) — v1

진입 버튼은 팝오버에서 **단일 강조(accent) "최적화" 버튼**(액션 버튼 행의 동급 4번째 아님 — 헤드라인 가치). 패널(v1):
```
┌─ 최적화 ────────────────────────────────────┐
│ 🟢 메모리 압력: 정상   [▁▂▂▁▂] swap 0.4GB     │  ← 진단(정직)
│ ⓘ (탭) 빈 RAM은 낭비된 RAM — 우리는 '비우지' 않습니다 │  ← 점진적 노출(상시배너 아님)
│                                              │
│ 디스크 정크 회수                  ← v1 헤드라인·만족감 │
│   [스캔]  → 검토 리스트(JunkPanel 선택 UX) → [정리] │
│   결과: "1.2GB 휴지통으로 정리됨"  ← 진짜·지속 GB    │
│                                              │
│ 메모리 많이 쓰는 앱 (보기 전용)                   │
│   Google Chrome   사용 중 5.4 GB              │  ← phys_footprint, 종료 버튼 없음
│   Xcode           사용 중 4.1 GB              │
│   Claude Code     사용 중 8.2 GB             │
└──────────────────────────────────────────┘
```
- **만족감의 원천 = 디스크 회수**(되돌림 가능·무희생·실측 GB). 정크 연계는 **기존 "검토 후 휴지통" UX 재사용**(`JunkScanner`→리스트 표시→선택→`SafeRemover`). **숨은 auto-trash 금지.**
- top 소비자는 **보기 전용**("사용 중 X", `phys_footprint`). v1에 종료 버튼 없음.
- 교육 문구는 **ⓘ 점진적 노출 / first-run**(상시 배너로 액션과 충돌시키지 않음).
- **purge/free-RAM/N GB 해제 수치 없음.** 팝오버 read-only 메모리 카드는 모니터로 유지.

### 5.5 `SettingsView` + Settings Scene (항목 3)

- `Settings { SettingsView() }`(⌘,) + 팝오버 `SettingsLink { Button("설정…") }`, `DisclosureGroup` 제거.
- **2탭**: **일반**(메뉴바 표시 토글 showCPU/MEM/SSD + AI 세션 추적 agentsEnabled) / **업데이트**(버전 + Sparkle "업데이트 확인"). (4탭은 컨트롤 ~6개에 과구조 + 빈 탭 → 2탭으로 축소)
- 수동 "업데이트 확인"은 설정으로 이전하되, **"업데이트 있음" affordance는 팝오버에 유지**(Sparkle가 발견 시) — 발견성 보존.

---

## 6. 데이터 흐름

```
MenuBarLabel.tick(1s)  ── 단일 샘플러
  → memoryMonitor.sample()  + history append (이 경로에서만)
  → cpuMonitor.sample()
  → processMonitor.sample() (utility 큐 수집 → MainActor publish; 정상·윈도우닫힘 시 게이트)
  → @Published 갱신
       ↑ 읽기 전용
  MenuBarView · OptimizePanel · SettingsView  (sample 호출 안 함; 디스크만 자체 refresh)
```

---

## 7. 안전 (v1)

- **v1엔 프로세스 종료가 없다** → 비가역 손실 표면 0. 리소스 뷰는 **보기 전용.**
- 디스크 회수는 기존 안전 모델 그대로: **휴지통 기반·검토 후·선택 기반·TOCTOU 가드**(`SafeRemover`).
- (v-next 종료 기능의 안전 요구는 §10에 분리 명시.)

---

## 8. 테스트

TrimCore 순수 로직(기존 106개 스타일):
- `ProcessMonitor`: `topN`(footprint 정렬), `aggregateByApp`(bundleID 귀속), unknown/background **비노출** 보장.
- `MemoryMonitor`: timestamp 링버퍼 append/trim, `sustainedCritical`(시간기반, **갭 배제** 경계), **팝오버 read 경로가 history를 append하지 않음** 검증.
- UI: pill 상태 전환, OptimizePanel 로딩/빈/에러 상태, 디스크 회수 검토 흐름 — 수동 스모크 + 순수 로직 분리.
- `swift test`/CI(macos-26) 그린이 완료 기준.

---

## 9. 결정 기록

1. **decision 2 (no purge) 유지** — 검증이 정당화.
2. **v1 = 읽기전용 모니터 + 정직한 디스크 회수**; **프로세스 종료는 Developer ID 서명·notarize 후 v-next로 연기**(사용자 결정). 근거: 종료 기능이 Codex 8 MUST의 대부분 + 멀웨어 오인·서명 리스크의 근원.
3. **이름 = 하이브리드** — 버튼 "최적화", 내용·결과 정직(사용자 결정).
4. **만족감 = 디스크 회수**(무희생·지속 GB), 프로세스 종료 아님.
5. **메모리 수치 = `phys_footprint`** "사용 중 X" (RSS 합산 "N GB 해제" 폐기).
6. **ProcessMonitor 단일 enumeration 소유**, AgentSessionMonitor 강등, 메인액터 밖 수집.
7. **history: timestamp + 1초 단일 append + 시간기반 판정**.
8. pill normal=무채색 점 · Settings 2탭 · "업데이트 있음" affordance 유지 · 교육 점진적 노출.
9. 새 작업은 최신 main에서 분기(`feature/resource-optimize`).

---

## 10. 범위: v1 vs v-next

### v1 (이번 구현)
pill 재설계 + 압력/swap 히스토리 + Settings Scene(2탭) + "최적화" 패널(진단 + **검토식 디스크 회수** + **보기 전용** top 소비자) + ProcessMonitor(읽기전용, AgentSessionMonitor 흡수) + 하이브리드 네이밍.

### v-next (Developer ID 서명·notarize **이후**)
**프로세스 종료** 기능. 게이트: Developer ID signing + notarization + 명확한 사용자 고지. 종료 설계 요구(구현 시):
- **allowlist만 종료 가능**: `NSRunningApplication.activationPolicy == .regular` GUI 앱 + 인식된 agent. unknown/background/데몬은 보기 전용·종료 불가.
- **비동기 종료 상태**: `requestSent / exited / stillRunning / timedOut / deniedByPolicy`. UI·수치는 **pid 소멸 확인 후**에만 갱신.
- **TOCTOU**: kill 직전 pid의 comm·시작시각 재검증.
- **AI 세션 별도 risk tier**: 진행 중 세션 복구불가 가능 → 강한 2단계 확인("작업/세션이 복구되지 않을 수 있음") 또는 view-only/reveal/open-terminal. 기본 view-only 권장(별도 opt-in).
- 종료 결과 표기: 행위 기반("Claude Code 종료됨"), "해제 GB"는 전후 delta 확인 시에만.

### 이 spec 범위 밖
- 기타 미착수(UninstallPanel F4 배너, 정식 릴리스, AI 세션 정렬 UX).

---

## 11. 리뷰 게이트 기록

- **gstack 3렌즈**(전략·엔지니어링·디자인 독립 서브에이전트) + **Codex `gpt-5.5 xhigh`** 독립 리뷰. 다른 모델 간 **합의 6/6** + Codex `GATE: BLOCK (MUST 8건)`.
- **MUST 처리 매핑**:
  - 종료 관련(allowlist·비동기 상태·AI세션 risk·서명·denylist 충돌) → **v1에서 종료 제외로 해소**(§10 v-next 요구로 이관).
  - RSS "N GB 해제" → **phys_footprint·디스크 회수로 대체**(자동결정 §9.5).
  - 정크 숨은 auto-trash → **검토식 재사용**(§5.4).
  - ProcessMonitor 이중 enumeration → **단일 소유**(§4, §5.1).
  - history 오염 → **1초 단일 append + timestamp**(§5.2).
- **사용자 결정 2건**: v1 범위(종료 연기), 하이브리드 네이밍 — 반영됨.
