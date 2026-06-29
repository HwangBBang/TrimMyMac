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
    }
}
