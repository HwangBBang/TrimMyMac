import SwiftUI
import TrimCore

@main
struct TrimMyMacApp: App {
    @StateObject private var memoryMonitor = MemoryMonitor()
    @StateObject private var cpuMonitor = CPUMonitor()
    @StateObject private var processMonitor = ProcessMonitor()
    @StateObject private var updater = UpdaterModel()
    @StateObject private var fdaModel = FullDiskAccessModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(memoryMonitor: memoryMonitor, cpuMonitor: cpuMonitor,
                        processMonitor: processMonitor,
                        updater: updater, fdaModel: fdaModel)
        } label: {
            MenuBarLabel(memoryMonitor: memoryMonitor, cpuMonitor: cpuMonitor,
                         processMonitor: processMonitor, fdaModel: fdaModel)
        }
        .menuBarExtraStyle(.window)

        Window("Junk Cleanup", id: "junk") {
            JunkPanel()
        }
        .windowResizability(.contentSize)

        Window("Duplicate Finder", id: "duplicates") {
            DuplicatePanel()
        }
        .windowResizability(.contentSize)

        Window("Uninstall App", id: "uninstall") {
            UninstallPanel()
        }
        .windowResizability(.contentSize)

        Window("최적화", id: "optimize") {
            OptimizePanel(memoryMonitor: memoryMonitor, processMonitor: processMonitor)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(updater: updater)
        }

        Window("환영", id: "onboarding") {
            OnboardingView()
        }
        .windowResizability(.contentSize)
    }
}
