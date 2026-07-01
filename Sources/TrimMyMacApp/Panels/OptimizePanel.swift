import SwiftUI
import TrimCore

struct OptimizePanel: View {
    @ObservedObject var memoryMonitor: MemoryMonitor
    @ObservedObject var processMonitor: ProcessMonitor
    @Environment(\.openWindow) private var openWindow
    @State private var showEducation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pressureHeader
            Divider()
            diskSection
            Divider()
            consumersSection
        }
        .padding(20)
        .frame(width: 380)
    }

    private var pressureHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let p = memoryMonitor.latest?.pressure {
                    Circle().fill(p.pillColor).frame(width: 10, height: 10)
                    Text("메모리 압력: \(p.koreanLabel)").font(.headline)
                }
                Spacer()
                Sparkline(samples: memoryMonitor.history)
                if let swap = memoryMonitor.latest?.swapUsed {
                    Text("swap \(humanReadableBytes(swap))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                showEducation.toggle()
            } label: {
                Label("빈 RAM은 낭비된 RAM입니다 — 우리는 '비우지' 않습니다", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if showEducation {
                Text("macOS는 남는 메모리를 캐시로 채워 성능을 냅니다. '빈 RAM'을 늘리는 건 성능을 올리지 않습니다. 그래서 가짜 'RAM 비우기' 대신, 실제로 회수되는 디스크 정크를 정리하고 무엇이 메모리를 쓰는지 보여줍니다.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("디스크 정크 회수").font(.subheadline).bold()
            Text("실제로 되돌릴 수 있는 공간을 회수합니다 (검토 후 휴지통).")
                .font(.caption).foregroundStyle(.secondary)
            Button("디스크 정크 정리…") { openWindow(id: "junk") }
                .controlSize(.large)
        }
    }

    private var consumersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("메모리 많이 쓰는 프로세스 (보기 전용)").font(.subheadline).bold()
            if processMonitor.top.isEmpty {
                Text("측정 중…").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(processMonitor.top) { u in
                    HStack {
                        Text(u.displayName).font(.callout).lineLimit(1)
                        Spacer()
                        Text("사용 중 \(humanReadableBytes(u.footprint))")
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text("v1은 보기 전용입니다. 종료 기능은 서명 후 추가됩니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
