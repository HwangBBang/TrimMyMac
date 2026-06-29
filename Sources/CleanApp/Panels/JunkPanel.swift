import SwiftUI
import AppKit
import CleanCore

// MARK: - ViewModel

@MainActor
final class JunkPanelModel: ObservableObject {
    @Published var items: [ScanItem] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var isScanning: Bool = false
    @Published var outcome: TrashOutcome?
    @Published var errorMessage: String?

    private let home: URL
    private var scanTask: Task<Void, Never>?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Summary of the currently selected items (pure logic lives in CleanCore).
    var summary: SelectionSummary {
        selectionSummary(items: items.filter { selectedIDs.contains($0.id) })
    }

    var selectedItems: [ScanItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func startScan() {
        scanTask?.cancel()
        outcome = nil
        errorMessage = nil
        isScanning = true
        let home = self.home
        scanTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    () throws -> [ScanItem] in
                    let probe = DefaultStatProbe()
                    let coreScanner = CleanCore.Scanner(ignore: .default, probe: probe)
                    // Capture snapshot of running apps before going off-main
                    let isRunning: RunningCheck = await MainActor.run {
                        RunningApps.shared.snapshotCheck()
                    }
                    let junk = JunkScanner(
                        roots: JunkScanner.defaultRoots(home: home),
                        scanner: coreScanner,
                        isRunning: isRunning
                    )
                    return try junk.scan()
                }.value
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.items = result
                self.selectedIDs = Set(result.filter { $0.isAutoSelected }.map { $0.id })
                self.isScanning = false
            } catch is CancellationError {
                self?.isScanning = false
            } catch {
                guard let self else { return }
                self.errorMessage = error.localizedDescription
                self.isScanning = false
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    func trashSelected() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> TrashOutcome in
                let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: FileManager.default)
                return remover.trash(selected)
            }.value
            guard let self else { return }
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

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private func fmt(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

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
                Text(fmt(item.allocatedSize)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var footerRow: some View {
        HStack {
            let summary = model.summary
            Text("\(summary.count) selected · \(fmt(summary.allocatedBytes)) reclaimable")
                .font(.subheadline)
            Spacer()
            if let outcome = model.outcome {
                Text(
                    "Trashed \(outcome.trashed.count) · " +
                    "skipped \(outcome.skipped.count) · " +
                    "failed \(outcome.failed.count) · " +
                    "freed \(fmt(outcome.reclaimedAllocated))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button("Move to Trash") { model.trashSelected() }
                .disabled(model.summary.count == 0 || model.isScanning)
        }
    }
}
