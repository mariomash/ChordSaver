import SwiftUI

@main
struct ChordSaverApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(viewModel)
                .environmentObject(viewModel.audio)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Session") {
                Button("Export Session…") {
                    viewModel.exportSession()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}
