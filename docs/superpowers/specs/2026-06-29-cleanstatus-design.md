# TrimMyMac — 설계안 (Codex 게이트 + 회의 반영 완료)

> 상태: 브레인스토밍 → Codex(`gpt-5.5 xhigh`) 독립 리뷰 `GATE: BLOCK(MUST 4건)` → 세계최고 개발자 회의(4 페르소나) → **6개 의사결정 확정**. 본 문서는 그 결정을 반영한 최종 설계.
> 작성일: 2026-06-29 · 리뷰파일: `~/.claude/cx-reviews/trimmymac-design-20260629-123729.md`

## 0. 한 줄 정의

macOS 메뉴바에 상주하며 **리소스를 모니터링하고, 정크/중복 파일/앱 잔여물을 안전하게(휴지통 경유) 정리**하는 **개인용** 클리너 앱.

## 1. 컨텍스트 / 제약

- **목적/대상**: 개발자 본인의 Mac에서 본인이 쓰는 **개인 도구**. 배포·정식 코드서명·앱스토어·샌드박스 **불필요**. 속도·실용 우선.
- **환경**: macOS 26.5.1 (Tahoe), Apple Silicon (arm64), Swift 6.3.2 (Command Line Tools만 — **풀 Xcode 없음**), Homebrew 있음.
- **형태**: SwiftUI + AppKit **메뉴바 앱** (`LSUIElement`), **Swift Package Manager로 빌드** (Xcode 프로젝트 아님).
- 비샌드박스 + 비배포라 App Store 앱이 못하는 것(셸 명령, `~/Library` 접근, Full Disk Access 요청)이 가능.
- 사용자는 Kotlin/Spring 백엔드 개발자 — Swift는 익숙하지 않음. 코드 가독성·구조 중요.

## 2. Codex 게이트 결정 반영 (검토 산물)

**MUST (자동 반영):**
- **③ 메모리 압력 API**: `kern.memorystatus_vm_pressure_level` sysctl을 1차 신호로 쓰지 않는다. **`DispatchSource.makeMemoryPressureSource`**(녹/황/적 이벤트) + **`host_statistics64`**(used/cached/compressed/wired) + **`sysctl vm.swapusage`**(스왑) 조합으로 읽는다. 전부 권한 불필요.
- **④ 중복 클론 처리**: `st_dev/st_ino` 비교는 **하드링크 제외**로 정확히 명명한다(클론 제외 아님). `clonefile(2)` 클론은 별도 inode + CoW extent 공유라 inode 비교로 안 걸러진다 → **`ATTR_CMNEXT_CLONEID` 프로브**로 클론 의심 표시, 불확실하면 **절감 용량을 보수적(logical/allocated 분리)으로 표기**. trash-only라 클론 오삭제해도 원본은 남음.

**제품 결정 (사용자 확정):**
| # | 항목 | 결정 |
|---|---|---|
| 1 | 휴지통 비우기(empty Trash) | **v1 제외** — "영구삭제 절대 없음" 불변식 100% 순수 유지 |
| 2 | RAM 비우기 버튼(그룹 E) | **압력/스왑 정보 카드(읽기전용)로 대체** — 동작 보장·정직. purge 액션 버튼 없음 |
| 3 | 코드 서명 / FDA 지속 | **self-signed 고정 인증서**로 서명 — 재빌드 간 cdhash 안정 → FDA 영속 |
| 4 | 앱 언인스톨러 매칭 | **exact 번들ID만 자동선택** + 근거(plist/receipt) 표시, helper/group/shared는 'ambiguous' 기본해제 |
| 5 | 중복 파일 처리 | **명백 동일(전체해시 일치)만 자동선택** + **삭제 직전 re-stat 재검증**(TOCTOU 차단), 애매/클론은 해제 |
| 6 | 아키텍처 투자 | **직접 AppKit 의존(YAGNI)** — `RunningAppProvider` 프로토콜 분리 안 함. TrimCore는 AppKit import 허용 |

## 3. v1 범위 (A~F)

| 그룹 | 기능 | 난이도/위험 |
|---|---|---|
| A. 메뉴바 모니터 | 메모리 압력(DispatchSource·host_statistics64·swap) + 디스크 여유(`volumeAvailableCapacityForImportantUsage`) 상시 표시 | easy/low |
| B. 정크 정리 | 사용자 캐시(`~/Library/Caches`) + 로그(`~/Library/Logs`) — **휴지통 비우기 제외** | easy/low |
| B+. 개발자 정크 | Xcode DerivedData · npm · SPM · CocoaPods 등 (수십 GB ROI) | easy/low |
| C. 중복 파일 탐지 | size → 부분해시 → SHA256(CryptoKit) 다단계, **하드링크 제외 + 클론 프로브**, 그룹당 1개 보존, 명백동일만 자동선택+re-stat | moderate/medium |
| D. 앱 언인스톨러 | **exact 번들ID** 기반 앱 + 잔여물(Caches/Preferences/App Support/Containers/Saved State/LaunchAgents) 제거, ambiguous 기본해제 | moderate/medium |
| E. 메모리 정보 카드 | 압력 + 스왑 사용량 **읽기전용 카드** (RAM 비우기 버튼 대체) | easy/low |
| F. 안전 인프라 | 휴지통 경유(`trashItem`) + 삭제 전 미리보기 + 작업 로그 (모든 그룹의 토대) | easy/low |

### 명시적 비범위 (배제)
- 휴지통 비우기(empty Trash) — 영구삭제라 v1 제외 (결정 1)
- RAM 비우기 액션 버튼 — purge 비관리자 동작 불가/플라시보 (결정 2, 정보 카드로 대체)
- 디스크 권한 복구(SIP로 제거·홈 ACL 파손) · 유지보수 스크립트(Tahoe서 제거) · 언어팩/바이너리 슬리밍(서명 무효화) · 메일 정리(실데이터 손상) · 악성코드 탐지(시그니처 없이 거짓안심)
- `/Library`·`/System` 영역 (SIP/관리자 — v1은 `~/홈`만)

### 나중 단계 후보
대용량/오래된 파일 찾기 · 디스크 시각화(treemap) · CPU/네트워크/배터리 위젯 · Time Machine 로컬 스냅샷 정리(`tmutil thinlocalsnapshots`) · 로그인 항목 관리 · 브라우저 데이터 정리

## 4. 아키텍처 — 엔진/UI 2계층

엔진(`TrimCore`)을 **SwiftUI 뷰 없는 로직 라이브러리**로 둔다(시스템 API·AppKit은 직접 사용 — 결정 6). 그 위에 얇은 SwiftUI 앱(`TrimMyMacApp`)을 얹는다. 단위 테스트는 파일시스템 로직(중복/정크/메트릭) 중심으로 확보한다.

```
trimmymac/
├── Package.swift                      # executable(TrimMyMacApp) + library(TrimCore) + test 타깃
├── Sources/
│   ├── TrimCore/                     # 엔진 (SwiftUI 뷰 없음; Foundation/Darwin/AppKit 사용 가능)
│   │   ├── Metrics/
│   │   │   ├── MemoryMonitor.swift    # DispatchSource.makeMemoryPressureSource + host_statistics64 + vm.swapusage
│   │   │   └── DiskMetrics.swift      # URLResourceValues volumeAvailableCapacityForImportantUsage
│   │   ├── Scan/
│   │   │   ├── Scanner.swift          # 공용 파일 탐색(재귀, 심링크 루프 가드, 취소 지원)
│   │   │   └── IgnoreRules.swift      # 화이트리스트: node_modules, *.photoslibrary, com.apple.*
│   │   ├── Junk/
│   │   │   └── JunkScanner.swift      # 캐시/로그/개발자정크 경로 → 삭제후보(경로+logical/allocated 용량)
│   │   ├── Duplicate/
│   │   │   └── DuplicateFinder.swift  # size→부분해시→SHA256, 하드링크 제외, 클론 프로브, 1개 보존
│   │   ├── Uninstall/
│   │   │   └── AppUninstaller.swift   # .app → CFBundleIdentifier(exact) → 표준 잔여물, ambiguous 표시
│   │   ├── Actions/
│   │   │   └── SafeRemover.swift      # ★모든 삭제의 유일한 통로 = FileManager.trashItem (+삭제직전 re-stat)
│   │   └── System/
│   │       └── RunningApps.swift      # NSRunningApplication/NSWorkspace 직접 사용 (quit-first 판단)
│   └── TrimMyMacApp/                      # SwiftUI 메뉴바 앱 (TrimCore 의존)
│       ├── TrimMyMacApp.swift       # @main, MenuBarExtra(.menuBarExtraStyle(.window))
│       ├── MenuBarView.swift          # 상시 모니터(메모리/디스크) + 메모리 정보 카드
│       └── Panels/
│           ├── JunkPanel.swift
│           ├── DuplicatePanel.swift
│           └── UninstallPanel.swift
├── Tests/TrimCoreTests/             # 엔진 단위 테스트 (임시 디렉토리 픽스처)
└── scripts/build-app.sh              # swift build → .app 번들 → self-signed 서명 → /Applications 설치
```

### 모듈 책임 (한 줄 정의 + 의존)
- `MemoryMonitor`/`DiskMetrics`: 메모리 압력·스왑·디스크 여유 읽기. 시스템콜은 얇은 함수 뒤에 두어 파싱 로직만 테스트.
- `Scanner` + `IgnoreRules`: "이 경로들을 훑되 이건 건너뛴다" + 취소를 모든 스캐너가 공유. 의존: Foundation.
- `JunkScanner` / `DuplicateFinder` / `AppUninstaller`: 각자 **삭제 후보 목록만 산출** — 직접 삭제 안 함. 실행중 여부가 필요한 곳은 기본값 `RunningApps.shared`를 갖는 **주입 가능 클로저**로 테스트 시 대체(프로토콜 모듈은 안 만듦 — 결정 6의 경량 seam).
- `SafeRemover`: 후보를 **휴지통으로만** 이동(`trashItem`), 이동 직전 **re-stat로 size/mtime/fileID 재확인**. 삭제는 전부 여기로 수렴 = 안전 단일 지점.
- `RunningApps`: 실행중 앱 감지(AppKit). 캐시/삭제/중복이 공유하는 quit-first 판단.
- `TrimMyMacApp`: 위 엔진을 호출하는 SwiftUI 레이어. 비즈니스 로직 없음.

## 5. UI/UX 흐름

```
메뉴바 아이콘(메모리%·디스크여유 상시) ──클릭──▶ 팝오버 패널
   ├─ 상단: 메모리 압력(녹/황/적)·스왑·디스크 여유            [실시간: DispatchSource 이벤트 + N초 폴링]
   ├─ 메모리 정보 카드  ← 읽기전용 (압력/스왑 신호, 액션 버튼 아님)
   ├─ [정크 정리]   → 스캔 → 항목·용량 미리보기 → 체크 → [휴지통으로]
   ├─ [중복 파일]   → 폴더 선택 → 스캔 → 그룹별(1개 자동 보존, 명백동일만 자동체크) → [휴지통으로]
   └─ [앱 삭제]     → 앱 드롭 → exact 잔여물 스캔(ambiguous 해제) → 미리보기 → [휴지통으로]
```

**불변 흐름**: 모든 파괴적 동작 = `스캔(읽기전용)` → `미리보기+선택` → `re-stat 재확인` → `휴지통 이동(복구가능)` → `결과 리포트`.

## 6. 안전 모델 (타협 불가 불변식)

1. **영구삭제 절대 없음** — 모든 삭제는 `FileManager.trashItem`만 (복구 가능). 휴지통 비우기 미포함이라 예외 없음.
2. **`~/홈` 영역만** — `/Library`·`/System` 손대지 않음 (SIP/권한 회피).
3. **삭제 직전 re-stat 재검증** — 스캔~삭제 사이 변경된 파일(size/mtime/fileID 불일치) skip → TOCTOU 차단.
4. **실행 중 앱 보호** — 캐시/삭제 전 `RunningApps`로 감지 → 건너뛰거나 종료 유도.
5. **하드링크 제외 + 클론 프로브** — 중복 탐지 시 하드링크(동일 inode) 제외, `clonefile` 클론은 표시·보수적 용량 표기.
6. **삭제 전 항상 미리보기** — 항목 + 총 회수 용량(logical/allocated 구분) 표시 후 확인.
7. **공용 ignore 정책** — `node_modules`, `*.photoslibrary`, `com.apple.*` 등을 전 기능이 공유.

## 7. 빌드 & 실행 (Xcode 불필요)

- `swift build -c release` → `scripts/build-app.sh`가 `TrimMyMac.app` 번들 조립:
  - `Info.plist`: `LSUIElement=true`(Dock 미표시), `CFBundleIdentifier`(고정), 아이콘, `CFBundleExecutable`.
  - **self-signed 인증서로 서명** (`security`로 1회 생성한 코드서명용 인증서, `codesign -s "<cert>"` — `--deep` 회피). 동일 번들ID+안정 cdhash → **FDA 권한 영속**.
  - `/Applications`에 설치 (안정 경로 → TCC 권한 안정).
- **FDA 온보딩**: 일부 경로(`~/Library/Containers` 하위 타 앱 데이터 등)는 Full Disk Access 필요 → `EPERM` 감지 시 시스템 설정 딥링크(`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`) 안내.
- Swift 6 strict concurrency: 스캔은 백그라운드 Task/actor, UI 갱신은 `@MainActor`, 모든 스캔은 취소 가능.

## 8. 테스트 전략 (TDD)

- `TrimCore` 파일시스템 로직을 임시 디렉토리 픽스처로 단위 테스트:
  - `DuplicateFinder`: 동일/상이/하드링크/클론 픽스처로 정확도 + 하드링크 제외 + 클론 표시 검증.
  - `JunkScanner`/`IgnoreRules`: 화이트리스트 보호, 실행중 앱 캐시 skip(주입 클로저로).
  - `SafeRemover`: 휴지통 이동 + re-stat skip 동작.
  - `MemoryMonitor`/`DiskMetrics`: 파싱 로직(고정 입력 주입).
- UI는 빌드 후 실제 실행으로 수동 확인 (메뉴바 표시 + 스캔 1회 + 휴지통 이동 + FDA 온보딩).

## 9. 빌드 순서 (구현 계획의 씨앗)

1. SPM 스캐폴드 + `build-app.sh`(번들+self-signed 서명) → 빈 MenuBarExtra가 메뉴바에 뜨는지 **가장 먼저 검증**(가장 큰 불확실성).
2. F 안전 인프라(`SafeRemover` + 미리보기) → 이후 모든 정리 기능의 토대.
3. A 모니터(메모리/디스크) → 앱의 상시 가치.
4. B/B+ 정크 정리(캐시·로그·개발자정크) → 가장 안전·고ROI.
5. C 중복, D 언인스톨러 → moderate 난이도.
