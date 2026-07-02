# Changelog

이 프로젝트의 모든 주목할 변경을 기록한다.
포맷은 [Keep a Changelog](https://keepachangelog.com/ko/1.1.0/)를 따르고,
버전 규칙은 [Semantic Versioning](https://semver.org/lang/ko/)(`MAJOR.MINOR.PATCH`)을 따른다.

버전 단일 출처는 루트의 `VERSION` 파일이다. 릴리스 시: `VERSION` bump →
아래 `[Unreleased]`를 `[<버전>] - <날짜>`로 확정 → `git tag v<버전>` 푸시
(→ `release.yml`이 빌드·EdDSA appcast·GitHub Release 발행).

## [Unreleased]

## [0.1.0] - 2026-07-02

### Added
- 메뉴바 리소스 모니터: 메모리 압력 pill(정상=무채색 점, 주의/위험=탭하면 최적화), CPU·메모리·디스크 사용률, 압력/사용률 sparkline.
- 최적화 창: 압력 진단 + "빈 RAM은 낭비" 정직 교육, 실제 회수되는 디스크 정크 정리 진입, 메모리 많이 쓰는 프로세스 보기 전용 목록("사용 중 X", phys_footprint).
- AI 세션 모니터: Claude Code·Codex 세션별 메모리(서브트리 집계) + 프로젝트(cwd) 식별자로 동종 세션 구분.
- 네이티브 Settings 창(일반/업데이트 2탭), 메뉴바 표시 토글, AI 세션 추적 토글.
- 전체 디스크 접근(FDA) 안내: 능동 감지(tri-state) 팝오버 affordance + 첫 팝오버 오픈 온보딩(정직 프레이밍, 정확히 1회).
- 정크 정리·중복 파일·앱 삭제 디스크 도구.
- Sparkle 자동 업데이트(EdDSA) + CI/CD(build/test, `v*` 태그 릴리스).

### Changed
- 릴리스 버전을 `VERSION` 파일 단일 출처로 통일; `CFBundleVersion`은 커밋 수(`git rev-list --count HEAD`)로 자동 증가.

### Notes
- 코드 서명: 자체서명(Developer ID/notarize 아님). 개인용 전제 — 다른 맥에서는 Gatekeeper 우클릭-열기 필요. Sparkle 업데이트는 EdDSA라 정상 동작.
