import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CleanCore

// MARK: - Phase enum

enum UninstallPhase {
    case idle
    case loading(URL)
    case ready(UninstallPlan)
    case done(UninstallPlan, TrashOutcome)
    case error(String)

    /// True while a plan is ready to act on or a trash operation has completed.
    var showReset: Bool {
        switch self {
        case .ready, .done: return true
        default: return false
        }
    }
}

// MARK: - ViewModel

@MainActor
final class UninstallPanelModel: ObservableObject {
    @Published var phase: UninstallPhase = .idle
    @Published var selection: Set<UUID> = []
    @Published var showFDASheet = false

    private var lastAppURL: URL?
    private var planTask: Task<Void, Never>?
    private var innerPlanTask: Task<UninstallPlan, Error>?

    let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    // MARK: Plan loading

    func loadPlan(appURL: URL) {
        innerPlanTask?.cancel()
        planTask?.cancel()
        innerPlanTask = nil
        planTask = nil

        lastAppURL = appURL
        selection = []
        phase = .loading(appURL)

        let homeURL = home
        let inner = Task.detached(priority: .userInitiated) {
            () throws -> UninstallPlan in
            let scanner = CleanCore.Scanner(ignore: .default, probe: DefaultStatProbe())
            let uninstaller = AppUninstaller(scanner: scanner, home: homeURL)
            return try uninstaller.plan(for: appURL)
        }
        innerPlanTask = inner

        planTask = Task { [weak self] in
            do {
                let plan = try await inner.value
                guard let self else { return }
                self.innerPlanTask = nil
                var preselected = Set<UUID>()
                if plan.app.isAutoSelected { preselected.insert(plan.app.id) }
                for item in plan.leftovers where item.isAutoSelected {
                    preselected.insert(item.id)
                }
                self.selection = preselected
                self.phase = .ready(plan)
            } catch is CancellationError {
                // Phase already transitioned by cancelLoad(); nothing to do here.
            } catch {
                guard let self else { return }
                self.innerPlanTask = nil
                if FullDiskAccessClassifier.needsFullDiskAccess(for: error) {
                    self.phase = .idle
                    self.showFDASheet = true
                } else {
                    self.phase = .error("Could not read app: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelLoad() {
        innerPlanTask?.cancel()
        planTask?.cancel()
        innerPlanTask = nil
        planTask = nil
        phase = .idle
    }

    func retryLastApp() {
        if let url = lastAppURL { loadPlan(appURL: url) }
    }

    // MARK: Trash

    func trashSelected(plan: UninstallPlan) {
        let all = [plan.app] + plan.leftovers
        let chosen = all.filter { selection.contains($0.id) }
        let remover = SafeRemover(probe: DefaultStatProbe(), fileManager: .default)
        let outcome = remover.trash(chosen)
        phase = .done(plan, outcome)
    }

    // MARK: Reset

    func reset() {
        cancelLoad()
        selection = []
        lastAppURL = nil
    }
}

// MARK: - UninstallPanel

/// App-uninstaller panel. Pick a .app via NSOpenPanel or drag-drop → AppUninstaller.plan(for:)
/// → show the app + leftovers (exact auto-checked; ambiguous unchecked with evidence shown)
/// → SafeRemover.trash(selected) → outcome.
@MainActor
struct UninstallPanel: View {
    @StateObject private var model: UninstallPanelModel
    @State private var isDropTargeted = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        _model = StateObject(wrappedValue: UninstallPanelModel(home: home))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            switch model.phase {
            case .idle:
                dropZone
            case .loading(let appURL):
                loadingView(appURL)
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
        .onDisappear {
            model.cancelLoad()
        }
        .sheet(isPresented: $model.showFDASheet) {
            FullDiskAccessSheet(
                onRetry: {
                    model.showFDASheet = false
                    model.retryLastApp()
                },
                onDismiss: { model.showFDASheet = false }
            )
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            Label("Uninstall App", systemImage: "trash.square")
                .font(.headline)
            Spacer()
            if case .loading = model.phase {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.cancelLoad() }
            } else {
                Button("Choose .app…") { chooseApp() }
                if model.phase.showReset {
                    Button("Reset") { model.reset() }
                }
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

    private func loadingView(_ appURL: URL) -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Analysing \(appURL.lastPathComponent)…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
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
                .filter { model.selection.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.allocatedSize }

            HStack {
                Text("Selected \(model.selection.count) of \(allItems.count) • \(byteString(selectedBytes))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Move \(model.selection.count) Item(s) to Trash") {
                    model.trashSelected(plan: plan)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selection.isEmpty)
            }
        }
    }

    private func itemRow(for item: ScanItem, isApp: Bool) -> some View {
        let bound = Binding<Bool>(
            get: { model.selection.contains(item.id) },
            set: { isOn in
                if isOn { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
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
            model.loadPlan(appURL: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension == "app" else { return }
            Task { @MainActor in model.loadPlan(appURL: url) }
        }
        return true
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
