import Foundation

/// Collects locations a scan could not read because of a permission denial (missing
/// Full Disk Access / TCC). Lets the UI say "some locations were skipped — grant Full
/// Disk Access" instead of silently presenting a partial scan as a clean, complete one.
/// Thread-safe; passed optionally into the scanners (nil = no diagnostics collected).
public final class ScanDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    public init() {}

    public func recordUnreadable(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(url)
    }

    /// Distinct locations skipped due to a permission error, in first-seen order.
    public var unreadable: [URL] {
        lock.lock(); defer { lock.unlock() }
        var seen = Set<String>()
        return recorded.filter { seen.insert($0.path).inserted }
    }

    public var hasUnreadable: Bool {
        lock.lock(); defer { lock.unlock() }
        return !recorded.isEmpty
    }
}

/// True when an error denotes a permission/TCC denial (POSIX EACCES/EPERM or
/// NSFileReadNoPermissionError), as opposed to "not found" or other I/O failures.
/// Used to record only permission problems — a missing optional directory is not noise.
public func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
    if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM)) { return true }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
       underlying.domain == NSPOSIXErrorDomain,
       underlying.code == Int(EACCES) || underlying.code == Int(EPERM) {
        return true
    }
    return false
}
