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

    /// Central engines the app talks to besides the local one (contract 0.30.0, ADR-0019).
    public let engines: EngineProfileStore

    // Cross-feature state
    @Published public var selectedPath: String?

    /// A theme the user selected, narrowing the notes tree to its members.
    ///
    /// Themes only became useful once selecting one *led somewhere*: showing a wall of member paths
    /// and scoping a graph that does not contain the similarity edges the theme is made of was two
    /// dead ends. Filtering the tree is the action a person actually wants — open these notes.
    public struct ThemeFilter: Equatable {
        public let id: String
        public let title: String
        public let paths: Set<String>
        public init(id: String, title: String, paths: Set<String>) {
            self.id = id; self.title = title; self.paths = paths
        }
    }

    @Published public var themeFilter: ThemeFilter?

    @Published public var connection: ConnectionState = .disconnected
    @Published public var latestEvent: SvodEvent?
    @Published public var activeConflict: ConflictBody?
    /// Bumped on a vault switch. Vault-scoped panes (tree, graph, search) re-load
    /// by keying a `.task(id: app.reloadEpoch)` on it.
    @Published public var reloadEpoch = 0

    // Shell state
    @Published public var sidebarVisible = true
    @Published public var inspectorVisible = true
    @Published public var commandPaletteVisible = false
    @Published public var centerMode: CenterMode = .editor
    /// Import sheet presented from RootView (not from the toolbar menu — a `.sheet`
    /// inside a Menu never presents). Set true from the vault switcher / sidebar.
    @Published public var importPresented = false
    /// "New Vault" sheet, presented from RootView for the same reason as `importPresented`.
    @Published public var newVaultPresented = false
    /// Non-nil ⇒ RootView shows a confirmation dialog to delete this vault.
    @Published public var vaultPendingDeletion: Vault?
    /// Surfaced in a RootView alert when a vault action (delete) fails.
    @Published public var vaultActionError: String?

    // Feature sub-models (one per teammate)
    public let editor: EditorModel
    public let search: SearchModel
    public let graph: GraphModel
    public let history: HistoryModel
    public let activity: ActivityModel
    public let sidebar: SidebarModel
    public let engine: EngineModel
    public let vault: VaultModel
    public let inspector: InspectorModel

    /// The production composition: the local engine plus every saved central-engine profile
    /// behind one router client, so a vault switch can land on either.
    public static func live() -> AppModel {
        let store = EngineProfileStore()
        return AppModel(client: MultiEngineClient(local: LiveSvodClient(), profiles: store), engines: store)
    }

    public init(client: SvodClient, engines: EngineProfileStore? = nil) {
        self.client = client
        self.engines = engines ?? EngineProfileStore()
        self.editor = EditorModel(client: client)
        self.search = SearchModel(client: client)
        self.graph = GraphModel(client: client)
        self.history = HistoryModel(client: client)
        self.activity = ActivityModel(client: client)
        self.sidebar = SidebarModel(client: client)
        self.engine = EngineModel(client: client)
        self.vault = VaultModel(client: client)
        self.inspector = InspectorModel(client: client)

        // Back-references so feature models can navigate / present.
        editor.app = self
        search.app = self
        graph.app = self
        history.app = self
        activity.app = self
        sidebar.app = self
        engine.app = self
        vault.app = self
        inspector.app = self

        // Re-publish nested model changes so views observing only AppModel refresh.
        // (Views should prefer observing their own sub-model directly; this keeps
        // shell chrome — e.g. the toolbar — in sync without manual plumbing.)
        engine.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Forward vault changes so the toolbar vault indicator/switcher refreshes.
        vault.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Forward settings changes so the app shell (theme, endpoint) reacts.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        self.engines.objectWillChange
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
        settings.lastOpenedVault = vault.activeVaultId
        if centerMode == .graph { centerMode = .editor }
        commandPaletteVisible = false
    }

    /// Open a note that may live in another vault (qualified [[vault:note]] link or a
    /// federated search hit). Switches the active vault first, then opens the path.
    public func openGlobal(_ ref: GlobalNoteRef) {
        if ref.vault != vault.activeVaultId { vault.switchVault(ref.vault) }
        open(path: ref.path)
    }

    /// Open a hit/result that carries an optional vault tag (federated search).
    public func open(path: String, vault tag: String?) {
        if let tag, tag != vault.activeVaultId { self.vault.switchVault(tag) }
        open(path: path)
    }

    // MARK: vault switch
    /// Called by VaultModel after the active vault changes. Clears the open note and
    /// signals vault-scoped panes to reload.
    public func didSwitchVault() {
        selectedPath = nil
        activeConflict = nil
        reloadEpoch &+= 1
        // A reader can look but not type: land in preview.
        if vault.isActiveReadOnly { editor.previewMode = true }
        // `settings`/`indexStatus`/`metrics` describe the engine BEHIND THE ACTIVE VAULT, so every
        // version gate (Members, Sync & Backup, Sources) must be re-read on a switch, not only on a
        // (re)connect — the local and a central engine can run different contracts.
        Task { await engine.loadMeta() }
        objectWillChange.send()
    }

    // MARK: endpoint
    /// Point the (shared) client at the configured host:port and reconnect. All
    /// sub-models share one client instance, so updating its baseURL redirects
    /// every call; the engine then re-opens the WebSocket against the new URL.
    public func applyEndpoint() {
        updateLocalEndpoint()
        engine.reconnectNow()
    }

    private func updateLocalEndpoint() {
        if let m = client as? MultiEngineClient { m.updateLocalBaseURL(settings.baseURL) }
        else { (client as? LiveSvodClient)?.updateBaseURL(settings.baseURL) }
    }

    /// Central-engine profiles changed (Settings → Connection): rebuild the router's remote
    /// set, re-open the merged event stream and refresh the vault list.
    public func reloadEngines() {
        (client as? MultiEngineClient)?.configure(store: engines)
        engine.reconnectNow()
        reloadVaults()
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
        if settings.baseURL != client.baseURL { updateLocalEndpoint() }
        engine.startConnecting()
        // Load the vault list (degrades to a single implicit vault on older engines),
        // THEN reopen the last note. Selecting the path first raced this: the editor's
        // `.task` fired against whatever vault was active (the engine default), so a note
        // remembered from any other vault answered 404 and the pane showed "Not found".
        Task {
            await vault.load()
            reopenLastNoteIfPossible()
        }
    }

    /// Reopen the last note, but only when we know which vault it came from and that
    /// vault still exists. A remembered path with no remembered vault (written by a build
    /// before `lastOpenedVault`, or by a vault that has since been deleted) is dropped
    /// rather than opened against the wrong vault — the empty state beats a 404.
    private func reopenLastNoteIfPossible() {
        guard settings.reopenLastNote,
              let last = settings.lastOpenedPath,
              let vaultId = settings.lastOpenedVault,
              vault.vaults.contains(where: { $0.id == vaultId })
        else { return }
        vault.switchVault(vaultId)   // no-op when it is already active; clears selectedPath otherwise
        selectedPath = last
    }

    /// Reload vault-scoped state after a reconnect (e.g. engine restarted).
    public func reloadVaults() { Task { await vault.load() } }

    /// Refresh vault-scoped panes (tree, graph) without switching vaults — e.g.
    /// after an import added files to the active vault.
    public func refreshActiveVault() { reloadEpoch &+= 1 }

    /// Confirmed deletion of a vault (called from the RootView confirmation dialog).
    /// Moves its files to the Trash via VaultModel; maps engine errors to a banner.
    public func deleteVault(_ v: Vault) {
        Task {
            do {
                try await vault.deleteVault(v.id)
            } catch let e as SvodClientError {
                switch e {
                case .notImplemented, .notFound:
                    vaultActionError = "Deleting vaults needs a newer Svod engine."
                case .http(409, _):
                    vaultActionError = "You can’t delete the default vault or the last remaining vault."
                default:
                    vaultActionError = e.errorDescription
                }
            } catch {
                vaultActionError = error.localizedDescription
            }
        }
    }
}
