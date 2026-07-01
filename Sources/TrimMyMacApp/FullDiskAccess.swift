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
            Label("Full Disk Access Required", systemImage: "lock.shield")
                .font(.headline)

            Text("TrimMyMac needs Full Disk Access to scan and clean files under your "
                 + "~/Library folder. Grant access in System Settings, then return here and retry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("System Settings → Privacy & Security → Full Disk Access → enable TrimMyMac.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open System Settings") { FullDiskAccessSheet.openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Retry") { onRetry() }
                Button("Close") { onDismiss() }
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Deep link to the Full Disk Access pane of Privacy & Security.
    /// URL: x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles
    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
