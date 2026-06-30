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
