import SwiftUI
import TrimCore

@main
struct TrimMyMacApp: App {
    @StateObject private var memoryMonitor = MemoryMonitor()
    @StateObject private var cpuMonitor = CPUMonitor()
    @StateObject private var agentMonitor = AgentSessionMonitor()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(memoryMonitor: memoryMonitor, cpuMonitor: cpuMonitor,
                        agentMonitor: agentMonitor, updater: updater)
        } label: {
            MenuBarLabel(memoryMonitor: memoryMonitor, cpuMonitor: cpuMonitor, agentMonitor: agentMonitor)
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
    }
}
