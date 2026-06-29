import Foundation

/// An item that was deliberately not trashed (and why).
public struct SkippedItem: Sendable {
    public let url: URL
    public let reason: String
    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// An item whose trash operation threw.
public struct FailedItem: Sendable {
    public let url: URL
    public let message: String
    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

/// Result of a batch trash operation.
public struct TrashOutcome: Sendable {
    public let trashed: [URL]
    public let skipped: [SkippedItem]
    public let failed: [FailedItem]
    public let reclaimedAllocated: Int64
    public init(trashed: [URL], skipped: [SkippedItem], failed: [FailedItem], reclaimedAllocated: Int64) {
        self.trashed = trashed
        self.skipped = skipped
        self.failed = failed
        self.reclaimedAllocated = reclaimedAllocated
    }
}

/// The ONLY deletion path in CleanStatus. Re-stats each item immediately before
/// moving it to the Trash, refusing to touch anything that changed since the scan.
/// Never calls `FileManager.removeItem` — deletions are recoverable by design.
public struct SafeRemover: @unchecked Sendable {
    private let probe: any StatProbing
    private let fileManager: FileManager

    public init(probe: any StatProbing, fileManager: FileManager) {
        self.probe = probe
        self.fileManager = fileManager
    }

    public func trash(_ items: [ScanItem]) -> TrashOutcome {
        var trashed: [URL] = []
        var skipped: [SkippedItem] = []
        var failed: [FailedItem] = []
        var reclaimedAllocated: Int64 = 0

        for item in items {
            // Re-stat at the moment of deletion. A nil result means the path is gone.
            guard let current = probe.snapshot(of: item.url) else {
                skipped.append(SkippedItem(url: item.url, reason: "no longer exists"))
                continue
            }

            // Refuse to delete anything that drifted from what we showed the user.
            let unchanged = current.size == item.snapshot.size
                && current.mtime == item.snapshot.mtime
                && current.fileID == item.snapshot.fileID
                && current.deviceID == item.snapshot.deviceID
            guard unchanged else {
                skipped.append(SkippedItem(url: item.url, reason: "changed since scan"))
                continue
            }

            do {
                try fileManager.trashItem(at: item.url, resultingItemURL: nil)
                trashed.append(item.url)
                reclaimedAllocated += item.allocatedSize
            } catch {
                failed.append(FailedItem(url: item.url, message: error.localizedDescription))
            }
        }

        return TrashOutcome(
            trashed: trashed,
            skipped: skipped,
            failed: failed,
            reclaimedAllocated: reclaimedAllocated
        )
    }
}
