import SwiftUI
import Combine

// MARK: - AppModel
//
// The application's shared blackboard and the composition root. It owns one
// sub-model per feature and the small amount of cross-feature state the panes
// agree on (the open note, connection status, the latest live event, pane
// visibility, the active conflict). This file is part of the FROZEN foundation
// contract: feature teammates READ AppModel and CALL its methods, but do not edit
// it. Sub-model files are owned one-per-teammate (see banners in each).
//
// Event / connection wiring contract:
//   • EngineModel (Teammate 5) drives the lifecycle. It sets `connection`, opens
//     the WebSocket via `client.events()`, sets `latestEvent` on each event, and
//     forwards events to `activity`. Other models observe `latestEvent`.
//   • Navigation is via `selectedPath`. Panes react with `.task(id: app.selectedPath)`;
//     AppModel does not call into feature models to load.

@MainActor
public final class AppModel: ObservableObject {

    public let client: SvodClient

    /// All UI preferences (persisted). Read by feature models via their `app` ref.
    public let settings = SettingsStore()

    // Cross-feature state
    @Published public var selectedPath: String?
    @Published public var connection: ConnectionState = .disconnected
    @Published public var latestEvent: SvodEvent?
    @Published public var activeConflict: ConflictBody?

    // Shell state
    @Published public var sidebarVisible = true
    @Published public var inspectorVisible = true
    @Published public var commandPaletteVisible = false
    @Published public var centerMode: CenterMode = .editor

    // Feature sub-models (one per teammate)
    public let editor: EditorModel
    public let search: SearchModel
    public let graph: GraphModel
    public let history: HistoryModel
    public let activity: ActivityModel
    public let sidebar: SidebarModel
    public let engine: EngineModel

    public init(client: SvodClient) {
        self.client = client
        self.editor = EditorModel(client: client)
        self.search = SearchModel(client: client)
        self.graph = GraphModel(client: client)
        self.history = HistoryModel(client: client)
        self.activity = ActivityModel(client: client)
        self.sidebar = SidebarModel(client: client)
        self.engine = EngineModel(client: client)

        // Back-references so feature models can navigate / present.
        editor.app = self
        search.app = self
        graph.app = self
        history.app = self
        activity.app = self
        sidebar.app = self
        engine.app = self

        // Re-publish nested model changes so views observing only AppModel refresh.
        // (Views should prefer observing their own sub-model directly; this keeps
        // shell chrome — e.g. the toolbar — in sync without manual plumbing.)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Forward settings changes so the app shell (theme, endpoint) reacts.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Seed feature defaults from settings.
        search.mode = settings.defaultSearchMode
        graph.scope = settings.defaultGraphScopeLocal ? .local : .global
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: navigation
    public func open(path: String) {
        selectedPath = path
        settings.lastOpenedPath = path
        if centerMode == .graph { centerMode = .editor }
        commandPaletteVisible = false
    }

    // MARK: endpoint
    /// Point the (shared) client at the configured host:port and reconnect. All
    /// sub-models share one client instance, so updating its baseURL redirects
    /// every call; the engine then re-opens the WebSocket against the new URL.
    public func applyEndpoint() {
        (client as? LiveSvodClient)?.updateBaseURL(settings.baseURL)
        engine.reconnectNow()
    }

    // MARK: shell actions
    public func toggleSidebar() { withAnimation(Motion.pane) { sidebarVisible.toggle() } }
    public func toggleInspector() { withAnimation(Motion.pane) { inspectorVisible.toggle() } }
    public func toggleCommandPalette() {
        withAnimation(Motion.quick) { commandPaletteVisible.toggle() }
    }
    public func setCenter(_ mode: CenterMode) { withAnimation(Motion.standard) { centerMode = mode } }

    // MARK: conflict presentation (called by editor/history on a 409)
    public func presentConflict(_ conflict: ConflictBody) { activeConflict = conflict }
    public func dismissConflict() { activeConflict = nil }

    // MARK: lifecycle entry point used by SvodApp on launch
    public func bootstrap() {
        // Honor a non-default endpoint before the first connection attempt.
        if settings.baseURL != client.baseURL {
            (client as? LiveSvodClient)?.updateBaseURL(settings.baseURL)
        }
        if settings.reopenLastNote, let last = settings.lastOpenedPath {
            selectedPath = last
        }
        engine.startConnecting()
    }
}
