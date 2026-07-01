import Foundation

/// Pure classification of whether a scan/IO failure is caused by missing Full Disk Access
/// (a sandbox/TCC permission wall) versus an ordinary error (e.g. file not found).
///
/// macOS reports a TCC/permission denial as POSIX `EPERM` (errno 1). Foundation's
/// `FileManager` surfaces this as `NSFileReadNoPermissionError` (NSCocoaErrorDomain 257),
/// often with the raw POSIX error nested under `NSUnderlyingErrorKey`
/// (NSPOSIXErrorDomain, code 1). `EACCES` (13) is the classic BSD-permission denial and is
/// treated the same way for onboarding purposes. `ENOENT` (not found) is NOT a permission issue.
public enum FullDiskAccessClassifier {

    /// Map a raw POSIX errno to whether it indicates a permission wall.
    public static func needsFullDiskAccess(errno code: Int32) -> Bool {
        return code == EPERM || code == EACCES
    }

    /// Map an arbitrary `Error` (typically thrown by `FileManager` / `Scanner`) to whether it
    /// indicates a missing Full Disk Access permission. Unwraps Cocoa, POSIX, and nested errors.
    public static func needsFullDiskAccess(for error: Error) -> Bool {
        // Swift-typed POSIX error.
        if let posix = error as? POSIXError {
            return needsFullDiskAccess(errno: posix.code.rawValue)
        }

        let nsError = error as NSError

        switch nsError.domain {
        case NSPOSIXErrorDomain:
            return needsFullDiskAccess(errno: Int32(truncatingIfNeeded: nsError.code))

        case NSCocoaErrorDomain:
            if nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSFileWriteNoPermissionError {
                return true
            }
            // Drill into the wrapped underlying error (FileManager nests the POSIX cause here).
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return needsFullDiskAccess(for: underlying)
            }
            return false

        default:
            // Some lower-level APIs report directly via the OSStatus/Mach domains; ignore those.
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
                return needsFullDiskAccess(for: underlying)
            }
            return false
        }
    }
}

/// Three-state Full Disk Access result. `unknown` is never treated as `granted`,
/// so a genuinely-denied user whose probe returns an unexpected error is not hidden.
public enum FullDiskAccessStatus: Equatable, Sendable {
    case granted, denied, unknown

    /// Maps a probe read outcome to a status:
    /// nil error → granted; a permission wall (EPERM/EACCES/Cocoa no-permission) → denied;
    /// anything else (e.g. ENOENT) → unknown. We never guess `granted` from an error.
    public static func from(probeError error: Error?) -> FullDiskAccessStatus {
        guard let error else { return .granted }
        return FullDiskAccessClassifier.needsFullDiskAccess(for: error) ? .denied : .unknown
    }
}

/// What the popover should render for a given FDA status.
public enum FDAAffordance: Equatable, Sendable {
    case strip      // denied: amber "디스크 기능 제한" + [켜기]
    case quietLink  // unknown: no-alarm "설정 열기" link
    case hidden     // granted: nothing
}

/// Pure UI-gating decisions for Full Disk Access.
public enum FullDiskAccessGate {
    /// Onboarding shows once, only when denial is positively confirmed.
    public static func shouldShowOnboarding(seen: Bool, status: FullDiskAccessStatus) -> Bool {
        !seen && status == .denied
    }
    public static func affordance(for status: FullDiskAccessStatus) -> FDAAffordance {
        switch status {
        case .denied:  return .strip
        case .unknown: return .quietLink
        case .granted: return .hidden
        }
    }
}
