import SwiftUI
import CleanCore

@main
struct CleanStatusApp: App {
    @StateObject private var memoryMonitor = MemoryMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(memoryMonitor: memoryMonitor)
        } label: {
            MenuBarLabel(memoryMonitor: memoryMonitor)
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
