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
    func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult
    /// Federated search across ALL vaults (`across=true`). Each hit carries its `vault`.
    /// NB: `across` is referenced by the contract's SearchHit doc but is not formally
    /// declared as a /search parameter (v0.3.0) — verify against the live engine.
    func federatedSearch(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult

    // vaults (engine v0.3.0 multi-vault)
    func vaults() async throws -> Vaults
    /// One-shot Obsidian import into `vault` (nil ⇒ default). Idempotent.
    @discardableResult
    func importVault(source: String, into: String?, vault: String?) async throws -> ImportResult
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
    func setBackup(vault: String?, remote: String, enabled: Bool) async throws -> SyncConfig
    @discardableResult
    func reindex(vault: String?) async throws -> MaintenanceAck
    @discardableResult
    func backupNow(vault: String?) async throws -> BackupAck
    @discardableResult
    func syncNow(vault: String?) async throws -> SyncAck

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
        try await search(query: query, mode: .hybrid, limit: nil, tags: [], pathPrefix: nil)
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
