import Foundation

/// Default auto-selection across duplicate groups.
///
/// - `.exact` groups: every member except the kept original (`items[0]`) is contributed.
/// - `.cloneSuspected` groups: nothing is contributed (APFS clones share storage; trashing
///   one reclaims nothing and risks the user's intent). These must be reviewed manually.
public func autoSelectedItems(groups: [DuplicateGroup]) -> [ScanItem] {
    var result: [ScanItem] = []
    for group in groups where group.confidence == .exact {
        guard group.items.count > 1 else { continue }
        result.append(contentsOf: group.items.dropFirst())
    }
    return result
}
