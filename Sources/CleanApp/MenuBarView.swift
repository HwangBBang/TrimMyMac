import SwiftUI
import CleanCore

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

/// Compact label shown in the macOS menu bar: "<mem%> · <free disk>".
/// Owns the sampling timer + pressure source so values stay live even when the
/// popover window is closed.
struct MenuBarLabel: View {
    @ObservedObject var memoryMonitor: MemoryMonitor

    @State private var sample: MemorySample?
    @State private var freeDisk: Int64 = 0

    private let disk = DiskMetrics()
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip")
            if let sample {
                Text("\(memoryUsagePercent(used: sample.used, total: sample.total))% · \(humanReadableBytes(freeDisk)) free")
            } else {
                Text("—")
            }
        }
        .onAppear {
            refresh()
            memoryMonitor.start { _ in
                refresh()
            }
        }
        .onDisappear { memoryMonitor.stop() }
        .onReceive(tick) { _ in refresh() }
    }

    private func refresh() {
        let s = memoryMonitor.sample()
        sample = s
        if let d = disk.sample(volume: URL(fileURLWithPath: "/")) {
            freeDisk = d.availableImportant
        }
    }
}

// MARK: - Popover content

struct MenuBarView: View {
    @ObservedObject var memoryMonitor: MemoryMonitor

    // Memory is read directly from memoryMonitor.latest (single source of truth).
    // Disk (not owned by MemoryMonitor) stays in local @State.
    @State private var diskSample: DiskSample?

    // openWindow environment action for opening named windows.
    @Environment(\.openWindow) private var openWindow

    // Placeholder panel toggles (later tasks replace the sheet bodies).
    @State private var showDuplicates = false   // 중복
    @State private var showAppDelete = false    // 앱 삭제

    private let disk = DiskMetrics()
    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            memoryInfoCard
            Divider()
            diskRow
            Divider()
            actionButtons
        }
        .padding(16)
        .frame(width: 320)
        .onAppear(perform: refresh)
        .onReceive(tick) { _ in refresh() }
        // memoryMonitor is @ObservedObject: any @Published change (including $latest
        // from sample() or the pressure callback) automatically triggers re-render.
        // The old onReceive($latest) duplicated that update → removed.
        .sheet(isPresented: $showDuplicates) {
            PlaceholderPanel(title: "중복 파일", message: "중복 탐지 패널은 이후 작업에서 연결됩니다.")
        }
        .sheet(isPresented: $showAppDelete) {
            PlaceholderPanel(title: "앱 삭제", message: "앱 제거 패널은 이후 작업에서 연결됩니다.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("CleanStatus").font(.headline)
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

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("정크 정리") { openWindow(id: "junk") }
            Button("중복 파일") { showDuplicates = true }
            Button("앱 삭제") { showAppDelete = true }
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
