import Foundation

// MARK: - SvodClient
//
// The single protocol every UI surface talks to. Frozen foundation contract —
// feature teammates depend on this read-only and never edit it. Two conforming
// implementations ship in the foundation: `LiveSvodClient` (URLSession HTTP +
// WebSocket) and `MockSvodClient` (canned data, for previews + offline builds).
//
// All methods are async and throw `SvodClientError`. A write that loses an
// optimistic-concurrency race throws `.conflict(ConflictBody)` so the editor /
// history surfaces can drive a 3-way merge.

public protocol SvodClient: AnyObject, Sendable {

    /// Base endpoint, e.g. http://127.0.0.1:7517 — used for display and to derive ws://.
    var baseURL: URL { get }

    /// Active vault id, applied as `?vault=` to every per-vault route. nil ⇒ the
    /// engine's default vault. Set via `setActiveVault` when the user switches vaults;
    /// one shared client means the switch redirects every subsequent fetch at once.
    var activeVault: String? { get }
    func setActiveVault(_ vault: String?)

    // lifecycle
    func health() async throws -> Health
    func ready() async throws -> Ready

    // files
    func tree() async throws -> TreeNode
    func readFile(path: String) async throws -> FileContent
    @discardableResult
    func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult
    @discardableResult
    func deleteFile(path: String, expectedRevision: String?) async throws -> WriteResult
    @discardableResult
    func moveFile(from: String, to: String, expectedRevision: String?) async throws -> MoveResult
    @discardableResult
    func restoreFile(trashPath: String, to: String?) async throws -> WriteResult

    // history
    func history(path: String, max: Int?) async throws -> [CommitInfo]
    func diff(path: String, from: String, to: String) async throws -> DiffResult
    func revision(path: String, revision: String) async throws -> FileContent

    // graph / links
    func fileLinks(path: String) async throws -> FileLinks
    func graph() async throws -> Graph

    // search
    func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?, memory: MemoryFilter) async throws -> SearchResult
    /// Federated search across ALL vaults (`across=true`). Each hit carries its `vault`.
    /// NB: `across` is referenced by the contract's SearchHit doc but is not formally
    /// declared as a /search parameter (v0.3.0) — verify against the live engine.
    func federatedSearch(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?, memory: MemoryFilter) async throws -> SearchResult

    // vaults (engine v0.3.0 multi-vault)
    func vaults() async throws -> Vaults
    /// Create + register a new (empty) vault and return it (engine ≥ contract 0.15.0).
    /// `name`/`path` are optional (nil ⇒ engine defaults). Throws `.notImplemented`/
    /// `.notFound` on engines that predate the create endpoint, and `.conflict`/409
    /// (surfaced as `.http(409,…)`) when the id already exists.
    @discardableResult
    func createVault(id: String, name: String?, path: String?) async throws -> Vault
    /// Delete + unregister a vault (engine ≥ contract 0.16.0). With `deleteFiles` false
    /// the engine leaves the directory on disk and returns its `path` so the app can move
    /// it to the OS Trash. Throws `.notImplemented`/`.notFound` on older engines, and
    /// `.http(409,…)` when refusing the default or last-remaining vault.
    @discardableResult
    func deleteVault(id: String, deleteFiles: Bool) async throws -> DeleteVaultResult
    /// One-shot Obsidian import into `vault` (nil ⇒ default). Idempotent.
    /// `followSymlinks` (contract 0.7.0) materializes symlinks instead of skipping them.
    @discardableResult
    func importVault(source: String, into: String?, vault: String?, followSymlinks: Bool) async throws -> ImportResult

    // engine self-update (engine ≥ contract 0.18.0)
    /// Ask the engine whether a newer compatible release exists. Throws
    /// `.notImplemented`/`.notFound` on engines that predate the endpoint.
    func updateCheck() async throws -> UpdateCheck
    /// Tell the engine to download + apply the latest compatible release (detached
    /// self-update → restart). `.http(409,…)` if no update/incompatible, `.notImplemented`/501
    /// if the engine has no updater configured.
    @discardableResult
    func updateApply() async throws -> UpdateApply

    // MCP agents — LLM access (engine ≥ contract 0.17.0)
    /// List the authorized MCP clients (LLMs) plus the MCP endpoint URL/port.
    /// Throws `.notImplemented`/`.notFound` on engines that predate the endpoint.
    func agents() async throws -> AgentsInfo
    /// Authorize a new LLM. `tokenRef` must be a Secrets ref (`file:`/`env:`/`keychain:`) —
    /// a raw token is rejected (`.http(422,…)`). Duplicate id ⇒ `.http(409,…)`.
    @discardableResult
    func createAgent(_ request: CreateAgentRequest) async throws -> Agent
    /// Update an agent's role/vaults/name/prompt/token (omitted fields unchanged).
    /// Unknown id ⇒ `.notFound`.
    @discardableResult
    func updateAgent(id: String, _ request: UpdateAgentRequest) async throws -> Agent
    /// Revoke an LLM's access. Unknown id ⇒ `.notFound`.
    func deleteAgent(id: String) async throws

    // external sources (engine v0.6.0 — re-syncable external files/dirs)
    func listSources(vault: String?) async throws -> [ExternalSource]
    @discardableResult
    func registerSource(vault: String?, path: String, into: String?, followSymlinks: Bool, prune: Bool, autoSync: Bool, writeBack: Bool) async throws -> ExternalSource
    /// Partial update of a source (contract 0.13.0). Toggling `autoSync` starts/stops
    /// the filesystem watcher immediately. Throws `.notImplemented` on older engines.
    @discardableResult
    func updateSource(id: String, vault: String?, autoSync: Bool?, followSymlinks: Bool?, prune: Bool?, writeBack: Bool?) async throws -> ExternalSource
    func removeSource(id: String, vault: String?) async throws
    @discardableResult
    func syncSource(id: String, vault: String?) async throws -> SourceSyncResult
    @discardableResult
    func syncAllSources(vault: String?) async throws -> [SourceSyncResult]
    /// Resolve one conflicted (locally edited) synced path (contract 0.19.0):
    /// strategy "takeExternal" (external wins once) or "keepVault" (accept the local edit).
    @discardableResult
    func resolveSourceConflict(id: String, path: String, strategy: String, vault: String?) async throws -> SourceSyncResult
    /// Read a note from a SPECIFIC vault without changing the active vault — for
    /// cross-vault [[vault:note]] previews / navigation.
    func readFile(path: String, inVault vault: String) async throws -> FileContent

    // meta
    func tags() async throws -> Tags
    func settings() async throws -> Settings
    func indexStatus() async throws -> IndexStatus
    func metrics() async throws -> Metrics
    func conflicts() async throws -> Conflicts

    /// Resolve a sync conflict with merged content (engine v0.3.0+).
    @discardableResult
    func resolveConflict(path: String, content: String, expectedRevision: String?) async throws -> WriteResult

    // Sync & backup (engine v0.4.0; per-vault via `vault`). Throw `.notImplemented`
    // when the engine returns 501 so the UI degrades to a "needs engine support" note.
    func syncConfig(vault: String?) async throws -> SyncConfig
    @discardableResult
    func setBackup(vault: String?, remote: String, enabled: Bool,
                   backupOnStartup: Bool, backupIntervalMinutes: Int, backupOnChange: Bool,
                   syncEnabled: Bool, syncIntervalMinutes: Int?) async throws -> SyncConfig
    @discardableResult
    func reindex(vault: String?) async throws -> MaintenanceAck
    @discardableResult
    func backupNow(vault: String?) async throws -> BackupAck
    @discardableResult
    func syncNow(vault: String?) async throws -> SyncAck

    // Embeddings & indexing (engine v1.2.0 / contract 0.8.0; global embedder).
    // Throw `.notImplemented` on 501 so the UI degrades on older engines.
    /// Switch the active embedder (persisted; triggers a background re-embed).
    @discardableResult
    func setEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderInfo
    /// Probe an embedder spec (embed a test string) without persisting it.
    func testEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderTestResult
    /// List the models a provider/endpoint can serve (Ollama tags / onnx bundles /
    /// remote /v1/models). Returns [] when the provider can't be enumerated; throws
    /// `.notImplemented` (501) / not-found (404) on older engines — UI falls back to manual entry.
    func embedderModels(_ request: EmbedderRequest, vault: String?) async throws -> [EmbedderModelOption]
    /// Re-embed the whole vault in the background (keyword search stays available).
    @discardableResult
    func reembed(vault: String?) async throws -> IndexStatus
    @discardableResult
    func pauseIndex(vault: String?) async throws -> IndexStatus
    @discardableResult
    func resumeIndex(vault: String?) async throws -> IndexStatus

    /// Live event stream. The stream finishes (or throws) when the socket drops;
    /// reconnection policy lives in the caller (EngineModel), which re-subscribes.
    func events() -> AsyncThrowingStream<SvodEvent, Error>
}

// MARK: - Ergonomic defaults so call sites stay short
public extension SvodClient {
    @discardableResult
    func writeFile(path: String, content: String) async throws -> WriteResult {
        try await writeFile(path: path, content: content, expectedRevision: nil)
    }
    func history(path: String) async throws -> [CommitInfo] {
        try await history(path: path, max: nil)
    }
    func search(query: String) async throws -> SearchResult {
        try await search(query: query, mode: .hybrid, limit: nil, tags: [], pathPrefix: nil, memory: .none)
    }
    /// Search without memory filters (the pre-0.14.0 call shape).
    func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult {
        try await search(query: query, mode: mode, limit: limit, tags: tags, pathPrefix: pathPrefix, memory: .none)
    }
    func federatedSearch(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult {
        try await federatedSearch(query: query, mode: mode, limit: limit, tags: tags, pathPrefix: pathPrefix, memory: .none)
    }
    @discardableResult
    func importVault(source: String, into: String? = nil, vault: String? = nil) async throws -> ImportResult {
        try await importVault(source: source, into: into, vault: vault, followSymlinks: false)
    }
    /// Delete a vault, leaving its files on disk for the app to trash (the default).
    @discardableResult
    func deleteVault(id: String) async throws -> DeleteVaultResult {
        try await deleteVault(id: id, deleteFiles: false)
    }
    /// Register a source without opting into auto-sync (the pre-0.13.0 call shape).
    @discardableResult
    func registerSource(vault: String?, path: String, into: String?, followSymlinks: Bool, prune: Bool) async throws -> ExternalSource {
        try await registerSource(vault: vault, path: path, into: into, followSymlinks: followSymlinks, prune: prune, autoSync: false, writeBack: false)
    }
    /// Register a source without opting into write-back (the pre-0.20.0 call shape).
    @discardableResult
    func registerSource(vault: String?, path: String, into: String?, followSymlinks: Bool, prune: Bool, autoSync: Bool) async throws -> ExternalSource {
        try await registerSource(vault: vault, path: path, into: into, followSymlinks: followSymlinks, prune: prune, autoSync: autoSync, writeBack: false)
    }
    /// Update a source without touching write-back (the pre-0.20.0 call shape).
    @discardableResult
    func updateSource(id: String, vault: String?, autoSync: Bool?, followSymlinks: Bool?, prune: Bool?) async throws -> ExternalSource {
        try await updateSource(id: id, vault: vault, autoSync: autoSync, followSymlinks: followSymlinks, prune: prune, writeBack: nil)
    }
    /// Set the backup destination without changing the schedule (manual: no auto-backup).
    @discardableResult
    func setBackup(vault: String?, remote: String, enabled: Bool) async throws -> SyncConfig {
        try await setBackup(vault: vault, remote: remote, enabled: enabled,
                            backupOnStartup: false, backupIntervalMinutes: 0, backupOnChange: false,
                            syncEnabled: false, syncIntervalMinutes: nil)
    }
    /// Backup-schedule overload that leaves two-way sync off (the pre-0.12.0 call site shape).
    @discardableResult
    func setBackup(vault: String?, remote: String, enabled: Bool,
                   backupOnStartup: Bool, backupIntervalMinutes: Int, backupOnChange: Bool) async throws -> SyncConfig {
        try await setBackup(vault: vault, remote: remote, enabled: enabled,
                            backupOnStartup: backupOnStartup, backupIntervalMinutes: backupIntervalMinutes,
                            backupOnChange: backupOnChange, syncEnabled: false, syncIntervalMinutes: nil)
    }
}

// MARK: - Errors
public enum SvodClientError: Error, LocalizedError, Sendable {
    case conflict(ConflictBody)
    case notFound
    case badRequest(String?)
    case http(status: Int, message: String?)
    case offline                       // could not reach the engine at all
    case notImplemented(String?)       // 501 — engine doesn't support this yet
    case decoding(String)
    case transport(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .conflict:               return "This note changed on disk; resolve the conflict to save."
        case .notFound:               return "Not found."
        case .badRequest(let m):      return m ?? "Bad request."
        case .http(let s, let m):     return m ?? "Server error (\(s))."
        case .offline:                return "The Svod engine is not reachable."
        case .notImplemented(let m):  return m ?? "The engine doesn't support this yet."
        case .decoding(let m):        return "Couldn't read the engine's response. \(m)"
        case .transport(let m):       return m
        case .invalidResponse:        return "Unexpected response from the engine."
        }
    }

    /// True when the failure means "engine is down", so UI can drop to offline state.
    public var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    /// True when the engine returned 501 — the feature isn't available yet.
    public var isNotImplemented: Bool {
        if case .notImplemented = self { return true }
        return false
    }
}
