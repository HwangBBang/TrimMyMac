import SwiftUI
import AppKit
import TrimCore

// MARK: - ViewModel

@MainActor
final class JunkPanelModel: ObservableObject {
    @Published var items: [ScanItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var phase: Phase = .idle
    @Published var outcome: TrashOutcome?
    @Published var errorMessage: String?
    /// Locations skipped because they couldn't be read (missing Full Disk Access / TCC).
    @Published var unreadableLocations: [URL] = []

    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case failed(String)
    }

    // Derived from phase so a cancelled task can never write a stale false and freeze the UI.
    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    private let home: URL
    private var scanTask: Task<Void, Never>?
    private var innerScanTask: Task<([ScanItem], [URL]), Error>?
    private var trashTask: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Summary of the currently selected items (pure logic lives in TrimCore).
    var summary: SelectionSummary {
        selectionSummary(items: items.filter { selectedIDs.contains($0.id) })
    }

    var selectedItems: [ScanItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func startScan() {
        innerScanTask?.cancel()
        scanTask?.cancel()
        innerScanTask = nil
        scanTask = nil
        outcome = nil
        errorMessage = nil
        unreadableLocations = []
        phase = .scanning    // isScanning derives true from here
        let home = self.home
        let inner = Task.detached(priority: .userInitiated) {
            () throws -> ([ScanItem], [URL]) in
            let probe = DefaultStatProbe()
            let diag = ScanDiagnostics()
            let coreScanner = TrimCore.Scanner(ignore: .default, probe: probe, diagnostics: diag)
            // Capture snapshot of running apps before going off-main
            let isRunning: RunningCheck = await MainActor.run {
                RunningApps.shared.snapshotCheck()
            }
            let junk = JunkScanner(
                roots: JunkScanner.defaultRoots(home: home),
                scanner: coreScanner,
                isRunning: isRunning,
                diagnostics: diag
            )
            let items = try junk.scan()
            return (items, diag.unreadable)
        }
        innerScanTask = inner
        scanTask = Task { [weak self] in
            do {
                let (scanned, unreadable) = try await inner.value
                guard let self else { return }
                self.innerScanTask = nil
                self.items = scanned
                self.unreadableLocations = unreadable
                self.selectedIDs = Set(scanned.filter { $0.isAutoSelected }.map { $0.id })
                self.phase = .results    // isScanning derives false from here
            } catch is CancellationError {
                // phase is already transitioned by cancelScan(); nothing to do here.
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.phase = .failed(error.localizedDescription)    // isScanning derives false
            }
        }
    }

    func cancelScan() {
        innerScanTask?.cancel()
        scanTask?.cancel()
        trashTask?.cancel()
        innerScanTask = nil
        scanTask = nil
        trashTask = nil
        phase = .idle    // isScanning derives false from here
    }

    func trashSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        trashTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> TrashOutcome in
                let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: FileManager.default)
                return remover.trash(selected)
            }.value
            guard let self else { return }
            self.trashTask = nil
            self.outcome = result
            let trashedSet = Set(result.trashed)
            self.items.removeAll { trashedSet.contains($0.url) }
            let remainingIDs = Set(self.items.map { $0.id })
            self.selectedIDs = self.selectedIDs.intersection(remainingIDs)
        }
    }
}

// MARK: - View

struct JunkPanel: View {
    @StateObject private var model = JunkPanelModel()

    private var grouped: [(kind: ItemKind, items: [ScanItem])] {
        Dictionary(grouping: model.items, by: { $0.kind })
            .map { (kind: $0.key, items: $0.value) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func label(for kind: ItemKind) -> String {
        switch kind {
        case .userCache:   return "User Caches"
        case .log:         return "Logs"
        case .devJunk:     return "Developer Junk"
        case .duplicate:   return "Duplicates"
        case .appLeftover: return "App Leftovers"
        case .appBundle:   return "Applications"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            if !model.unreadableLocations.isEmpty {
                permissionBanner
            }
            Divider()
            contentArea
            Divider()
            footerRow
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 420)
        .onDisappear {
            model.cancelScan()
        }
    }

    // MARK: Sections

    /// Shown when a scan hit permission-denied locations: results may be incomplete.
    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(model.unreadableLocations.count)곳을 읽지 못했습니다 — 전체 디스크 접근 권한이 필요할 수 있습니다. 결과가 일부일 수 있어요.")
                .font(.callout)
            Spacer()
            Button("권한 설정 열기") {
                FullDiskAccessProbe.openSettings()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var headerRow: some View {
        HStack {
            Text("Junk Cleanup").font(.headline)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelScan() }
            } else {
                Button("Scan") { model.startScan() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var contentArea: some View {
        if let error = model.errorMessage {
            Text(error).foregroundStyle(.red)
        }
        if model.items.isEmpty && !model.isScanning {
            Text("No items. Press Scan to look for reclaimable junk.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(grouped, id: \.kind) { section in
                    Section(label(for: section.kind)) {
                        ForEach(section.items) { item in
                            itemRow(item)
                        }
                    }
                }
            }
        }
    }

    private func itemRow(_ item: ScanItem) -> some View {
        Toggle(isOn: Binding(
            get: { model.selectedIDs.contains(item.id) },
            set: { on in
                if on { model.selectedIDs.insert(item.id) }
                else  { model.selectedIDs.remove(item.id) }
            }
        )) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.url.lastPathComponent)
                    if let evidence = item.evidence {
                        Text(evidence).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(humanReadableBytes(item.allocatedSize)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var footerRow: some View {
        HStack {
            let summary = model.summary
            Text("\(summary.count) selected · \(humanReadableBytes(summary.allocatedBytes)) reclaimable")
                .font(.subheadline)
            Spacer()
            if let outcome = model.outcome {
                Text(
                    "Trashed \(outcome.trashed.count) · " +
                    "skipped \(outcome.skipped.count) · " +
                    "failed \(outcome.failed.count) · " +
                    "freed \(humanReadableBytes(outcome.reclaimedAllocated))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button("Move to Trash") { model.trashSelected() }
                .disabled(model.summary.count == 0 || model.isScanning)
        }
    }
}
