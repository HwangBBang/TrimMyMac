import SwiftUI
import AppKit
import TrimCore

// MARK: - ViewModel

@MainActor
final class DuplicatePanelModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var selectedIDs: Set<UUID> = []      // ScanItem.id values chosen for trash
    @Published var phase: Phase = .idle
    @Published var outcome: TrashOutcome?
    @Published var errorMessage: String?

    enum Phase: Equatable {
        case idle
        case scanning(URL)
        case results(URL)
        case failed(String)
    }

    // Derived from phase so a cancelled task can never write a stale false and freeze the UI.
    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    private var scanTask: Task<Void, Never>?
    private var innerScanTask: Task<[DuplicateGroup], Error>?
    private var trashTask: Task<Void, Never>?
    private var innerTrashTask: Task<TrashOutcome, Never>?

    var selectedItems: [ScanItem] {
        groups.flatMap { $0.items }.filter { selectedIDs.contains($0.id) }
    }

    func startScan(root: URL) {
        innerScanTask?.cancel()
        scanTask?.cancel()
        innerScanTask = nil
        scanTask = nil
        outcome = nil
        errorMessage = nil
        groups = []
        selectedIDs = []
        phase = .scanning(root)    // isScanning derives true from here

        let inner = Task.detached(priority: .userInitiated) {
            () throws -> [DuplicateGroup] in
            let probe = DefaultStatProbe()
            let scanner = TrimCore.Scanner(ignore: .default, probe: probe)
            let finder = DuplicateFinder(scanner: scanner, probe: probe)
            return try finder.find(in: [root])
        }
        innerScanTask = inner
        scanTask = Task { [weak self] in
            do {
                let found = try await inner.value
                guard let self else { return }
                self.innerScanTask = nil
                self.groups = found
                self.selectedIDs = Set(autoSelectedItems(groups: found).map { $0.id })
                self.phase = .results(root)    // isScanning derives false from here
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
        innerTrashTask?.cancel()
        trashTask?.cancel()
        innerScanTask = nil
        scanTask = nil
        innerTrashTask = nil
        trashTask = nil
        phase = .idle    // isScanning derives false from here
    }

    func trashSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }

        let inner = Task.detached(priority: .userInitiated) {
            () -> TrashOutcome in
            let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: FileManager.default)
            return remover.trash(items)
        }
        innerTrashTask = inner

        trashTask = Task { [weak self] in
            let result = await inner.value
            guard let self else { return }
            self.innerTrashTask = nil
            self.trashTask = nil
            self.outcome = result
            let trashedSet = Set(result.trashed)
            // Remove trashed items and collapse singleton groups.
            self.groups = self.groups.compactMap { group in
                let remaining = group.items.filter { !trashedSet.contains($0.url) }
                guard remaining.count >= 2 else { return nil }
                return DuplicateGroup(id: group.id, confidence: group.confidence, items: remaining)
            }
            let remainingIDs = Set(self.groups.flatMap { $0.items }.map { $0.id })
            self.selectedIDs = self.selectedIDs.intersection(remainingIDs)
        }
    }
}

// MARK: - View

struct DuplicatePanel: View {
    @StateObject private var model = DuplicatePanelModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider()
            contentArea
            Divider()
            footerRow
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 480)
        .onDisappear {
            model.cancelScan()
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack {
            Text("Duplicate Finder").font(.headline)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelScan() }
            } else {
                Button("Choose Folder…") { chooseFolderAndScan() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var contentArea: some View {
        switch model.phase {
        case .idle:
            placeholder("Choose a folder to scan for duplicate files.")
        case .scanning(let root):
            VStack(spacing: 8) {
                ProgressView()
                Text("Scanning \(root.path)…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text("Scan failed: \(message)")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .multilineTextAlignment(.center)
        case .results(let root):
            if model.groups.isEmpty {
                placeholder("No duplicates found in \(root.path).")
            } else {
                resultsList
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .multilineTextAlignment(.center)
    }

    private var resultsList: some View {
        List {
            ForEach(model.groups) { group in
                groupSection(group)
            }
        }
    }

    @ViewBuilder
    private func groupSection(_ group: DuplicateGroup) -> some View {
        let isClone = group.confidence == .cloneSuspected
        Section {
            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                memberRow(item: item, isKept: index == 0, isClone: isClone)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: isClone ? "exclamationmark.triangle.fill" : "doc.on.doc")
                    .foregroundStyle(isClone ? Color.orange : Color.secondary)
                Text(isClone ? "Clone suspected — review manually" : "Exact duplicates")
                    .font(.subheadline.bold())
                    .foregroundStyle(isClone ? Color.orange : Color.primary)
            }
        }
    }

    @ViewBuilder
    private func memberRow(item: ScanItem, isKept: Bool, isClone: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isKept {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .help("Kept original — not deletable")
            } else {
                Toggle("", isOn: bindingFor(item.id))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(isClone) // clone group items must be unchecked; safety guard
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.callout)
                    .fontWeight(isKept ? .semibold : .regular)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let evidence = item.evidence {
                    Text(evidence)
                        .font(.caption2)
                        .foregroundStyle(isClone ? Color.orange : Color.secondary)
                }
            }
            Spacer()
            Text(humanReadableBytes(item.allocatedSize))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .background(isKept ? Color.yellow.opacity(0.10) : Color.clear)
    }

    // MARK: Footer

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let outcome = model.outcome {
                Text(
                    "Trashed \(outcome.trashed.count) (\(humanReadableBytes(outcome.reclaimedAllocated)) reclaimed)" +
                    (outcome.skipped.isEmpty ? "" : " · skipped \(outcome.skipped.count)") +
                    (outcome.failed.isEmpty ? "" : " · failed \(outcome.failed.count)")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack {
                Text("\(model.selectedIDs.count) selected")
                    .font(.caption)
                Spacer()
                Button("Move Selected to Trash") { model.trashSelected() }
                    .disabled(model.selectedIDs.isEmpty || model.isScanning)
            }
        }
    }

    // MARK: Selection binding

    private func bindingFor(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.selectedIDs.contains(id) },
            set: { isOn in
                if isOn { model.selectedIDs.insert(id) }
                else    { model.selectedIDs.remove(id) }
            }
        )
    }

    // MARK: Actions

    private func chooseFolderAndScan() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Scan"
        openPanel.message = "Choose a folder to scan for duplicates"
        openPanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard openPanel.runModal() == .OK, let root = openPanel.url else { return }
        model.startScan(root: root)
    }
}
