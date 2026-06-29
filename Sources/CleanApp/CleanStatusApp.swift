import SwiftUI

@main
struct CleanStatusApp: App {
    var body: some Scene {
        MenuBarExtra("CleanStatus", systemImage: "sparkles") {
            MenuBarContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CleanStatus")
                .font(.headline)
            Text("Scaffold spike — menu bar item is live.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit CleanStatus") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
    }
}
