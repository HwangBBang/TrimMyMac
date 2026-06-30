import Foundation
import Combine
import Sparkle

/// Thin wrapper around Sparkle's standard updater so SwiftUI views can trigger
/// an update check (and observe whether one is allowed) without importing Sparkle
/// themselves. Background scheduled checks are driven by the Info.plist keys
/// (SUFeedURL / SUPublicEDKey / SUEnableAutomaticChecks / SUScheduledCheckInterval).
@MainActor
final class UpdaterModel: ObservableObject {
    /// Mirrors `updater.canCheckForUpdates` so a button can disable itself mid-check.
    @Published var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → starts the updater and its scheduled checks.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// User-initiated check; shows Sparkle's UI (up-to-date / available / error).
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
