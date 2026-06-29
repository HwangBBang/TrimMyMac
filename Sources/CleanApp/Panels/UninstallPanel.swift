import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CleanCore

// MARK: - Phase enum

private enum UninstallPhase {
    case idle
    case ready(UninstallPlan)
    case done(UninstallPlan, TrashOutcome)
    case error(String)
}

// MARK: - UninstallPanel

/// App-uninstaller panel. Pick a .app via NSOpenPanel or drag-drop → AppUninstaller.plan(for:)
/// → show the app + leftovers (exact auto-checked; ambiguous unchecked with evidence shown)
/// → SafeRemover.trash(selected) → outcome.
@MainActor
struct UninstallPanel: View {
    /// Home directory used by AppUninstaller to locate leftovers.
    let home: URL

    @State private var phase: UninstallPhase = .idle
    @State private var selection: Set<UUID> = []
    @State private var showFDASheet = false
    @State private var lastAppURL: URL?
    @State private var isDropTargeted = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            switch phase {
            case .idle:
                dropZone
            case .ready(let plan):
                planView(plan)
            case .done(let plan, let outcome):
                planView(plan)
                outcomeView(outcome)
            case .error(let message):
                dropZone
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 460)
        .sheet(isPresented: $showFDASheet) {
            FullDiskAccessSheet(
                onRetry: {
                    showFDASheet = false
                    if let url = lastAppURL { loadPlan(appURL: url) }
                },
                onDismiss: { showFDASheet = false }
            )
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            Label("Uninstall App", systemImage: "trash.square")
                .font(.headline)
            Spacer()
            Button("Choose .app…") { chooseApp() }
            if case .ready = phase {
                Button("Reset") { reset() }
            } else if case .done = phase {
                Button("Reset") { reset() }
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
            .frame(height: 120)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.largeTitle)
                    Text("Drop an application here, or click \"Choose .app…\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
    }

    private func planView(_ plan: UninstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            itemRow(for: plan.app, isApp: true)

            Divider()

            if plan.leftovers.isEmpty {
                Text("No leftover files found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Leftovers (\(plan.leftovers.count))")
                    .font(.subheadline.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.leftovers) { item in
                            itemRow(for: item, isApp: false)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            let allItems = [plan.app] + plan.leftovers
            let selectedBytes = allItems
                .filter { selection.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.allocatedSize }

            HStack {
                Text("Selected \(selection.count) of \(allItems.count) • \(byteString(selectedBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move \(selection.count) Item(s) to Trash") {
                    trashSelected(plan)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
        }
    }

    private func itemRow(for item: ScanItem, isApp: Bool) -> some View {
        let bound = Binding<Bool>(
            get: { selection.contains(item.id) },
            set: { isOn in
                if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
            }
        )
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: bound)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Image(systemName: isApp ? "app.badge" : "doc")
                    Text(item.url.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(byteString(item.allocatedSize))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(item.url.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let evidence = item.evidence {
                    Text("⚠︎ \(evidence)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func outcomeView(_ outcome: TrashOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Trashed \(outcome.trashed.count) · Skipped \(outcome.skipped.count) · Failed \(outcome.failed.count)")
                .font(.footnote.bold())
            Text("Reclaimed \(byteString(outcome.reclaimedAllocated))")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(outcome.skipped, id: \.url) { s in
                Text("Skipped \(s.url.lastPathComponent): \(s.reason)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(outcome.failed, id: \.url) { f in
                Text("Failed \(f.url.lastPathComponent): \(f.message)")
                    .font(.caption2).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            loadPlan(appURL: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { return }
            Task { @MainActor in self.loadPlan(appURL: url) }
        }
        return true
    }

    private func loadPlan(appURL: URL) {
        lastAppURL = appURL
        selection = []
        let scanner = CleanCore.Scanner(ignore: .default, probe: DefaultStatProbe())
        let uninstaller = AppUninstaller(scanner: scanner, home: home)
        do {
            let newPlan = try uninstaller.plan(for: appURL)
            // Auto-check exact matches; leave ambiguous ones unchecked.
            var preselected = Set<UUID>()
            if newPlan.app.isAutoSelected { preselected.insert(newPlan.app.id) }
            for item in newPlan.leftovers where item.isAutoSelected {
                preselected.insert(item.id)
            }
            selection = preselected
            phase = .ready(newPlan)
        } catch {
            if FullDiskAccessClassifier.needsFullDiskAccess(for: error) {
                showFDASheet = true
            } else {
                phase = .error("Could not read app: \(error.localizedDescription)")
            }
        }
    }

    private func trashSelected(_ plan: UninstallPlan) {
        let all = [plan.app] + plan.leftovers
        let chosen = all.filter { selection.contains($0.id) }
        let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: .default)
        let outcome = remover.trash(chosen)
        phase = .done(plan, outcome)
    }

    private func reset() {
        phase = .idle
        selection = []
        lastAppURL = nil
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
