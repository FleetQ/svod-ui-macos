import SwiftUI
import AppKit

// MARK: - Close-on-Esc
//
// A hidden window-wide Escape handler that closes the containing window. Used to
// give the Settings window (and other auxiliary panels) a consistent Esc-to-close.
struct CloseOnEsc: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            Button("") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}
extension View {
    func closeOnEsc() -> some View { modifier(CloseOnEsc()) }
}

// MARK: - SettingsScene
//
// The ⌘, preferences window: a sectioned sidebar + detail panels. Panels read
// preferences from `app.settings` (passed in as an @ObservedObject so bindings
// work) and reach engine/app actions via @EnvironmentObject. Native macOS Form
// look; design tokens for section chrome.

struct SettingsScene: View {
    @EnvironmentObject var app: AppModel
    @State private var section: Section = .connection

    enum Section: String, CaseIterable, Identifiable {
        case connection, engine, syncBackup, sources, appearance, editor, search, activity, graph, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .connection: "Connection"
            case .engine:     "Engine"
            case .syncBackup: "Sync & Backup"
            case .sources:    "Sources"
            case .appearance: "Appearance"
            case .editor:     "Editor"
            case .search:     "Search"
            case .activity:   "Activity"
            case .graph:      "Graph"
            case .about:      "About"
            }
        }
        var icon: String {
            switch self {
            case .connection: "network"
            case .engine:     "bolt.horizontal"
            case .syncBackup: "arrow.triangle.2.circlepath"
            case .sources:    "externaldrive.badge.plus"
            case .appearance: "paintpalette"
            case .editor:     "square.and.pencil"
            case .search:     "magnifyingglass"
            case .activity:   "dot.radiowaves.left.and.right"
            case .graph:      "point.3.connected.trianglepath.dotted"
            case .about:      "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            ScrollView { detail.padding(.vertical, Spacing.sm) }
                .navigationTitle(section.title)
        }
        .frame(minWidth: 720, minHeight: 480)
        .closeOnEsc()
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .connection: ConnectionSettingsView(settings: app.settings)
        case .engine:     EngineSettingsView()
        case .syncBackup: SyncBackupSettingsView()
        case .sources:    SourcesSettingsView()
        case .appearance: AppearanceSettingsView(settings: app.settings)
        case .editor:     EditorSettingsView(settings: app.settings)
        case .search:     SearchSettingsView(settings: app.settings)
        case .activity:   ActivitySettingsView(settings: app.settings)
        case .graph:      GraphSettingsView(settings: app.settings)
        case .about:      AboutSettingsView()
        }
    }
}

#Preview("Settings") {
    SettingsScene()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 820, height: 560)
}
