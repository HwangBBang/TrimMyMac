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

        // 6) Clone probe: distinguish three outcomes per file.
        //    .indeterminate = getattrlist failed (syscall unsupported, EPERM, etc.)
        //    .none          = getattrlist succeeded; file has no clone id (value zero)
        //    .id(n)         = getattrlist succeeded; file carries non-zero clone id n
        let probeResults = sorted.map { CloneIDProbe.probeClone(of: $0.url) }
        // If EVERY probe failed, only treat the files as plain duplicates when the
        // volume genuinely cannot hold clones (non-APFS). On an APFS volume an
        // all-failed result (e.g. EPERM on every file) is indistinguishable from real
        // clones, so we confirm the filesystem before allowing auto-selection.
        let onAPFS = sorted.contains { Self.volumeIsAPFS($0.url) }
        let (cloneSuspected, cloneNote) = Self.cloneSuspicion(probeResults: probeResults, volumeIsAPFS: onAPFS)

        let confidence: DuplicateConfidence = cloneSuspected ? .cloneSuspected : .exact

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

    // MARK: - Clone suspicion (pure decision + filesystem probe)

    /// Decides whether a group of identical-content files should be treated as APFS
    /// clones (auto-selection disabled). Probe states:
    ///  - all `.indeterminate`: every clone probe failed. Auto-select ONLY when the
    ///    volume is not APFS (clones impossible); on APFS the failure could be masking
    ///    real clones (e.g. EPERM), so stay conservative — consistent with partial-fail.
    ///  - some `.indeterminate`: clone status unknown for part of the group → conservative.
    ///  - all resolved: suspect a clone iff two members share a non-zero clone id.
    nonisolated static func cloneSuspicion(
        probeResults: [CloneProbeResult],
        volumeIsAPFS: Bool
    ) -> (suspected: Bool, note: String) {
        let indeterminateCount = probeResults.filter {
            if case .indeterminate = $0 { return true }
            return false
        }.count

        if indeterminateCount == probeResults.count {
            if volumeIsAPFS {
                return (true, "APFS clone status could not be determined (probe failed for "
                    + "every file). Auto-selection disabled as a safety measure.")
            }
            // Non-APFS volume → clones are impossible; these are genuine duplicates.
            return (false, "")
        } else if indeterminateCount > 0 {
            return (true, "APFS clone status indeterminate for some files: clone id could not "
                + "be read. Auto-selection disabled as a safety measure.")
        } else {
            let nonZeroIDs: [UInt64] = probeResults.compactMap {
                if case .id(let cid) = $0 { return cid }
                return nil
            }
            let suspected = Set(nonZeroIDs).count < nonZeroIDs.count
            return (suspected, suspected
                ? "APFS clone suspected: these files share storage extents (clone id). "
                    + "Trashing a copy will not immediately reclaim disk space."
                : "")
        }
    }

    /// True if `url` resides on an APFS volume (statfs `f_fstypename`). On failure,
    /// assume APFS so the all-indeterminate path stays conservative.
    nonisolated static func volumeIsAPFS(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return true }
        let name = withUnsafeBytes(of: &fs.f_fstypename) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return name.lowercased() == "apfs"
    }

    // MARK: - Hashing (file never fully held in memory)

    /// Streaming chunk size for full-hash pass: 1 MiB.
    private static let chunkSize = 1 << 20

    /// SHA-256 of the first 4096 bytes of `url`.
    /// Returns nil if the file cannot be opened OR if a read error occurs.
    /// Uses POSIX read(2) so that a negative return value (I/O error) propagates
    /// as nil — the file is excluded from grouping — rather than being swallowed
    /// via `?? Data()` and producing a bogus hash for an unreadable file.
    private static func partialHash(of url: URL) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, 4096)
        guard n >= 0 else { return nil }  // I/O error → exclude this file
        var hasher = SHA256()
        hasher.update(data: Data(buf.prefix(n)))
        return Data(hasher.finalize())
    }

    /// Full SHA-256 of `url`, computed by streaming 1 MiB chunks.
    /// Returns nil if the file cannot be opened or if any read error occurs.
    /// A mid-stream error returns nil (file excluded) rather than being swallowed
    /// into a truncated digest that could falsely match another unreadable file.
    private static func fullHash(of url: URL) -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var hasher = SHA256()
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = Darwin.read(fd, &buf, chunkSize)
            if n < 0 { return nil }  // I/O error → exclude this file
            if n == 0 { break }      // EOF → done
            hasher.update(data: Data(buf.prefix(n)))
        }
        return Data(hasher.finalize())
    }
}

// MARK: - APFS clone id probe via getattrlist(2) + ATTR_CMNEXT_CLONEID

/// Three-state result of an APFS clone-id probe.
/// Distinguishing failure (indeterminate) from success-with-no-id (none) prevents
/// a getattrlist failure from masking a clone and allowing auto-selection of the sole copy.
enum CloneProbeResult: Equatable {
    /// getattrlist succeeded; file carries a non-zero APFS clone id.
    case id(UInt64)
    /// getattrlist succeeded; file has no clone id (value is zero or buffer too short).
    case none
    /// getattrlist failed (unsupported volume type, EPERM, etc.); clone status unknown.
    case indeterminate
}

private enum CloneIDProbe {
    // ATTR_CMNEXT_CLONEID = 0x00000100, placed in attrlist.forkattr.
    // FSOPT_ATTR_CMN_EXTENDED = 0x00000020 reinterprets forkattr as extended
    // common attributes (required for ATTR_CMNEXT_* family).
    // Both values are web-verified against the XNU source and Apple getattrlist(2).
    private static let attrCloneID: UInt32 = 0x00000100
    private static let optExtended: UInt32 = 0x00000020

    /// Probes the APFS data-stream (clone) id for `url`.
    /// Returns `.id(n)` when getattrlist succeeds and the id is non-zero,
    /// `.none` when it succeeds but the id is absent/zero,
    /// or `.indeterminate` when the syscall fails (non-APFS, EPERM, etc.).
    static func probeClone(of url: URL) -> CloneProbeResult {
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
        guard status == 0 else { return .indeterminate }

        return buf.withUnsafeBytes { raw -> CloneProbeResult in
            let len = raw.load(fromByteOffset: 0, as: UInt32.self)
            guard len >= 12 else { return .none } // 4 (length field) + 8 (clone id)
            let cloneID = raw.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
            return cloneID == 0 ? .none : .id(cloneID)
        }
    }
}
