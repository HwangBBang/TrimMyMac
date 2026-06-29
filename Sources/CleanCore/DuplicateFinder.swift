import Foundation
import CryptoKit
import Darwin

// MARK: - Public contract

public enum DuplicateConfidence: String, Sendable {
    case exact, cloneSuspected
}

/// A group of 2+ physically distinct files that have identical content.
/// `items[0]` is the kept original (`isAutoSelected == false`).
/// The remaining items are `isAutoSelected == (confidence == .exact)`.
public struct DuplicateGroup: Identifiable, Sendable {
    public let id: UUID
    public let confidence: DuplicateConfidence
    public let items: [ScanItem]    // >= 2

    public init(id: UUID, confidence: DuplicateConfidence, items: [ScanItem]) {
        self.id = id
        self.confidence = confidence
        self.items = items
    }
}

/// Finds duplicate files across the given root directories.
///
/// Pipeline:
/// 1. Enumerate all regular non-empty files via `Scanner`.
/// 2. Group by `logicalSize`.
/// 3. Collapse hardlinks: files sharing `(deviceID, fileID)` are ONE physical file
///    — two links to the same inode are never reported as a deletable pair.
/// 4. Sub-group by partial hash (first 4096 bytes, SHA-256).
/// 5. Final-group by full SHA-256 (streamed in 1 MiB chunks).
/// 6. For each full-hash group of ≥ 2, probe APFS clone IDs:
///    - Shared non-zero clone ID → `.cloneSuspected`, no auto-selection.
///    - Otherwise → `.exact`, items[0] kept, rest auto-selected.
public struct DuplicateFinder {
    private let scanner: Scanner
    private let probe: any StatProbing

    public init(scanner: Scanner, probe: any StatProbing) {
        self.scanner = scanner
        self.probe = probe
    }

    public func find(in roots: [URL]) throws -> [DuplicateGroup] {
        // 1) Enumerate all real non-empty files.
        var files: [FileEntry] = []
        for root in roots {
            let entries = try scanner.enumerate(root)
            files.append(contentsOf: entries.filter { !$0.isDirectory && $0.logicalSize > 0 })
        }

        // 2) Group by logical size (only buckets with >= 2 files are candidates).
        var bySize: [Int64: [FileEntry]] = [:]
        for f in files {
            bySize[f.logicalSize, default: []].append(f)
        }

        var groups: [DuplicateGroup] = []

        for (_, sizeBucket) in bySize {
            guard sizeBucket.count >= 2 else { continue }

            // 3) Collapse hardlinks: files sharing (deviceID, fileID) are one physical file.
            //    Keep only the first representative for each inode.
            var byInode: [String: FileEntry] = [:]
            for f in sizeBucket {
                let key = "\(f.snapshot.deviceID):\(f.snapshot.fileID)"
                if byInode[key] == nil { byInode[key] = f }
            }
            let physical = Array(byInode.values)
            guard physical.count >= 2 else { continue }

            // 4) Sub-group by partial hash (first 4096 bytes).
            var byPartial: [Data: [FileEntry]] = [:]
            for f in physical {
                guard let ph = Self.partialHash(of: f.url) else { continue }
                byPartial[ph, default: []].append(f)
            }

            for (_, partialBucket) in byPartial {
                guard partialBucket.count >= 2 else { continue }

                // 5) Final-group by full SHA-256 (streamed in 1 MiB chunks).
                var byFull: [Data: [FileEntry]] = [:]
                for f in partialBucket {
                    guard let fh = Self.fullHash(of: f.url) else { continue }
                    byFull[fh, default: []].append(f)
                }

                for (_, fullBucket) in byFull where fullBucket.count >= 2 {
                    groups.append(makeGroup(fullBucket))
                }
            }
        }

        return groups
    }

    // MARK: - Group assembly

    private func makeGroup(_ entries: [FileEntry]) -> DuplicateGroup {
        // Deterministic order: oldest mtime is kept as the original; tie-break on path.
        let sorted = entries.sorted { lhs, rhs in
            if lhs.snapshot.mtime != rhs.snapshot.mtime {
                return lhs.snapshot.mtime < rhs.snapshot.mtime
            }
            return lhs.url.path < rhs.url.path
        }

        // 6) Clone probe: members sharing a non-zero clone id are APFS clones.
        let cloneIDs = sorted.map { CloneIDProbe.cloneID(of: $0.url) }
        let nonZero = cloneIDs.compactMap { $0 }.filter { $0 != 0 }
        // If there are duplicate values in nonZero, two or more files share a clone id.
        let cloneSuspected = Set(nonZero).count < nonZero.count
        let confidence: DuplicateConfidence = cloneSuspected ? .cloneSuspected : .exact

        let cloneNote = "APFS clone suspected: these files share storage extents (clone id). "
            + "Trashing a copy will not immediately reclaim disk space."

        let items: [ScanItem] = sorted.enumerated().map { (idx, f) in
            let isOriginal = idx == 0
            // items[0] never auto-selected; rest auto-selected only for exact duplicates.
            let auto = !isOriginal && (confidence == .exact)
            let evidence: String? = cloneSuspected ? cloneNote : nil
            return ScanItem(
                id: UUID(),
                url: f.url,
                logicalSize: f.logicalSize,
                allocatedSize: f.allocatedSize,
                kind: .duplicate,
                snapshot: f.snapshot,
                isAutoSelected: auto,
                evidence: evidence
            )
        }

        return DuplicateGroup(id: UUID(), confidence: confidence, items: items)
    }

    // MARK: - Hashing (file never fully held in memory)

    /// Streaming chunk size for full-hash pass: 1 MiB.
    private static let chunkSize = 1 << 20

    /// SHA-256 of the first 4096 bytes of `url`. Returns nil if unreadable.
    private static func partialHash(of url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 4096)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: head)
        return Data(hasher.finalize())
    }

    /// Full SHA-256 of `url`, computed by streaming 1 MiB chunks. Returns nil if unreadable.
    private static func fullHash(of url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = (try? fh.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}

// MARK: - APFS clone id probe via getattrlist(2) + ATTR_CMNEXT_CLONEID

private enum CloneIDProbe {
    // ATTR_CMNEXT_CLONEID = 0x00000100, placed in attrlist.forkattr.
    // FSOPT_ATTR_CMN_EXTENDED = 0x00000020 reinterprets forkattr as extended
    // common attributes (required for ATTR_CMNEXT_* family).
    // Both values are web-verified against the XNU source and Apple getattrlist(2).
    private static let attrCloneID: UInt32 = 0x00000100
    private static let optExtended: UInt32 = 0x00000020

    /// Returns the APFS data-stream (clone) id for `url`, or nil if unavailable.
    /// Two APFS clones of the same data share the same non-zero clone id.
    static func cloneID(of url: URL) -> UInt64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.forkattr = attrgroup_t(attrCloneID)

        // Buffer layout from getattrlist(2):
        //   offset 0: u_int32_t  — total returned length (always present)
        //   offset 4: u_int64_t  — ATTR_CMNEXT_CLONEID value (4-byte boundary)
        var buf = [UInt8](repeating: 0, count: 64)
        let path = url.path

        let status: Int32 = path.withCString { cpath in
            buf.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &al) { alp in
                    getattrlist(cpath, alp, raw.baseAddress, raw.count, optExtended)
                }
            }
        }
        guard status == 0 else { return nil }

        return buf.withUnsafeBytes { raw -> UInt64? in
            let len = raw.load(fromByteOffset: 0, as: UInt32.self)
            guard len >= 12 else { return nil } // 4 (length field) + 8 (clone id)
            return raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
        }
    }
}
