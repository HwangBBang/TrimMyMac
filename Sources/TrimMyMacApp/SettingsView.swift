import SwiftUI
import TrimCore

struct SettingsView: View {
    @ObservedObject var updater: UpdaterModel
    @AppStorage("menubar.showCPU") private var showCPU = true
    @AppStorage("menubar.showMEM") private var showMEM = true
    @AppStorage("menubar.showSSD") private var showSSD = true
    @AppStorage("agents.enabled") private var agentsEnabled = true

    var body: some View {
        TabView {
            Form {
                Section("메뉴바 표시") {
                    Toggle("CPU", isOn: $showCPU)
                    Toggle("메모리", isOn: $showMEM)
                    Toggle("디스크", isOn: $showSSD)
                }
                Section("AI 세션") {
                    Toggle("AI 세션 추적", isOn: $agentsEnabled)
                }
            }
            .tabItem { Label("일반", systemImage: "gearshape") }

            Form {
                LabeledContent("버전", value: appVersion)
                Button("업데이트 확인") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            .tabItem { Label("업데이트", systemImage: "arrow.down.circle") }
        }
        .frame(width: 360, height: 240)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
