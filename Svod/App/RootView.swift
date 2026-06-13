import SwiftUI

// MARK: - RootView
//
// The three-pane shell: sidebar | center (editor / graph / history) | inspector.
// Native NavigationSplitView for the sidebar+center, `.inspector` for the trailing
// pane, a unified translucent toolbar, and overlays for the ⌘K command palette and
// the conflict merge sheet. FROZEN foundation file — feature teammates do not edit
// it; the lead rewires `FeatureSlots` during integration.

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarSlot()
                .navigationSplitViewColumnWidth(
                    min: Spacing.sidebarMinWidth, ideal: Spacing.sidebarWidth, max: 360)
        } detail: {
            center
                .inspector(isPresented: $app.inspectorVisible) {
                    InspectorSlot()
                        .inspectorColumnWidth(
                            min: Spacing.inspectorMinWidth, ideal: Spacing.inspectorWidth, max: 420)
                }
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .background(ThemeColor.background)
        .overlay { commandPaletteOverlay }
        .sheet(isPresented: conflictPresented) {
            if let c = app.activeConflict { ConflictSlot(conflict: c) }
        }
        .sheet(isPresented: $app.importPresented) {
            ImportView().environmentObject(app)
        }
        .onChange(of: columnVisibility) { _, new in
            app.sidebarVisible = (new != .detailOnly)
        }
        .animation(Motion.pane, value: app.centerMode)
    }

    // MARK: center pane
    @ViewBuilder private var center: some View {
        switch app.centerMode {
        case .editor:  EditorSlot()
        case .graph:   GraphSlot()
        case .history: HistorySlot()
        }
    }

    // MARK: toolbar
    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            // NavigationSplitView already provides the sidebar toggle (and the
            // View ▸ Show/Hide Sidebar ⌃⌘S menu item), so we don't add our own —
            // just the active-vault indicator + switcher (hidden when single-vault).
            VaultSwitcherSlot()
        }

        ToolbarItemGroup(placement: .principal) {
            Picker("View", selection: centerModeBinding) {
                Image(systemName: "doc.text").tag(CenterMode.editor)
                Image(systemName: "point.3.connected.trianglepath.dotted").tag(CenterMode.graph)
                Image(systemName: "clock.arrow.circlepath").tag(CenterMode.history)
            }
            .pickerStyle(.segmented)
            .help("Editor · Graph · History")
            .fixedSize()
        }

        // Separate items (not a group) so macOS applies its standard, roomier
        // spacing between the connection pill, search, and inspector toggle.
        ToolbarItem(placement: .primaryAction) {
            ConnectionIndicator()
                .padding(.trailing, Spacing.xs)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { app.toggleCommandPalette() } label: { Image(systemName: "magnifyingglass") }
                .help("Search (⌘K)")
                .accessibilityLabel("Search")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { app.toggleInspector() } label: { Image(systemName: "sidebar.right") }
                .help("Toggle inspector")
                .accessibilityLabel("Toggle inspector")
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsLink { Image(systemName: "gearshape") }
                .help("Settings (⌘,)")
                .accessibilityLabel("Settings")
        }
    }

    private var centerModeBinding: Binding<CenterMode> {
        Binding(get: { app.centerMode }, set: { app.setCenter($0) })
    }

    private var conflictPresented: Binding<Bool> {
        Binding(get: { app.activeConflict != nil },
                set: { if !$0 { app.dismissConflict() } })
    }

    // MARK: ⌘K overlay
    @ViewBuilder private var commandPaletteOverlay: some View {
        if app.commandPaletteVisible {
            ZStack(alignment: .top) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { app.toggleCommandPalette() }
                CommandPaletteSlot()
                    .padding(.top, 80)
                    .transition(.move(edge: .top).combined(with: .opacity))
                // Window-level Esc: closes the palette even if the search field
                // isn't focused (.cancelAction fires from anywhere in the window).
                Button("") { app.commandPaletteVisible = false }
                    .keyboardShortcut(.cancelAction)
                    .hidden()
            }
            .zIndex(10)
        }
    }
}

// MARK: - Connection indicator (reads engine state; opens the Engine panel)
private struct ConnectionIndicator: View {
    @EnvironmentObject var app: AppModel
    @State private var showEnginePanel = false

    var body: some View {
        let state = app.connection
        Button { showEnginePanel.toggle() } label: {
            switch state {
            case .connected:             StatusPill(state.label, tone: .success)
            case .starting, .connecting: StatusPill(state.label, tone: .warning, pulses: true)
            case .error:                 StatusPill("Error", tone: .danger)
            case .disconnected:          StatusPill("Start Svod", tone: .offline, showsDot: false)
            }
        }
        .buttonStyle(.plain)
        .help("Engine status")
        .animation(Motion.quick, value: state)
        .popover(isPresented: $showEnginePanel, arrowEdge: .bottom) {
            EngineStatusView(model: app.engine)
                .environmentObject(app)
        }
    }
}

#Preview("RootView — connected") {
    RootView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 1100, height: 720)
        .preferredColorScheme(.dark)
}

#Preview("RootView — offline") {
    RootView()
        .environmentObject(AppModel(client: MockSvodClient.offline))
        .frame(width: 1100, height: 720)
        .preferredColorScheme(.dark)
}
