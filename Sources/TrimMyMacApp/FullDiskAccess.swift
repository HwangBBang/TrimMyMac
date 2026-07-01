import SwiftUI
import AppKit
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

/// Cross-cutting Full Disk Access onboarding. Presented as a sheet whenever a scan/uninstall
/// fails with a permission error (see `FullDiskAccessClassifier` in TrimCore).
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
