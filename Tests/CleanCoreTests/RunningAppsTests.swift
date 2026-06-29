import Foundation
import Testing
@testable import CleanCore

@Suite("RunningApps")
struct RunningAppsTests {

    // Finder is always running on a live, logged-in macOS session.
    @Test @MainActor func finderIsRunning() {
        #expect(
            RunningApps.shared.isRunning(bundleID: "com.apple.finder"),
            "Finder should always be running on a live Mac session"
        )
    }

    @Test @MainActor func fakeBundleIDIsNotRunning() {
        let fakeID = "com.example.totally.not.real.\(UUID().uuidString)"
        #expect(
            !RunningApps.shared.isRunning(bundleID: fakeID),
            "A random fake bundle id must not report as running"
        )
    }

    // The snapshot closure must be usable as a plain @Sendable value and
    // still report Finder as running.
    @Test @MainActor func snapshotRunningCheckSeesFinder() {
        let check: RunningCheck = RunningApps.shared.snapshotCheck()
        #expect(
            check("com.apple.finder"),
            "snapshot RunningCheck should report com.apple.finder as running"
        )
        let fakeID = "com.example.totally.not.real.\(UUID().uuidString)"
        #expect(
            !check(fakeID),
            "snapshot RunningCheck must reject a fake bundle id"
        )
    }

    // Verify quit API exists and returns false for a non-running fake bundle id.
    @Test @MainActor func quitNonRunningReturnsFalse() {
        let fakeID = "com.example.totally.not.real.\(UUID().uuidString)"
        let result = RunningApps.shared.quit(bundleID: fakeID)
        #expect(!result, "quit should return false when no app with that bundle id is running")
    }
}
