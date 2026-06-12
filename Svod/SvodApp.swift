import SwiftUI

@main
struct SvodApp: App {
    @StateObject private var app = AppModel(client: LiveSvodClient())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 900, minHeight: 560)
                .task { app.bootstrap() }
                .preferredColorScheme(.dark)   // dark-first
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Search…") { app.toggleCommandPalette() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Save Note") { Task { await app.editor.save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(app.selectedPath == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Inspector") { app.toggleInspector() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
                Button("Editor") { app.setCenter(.editor) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Graph") { app.setCenter(.graph) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("History") { app.setCenter(.history) }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}
