import Foundation
import AppKit

/// Closure that answers "is an app with this bundle id running?".
/// `@Sendable` so a captured snapshot can be passed to core scanners that
/// run off the main actor.
public typealias RunningCheck = @Sendable (String) -> Bool

@MainActor
public final class RunningApps {

    public static let shared = RunningApps()

    public init() {}

    /// True if any running application advertises this bundle identifier.
    public func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.bundleIdentifier == bundleID
        }
    }

    /// Politely terminate every running app matching `bundleID`.
    /// Returns whether at least one match was found.
    @discardableResult
    public func quit(bundleID: String) -> Bool {
        let matches = NSWorkspace.shared.runningApplications.filter { app in
            app.bundleIdentifier == bundleID
        }
        for app in matches {
            app.terminate()
        }
        return !matches.isEmpty
    }

    /// Capture the set of currently running bundle ids and return a
    /// `@Sendable` closure that tests membership against that frozen
    /// snapshot. Safe to call from a non-main actor.
    public func snapshotCheck() -> RunningCheck {
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        return { bundleID in running.contains(bundleID) }
    }
}
