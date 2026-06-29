import SwiftUI
import AppKit

/// Cross-cutting Full Disk Access onboarding. Presented as a sheet whenever a scan/uninstall
/// fails with a permission error (see `FullDiskAccessClassifier` in CleanCore).
@MainActor
struct FullDiskAccessSheet: View {
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Full Disk Access Required", systemImage: "lock.shield")
                .font(.headline)

            Text("CleanStatus needs Full Disk Access to scan and clean files under your "
                 + "~/Library folder. Grant access in System Settings, then return here and retry.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("System Settings → Privacy & Security → Full Disk Access → enable CleanStatus.")
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
