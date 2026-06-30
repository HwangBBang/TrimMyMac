import SwiftUI
import AppKit
import TrimCore

// MARK: - Pressure presentation

private extension MemoryPressure {
    var pillColor: Color {
        switch self {
        case .normal:   return .green
        case .warning:  return .yellow
        case .critical: return .red
        }
    }
    var koreanLabel: String {
        switch self {
        case .normal:   return "정상"
        case .warning:  return "주의"
        case .critical: return "위험"
        }
    }
}

// MARK: - Menu-bar label (always visible in the status bar)

/// Compact label shown in the macOS menu bar: "[glyph] MEM x% · SSD y%".
/// Owns the sampling timer + pressure source so values stay live even when the
/// popover window is closed.
struct MenuBarLabel: View {
    @ObservedObject var memoryMonitor: MemoryMonitor
    @ObservedObject var cpuMonitor: CPUMonitor
    @ObservedObject var agentMonitor: AgentSessionMonitor

    @AppStorage("menubar.showCPU") private var showCPU = true
    @AppStorage("menubar.showMEM") private var showMEM = true
    @AppStorage("menubar.showSSD") private var showSSD = true
    @AppStorage("agents.enabled") private var agentsEnabled = true

    @State private var memSample: MemorySample?
    @State private var diskSample: DiskSample?
    @State private var agentTick = 0

    private let disk = DiskMetrics()
    // 1 s cadence matches Stats' default; a 3 s delta read noticeably lower/laggier CPU.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // The status item shows a single pre-rasterized image. A live SwiftUI
        // HStack/VStack label gets squeezed to ~one character by the menu bar's
        // tight height/width budget; rendering the metrics to an NSImage (the
        // approach Stats uses) sizes exactly to content and never truncates.
        // Rendered inline so metric on/off toggles take effect immediately.
        Group {
            if let image = renderLabel() {
                Image(nsImage: image)
            } else {
                Text("TrimMyMac").font(.system(size: 11))
            }
        }
        .onAppear {
            refresh()
            memoryMonitor.start { _ in refresh() }
        }
        .onDisappear { memoryMonitor.stop() }
        .onReceive(tick) { _ in refresh() }
    }

    /// Stats-style stacked metric: small dimmed label on top, larger percentage below.
    /// Sizes are pushed to the practical ceiling for a two-line menu-bar item (~22pt tall).
    private func metric(_ label: String, _ percent: Int) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .opacity(0.6)
            Text("\(percent)%")
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
        }
    }

    /// Rasterizes the enabled stacked metrics into a template NSImage. `isTemplate`
    /// makes the menu bar tint it for light/dark automatically, and a single image
    /// is never clipped the way a live multi-line label is. Returns nil when no
    /// metric is enabled (the body then shows a text fallback so the item stays clickable).
    @MainActor
    private func renderLabel() -> NSImage? {
        var items: [(String, Int)] = []
        if showCPU { items.append(("CPU", cpuMonitor.latest?.usage ?? 0)) }
        if showMEM { items.append(("MEM", memSample.map { memoryUsagePercent(used: $0.used, total: $0.total) } ?? 0)) }
        if showSSD { items.append(("SSD", diskSample.map { diskUsedPercent(total: $0.total, available: $0.availableImportant) } ?? 0)) }
        guard !items.isEmpty else { return nil }

        let content = HStack(spacing: 8) {
            ForEach(items, id: \.0) { item in
                metric(item.0, item.1)
            }
        }
        .padding(.horizontal, 2)
        .foregroundStyle(.black)   // alpha mask → menu bar tint via isTemplate

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }

    private func refresh() {
        memSample = memoryMonitor.sample()
        diskSample = disk.sample(volume: URL(fileURLWithPath: "/"))
        // CPU is delta-based and MUST be sampled from exactly one place; the
        // always-present menu-bar label owns that cadence. The popover only reads.
        cpuMonitor.sample()

        // Agent enumeration is heavier than a couple of syscalls, so throttle it to
        // ~every 3rd tick (~3 s) and only when the feature is on. The popover reads
        // agentMonitor.sessions; it never samples (delta-based → single sampler).
        agentTick &+= 1
        if agentsEnabled, agentTick % 3 == 1 {
            agentMonitor.sample(enabled: Set(AgentKind.allCases))
        }
    }
}

// MARK: - Popover content

struct MenuBarView: View {
    @ObservedObject var memoryMonitor: MemoryMonitor
    @ObservedObject var cpuMonitor: CPUMonitor
    @ObservedObject var agentMonitor: AgentSessionMonitor

    @AppStorage("menubar.showCPU") private var showCPU = true
    @AppStorage("menubar.showMEM") private var showMEM = true
    @AppStorage("menubar.showSSD") private var showSSD = true
    @AppStorage("agents.enabled") private var agentsEnabled = true

    @ObservedObject var updater: UpdaterModel

    // Memory is read directly from memoryMonitor.latest (single source of truth).
    // Disk (not owned by MemoryMonitor) stays in local @State.
    @State private var diskSample: DiskSample?

    // openWindow environment action for opening named windows.
    @Environment(\.openWindow) private var openWindow

    private let disk = DiskMetrics()
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            cpuRow
            Divider()
            memoryInfoCard
            Divider()
            diskRow
            if agentsEnabled {
                Divider()
                agentSection
            }
            Divider()
            actionButtons
            Divider()
            settingsSection
            Divider()
            updateRow
        }
        .padding(16)
        .frame(width: 320)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
        // memoryMonitor is @ObservedObject: any @Published change (including $latest
        // from sample() or the pressure callback) automatically triggers re-render.
        // The old onReceive($latest) duplicated that update → removed.
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("TrimMyMac").font(.headline)
            Spacer()
            if let sample = memoryMonitor.latest {
                pressurePill(sample.pressure)
            }
        }
    }

    private func pressurePill(_ pressure: MemoryPressure) -> some View {
        HStack(spacing: 4) {
            Circle().fill(pressure.pillColor).frame(width: 8, height: 8)
            Text(pressure.koreanLabel).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(pressure.pillColor.opacity(0.15), in: Capsule())
    }

    /// CPU usage card. Read-only: the menu-bar label owns CPU sampling (delta-based);
    /// here we only display the latest value it produced.
    private var cpuRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU").font(.subheadline).bold()
            if let cpu = cpuMonitor.latest {
                infoRow("사용률", "\(cpu.usage)%")
                ProgressView(value: Double(cpu.usage), total: 100)
                infoRow("시스템", "\(cpu.system)%")
                infoRow("사용자", "\(cpu.user)%")
            } else {
                Text("측정 중…").foregroundStyle(.secondary)
            }
        }
    }

    /// Read-only memory info card — NO purge button (decision 2).
    private var memoryInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("메모리").font(.subheadline).bold()
            if let sample = memoryMonitor.latest {
                infoRow("사용량", "\(humanReadableBytes(sample.used)) / \(humanReadableBytes(sample.total))  (\(memoryUsagePercent(used: sample.used, total: sample.total))%)")
                ProgressView(value: Double(sample.used), total: Double(max(sample.total, 1)))
                infoRow("활성", humanReadableBytes(sample.active))
                infoRow("비활성", humanReadableBytes(sample.inactive))
                infoRow("와이어드", humanReadableBytes(sample.wired))
                infoRow("압축됨", humanReadableBytes(sample.compressed))
                infoRow("스왑 사용", humanReadableBytes(sample.swapUsed))
            } else {
                Text("측정 중…").foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var diskRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("디스크").font(.subheadline).bold()
            if let diskSample {
                infoRow("여유 공간", humanReadableBytes(diskSample.availableImportant))
                infoRow("전체", humanReadableBytes(diskSample.total))
            } else {
                Text("측정 중…").foregroundStyle(.secondary)
            }
        }
    }

    /// Per-session CPU/RAM for detected agentic AI CLIs (Claude Code, Codex).
    /// Read-only: the menu-bar label owns sampling.
    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 세션").font(.subheadline).bold()
            if agentMonitor.sessions.isEmpty {
                Text("감지된 세션 없음").font(.callout).foregroundStyle(.secondary)
            } else {
                // Could be many concurrent sessions; cap the height and scroll.
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(agentMonitor.sessions) { session in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(session.kind.displayName).font(.callout)
                                    Text("PID \(session.pid)").font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("CPU \(session.cpu)%").font(.callout).monospacedDigit()
                                Text(humanReadableBytes(session.memory))
                                    .font(.callout).monospacedDigit()
                                    .frame(width: 76, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(maxHeight: 168)
            }
        }
    }

    /// Collapsible settings: which metrics appear in the menu bar + agent tracking.
    private var settingsSection: some View {
        DisclosureGroup("설정") {
            VStack(alignment: .leading, spacing: 4) {
                Text("메뉴바 표시").font(.caption).foregroundStyle(.secondary)
                Toggle("CPU", isOn: $showCPU)
                Toggle("메모리", isOn: $showMEM)
                Toggle("디스크", isOn: $showSSD)
                Divider()
                Toggle("AI 세션 추적", isOn: $agentsEnabled)
            }
            .toggleStyle(.switch)
            .padding(.top, 4)
        }
        .font(.subheadline)
    }

    /// App version + manual update check (Sparkle). Background checks run on a schedule.
    private var updateRow: some View {
        HStack {
            Text("v\(appVersion)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("업데이트 확인") { updater.checkForUpdates() }
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("정크 정리") { openWindow(id: "junk") }
            Button("중복 파일") { openWindow(id: "duplicates") }
            Button("앱 삭제") { openWindow(id: "uninstall") }
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .foregroundStyle(.secondary)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }

    // MARK: Refresh

    private func refresh() {
        // Drive $latest (single source for memory); view re-renders via @ObservedObject.
        _ = memoryMonitor.sample()
        diskSample = disk.sample(volume: URL(fileURLWithPath: "/"))
    }
}

// MARK: - Placeholder sheet (replaced by real panels in later tasks)

struct PlaceholderPanel: View {
    let title: String
    let message: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            Text(message).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360, height: 180)
    }
}
