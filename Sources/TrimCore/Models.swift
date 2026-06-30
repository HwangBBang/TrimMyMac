import Foundation

public enum ItemKind: String, Sendable {
    case userCache, log, devJunk, duplicate, appLeftover, appBundle
}

public struct StatSnapshot: Equatable, Sendable {
    public let size: Int64        // st_size
    public let mtime: TimeInterval
    public let fileID: UInt64     // st_ino
    public let deviceID: Int32    // st_dev

    public init(size: Int64, mtime: TimeInterval, fileID: UInt64, deviceID: Int32) {
        self.size = size
        self.mtime = mtime
        self.fileID = fileID
        self.deviceID = deviceID
    }
}

public struct ScanItem: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let logicalSize: Int64     // sum of st_size for files under url (or st_size if file)
    public let allocatedSize: Int64   // sum of totalFileAllocatedSize
    public let kind: ItemKind
    public let snapshot: StatSnapshot // captured at scan time (of url itself)
    public var isAutoSelected: Bool
    public var evidence: String?      // ambiguous-leftover reason or clone note

    public init(
        id: UUID,
        url: URL,
        logicalSize: Int64,
        allocatedSize: Int64,
        kind: ItemKind,
        snapshot: StatSnapshot,
        isAutoSelected: Bool,
        evidence: String?
    ) {
        self.id = id
        self.url = url
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.kind = kind
        self.snapshot = snapshot
        self.isAutoSelected = isAutoSelected
        self.evidence = evidence
    }
}
