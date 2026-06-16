import Foundation

// MARK: - LiveSvodClient
//
// URLSession HTTP + WebSocket implementation of SvodClient. Talks only to the
// loopback App API. Status-code mapping follows the contract: 404 → notFound,
// 409 → conflict(ConflictBody), 400 → badRequest, connection failure → offline.

public final class LiveSvodClient: SvodClient, @unchecked Sendable {

    public private(set) var baseURL: URL
    public private(set) var activeVault: String?
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(baseURL: URL = URL(string: "http://127.0.0.1:7517")!,
                session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            // 30s base (cold /file/links can take ~10s); engine-down is detected instantly
            // via connection-refused on loopback, so a longer idle timeout doesn't slow that.
            // Long git ops (backup/sync/import/reindex) override this per-request (see send/sendNoBody).
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 600
            cfg.waitsForConnectivity = false
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Redirect this (shared) client to a new endpoint. Subsequent calls — including
    /// a freshly opened WebSocket — use the new base.
    public func updateBaseURL(_ url: URL) { baseURL = url }

    /// Switch the active vault. Every subsequent per-vault call appends `?vault=`.
    public func setActiveVault(_ vault: String?) { activeVault = vault }

    /// Per-vault query items: the explicit override if given, else the ambient
    /// active vault, else nothing (engine default vault).
    private func vaulted(_ extra: [URLQueryItem] = [], vault explicit: String? = nil) -> [URLQueryItem] {
        var q = extra
        if let v = explicit ?? activeVault { q.append(.init(name: "vault", value: v)) }
        return q
    }

    // MARK: lifecycle
    public func health() async throws -> Health { try await get("/health") }
    public func ready() async throws -> Ready { try await get("/ready") }

    // MARK: files
    public func tree() async throws -> TreeNode { try await get("/api/v1/tree", query: vaulted()) }

    public func readFile(path: String) async throws -> FileContent {
        try await get("/api/v1/file", query: vaulted([.init(name: "path", value: path)]))
    }

    public func readFile(path: String, inVault vault: String) async throws -> FileContent {
        try await get("/api/v1/file", query: vaulted([.init(name: "path", value: path)], vault: vault))
    }

    @discardableResult
    public func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await send("/api/v1/file", method: "PUT",
                       query: vaulted([.init(name: "path", value: path)]),
                       body: WriteRequest(content: content, expectedRevision: expectedRevision))
    }

    @discardableResult
    public func deleteFile(path: String, expectedRevision: String?) async throws -> WriteResult {
        var q = [URLQueryItem(name: "path", value: path)]
        if let expectedRevision { q.append(.init(name: "expectedRevision", value: expectedRevision)) }
        return try await sendNoBody("/api/v1/file", method: "DELETE", query: vaulted(q))
    }

    @discardableResult
    public func moveFile(from: String, to: String, expectedRevision: String?) async throws -> MoveResult {
        try await send("/api/v1/file/move", method: "POST", query: vaulted(),
                       body: MoveRequest(from: from, to: to, expectedRevision: expectedRevision))
    }

    @discardableResult
    public func restoreFile(trashPath: String, to: String?) async throws -> WriteResult {
        try await send("/api/v1/file/restore", method: "POST", query: vaulted(),
                       body: RestoreRequest(trashPath: trashPath, to: to))
    }

    // MARK: history
    public func history(path: String, max: Int?) async throws -> [CommitInfo] {
        var q = [URLQueryItem(name: "path", value: path)]
        if let max { q.append(.init(name: "max", value: String(max))) }
        struct Wrapper: Decodable { let commits: [CommitInfo] }
        let w: Wrapper = try await get("/api/v1/file/history", query: vaulted(q))
        return w.commits
    }

    public func diff(path: String, from: String, to: String) async throws -> DiffResult {
        try await get("/api/v1/file/diff", query: vaulted([
            .init(name: "path", value: path),
            .init(name: "from", value: from),
            .init(name: "to", value: to),
        ]))
    }

    public func revision(path: String, revision: String) async throws -> FileContent {
        try await get("/api/v1/file/revision", query: vaulted([
            .init(name: "path", value: path),
            .init(name: "revision", value: revision),
        ]))
    }

    // MARK: graph / links
    public func fileLinks(path: String) async throws -> FileLinks {
        try await get("/api/v1/file/links", query: vaulted([.init(name: "path", value: path)]))
    }
    public func graph() async throws -> Graph { try await get("/api/v1/graph", query: vaulted()) }

    // MARK: search
    public func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult {
        try await get("/api/v1/search", query: vaulted(searchItems(query, mode, limit, tags, pathPrefix)))
    }

    public func federatedSearch(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult {
        var q = searchItems(query, mode, limit, tags, pathPrefix)
        q.append(.init(name: "across", value: "true"))   // federate over all vaults
        return try await get("/api/v1/search", query: q)
    }

    private func searchItems(_ query: String, _ mode: SearchMode, _ limit: Int?, _ tags: [String], _ pathPrefix: String?) -> [URLQueryItem] {
        var q = [URLQueryItem(name: "q", value: query),
                 URLQueryItem(name: "mode", value: mode.rawValue)]
        if let limit { q.append(.init(name: "limit", value: String(limit))) }
        for t in tags { q.append(.init(name: "tags", value: t)) }
        if let pathPrefix, !pathPrefix.isEmpty { q.append(.init(name: "pathPrefix", value: pathPrefix)) }
        return q
    }

    // MARK: vaults / import
    public func vaults() async throws -> Vaults { try await get("/api/v1/vaults") }

    @discardableResult
    public func importVault(source: String, into: String?, vault: String?, followSymlinks: Bool) async throws -> ImportResult {
        try await send("/api/v1/import", method: "POST",
                       body: ImportRequest(source: source, into: into, vault: vault, followSymlinks: followSymlinks),
                       timeout: 180)
    }

    // MARK: external sources (per-vault)
    public func listSources(vault: String?) async throws -> [ExternalSource] {
        try await get("/api/v1/sources", query: vaulted())
    }

    @discardableResult
    public func registerSource(vault: String?, path: String, into: String?, followSymlinks: Bool, prune: Bool) async throws -> ExternalSource {
        try await send("/api/v1/sources", method: "POST", query: vaulted(),
                       body: RegisterSourceRequest(path: path, into: into, followSymlinks: followSymlinks, prune: prune))
    }

    public func removeSource(id: String, vault: String?) async throws {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        try await sendNoResult("/api/v1/sources/\(enc)", method: "DELETE", query: vaulted())
    }

    @discardableResult
    public func syncSource(id: String, vault: String?) async throws -> SourceSyncResult {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await sendNoBody("/api/v1/sources/\(enc)/sync", method: "POST", query: vaulted(), timeout: 180)
    }

    @discardableResult
    public func syncAllSources(vault: String?) async throws -> [SourceSyncResult] {
        try await sendNoBody("/api/v1/sources/sync", method: "POST", query: vaulted(), timeout: 180)
    }

    // MARK: meta
    public func tags() async throws -> Tags { try await get("/api/v1/tags", query: vaulted()) }
    public func settings() async throws -> Settings { try await get("/api/v1/settings", query: vaulted()) }
    public func indexStatus() async throws -> IndexStatus { try await get("/api/v1/index/status", query: vaulted()) }
    public func metrics() async throws -> Metrics { try await get("/api/v1/metrics", query: vaulted()) }
    public func conflicts() async throws -> Conflicts { try await get("/api/v1/conflicts", query: vaulted()) }

    @discardableResult
    public func resolveConflict(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await send("/api/v1/conflicts/resolve", method: "POST",
                       body: ResolveConflictRequest(path: path, content: content, expectedRevision: expectedRevision))
    }

    // MARK: sync & backup (per-vault via ?vault=)
    private func vaultQuery(_ vault: String?) -> [URLQueryItem] {
        vault.map { [URLQueryItem(name: "vault", value: $0)] } ?? []
    }

    public func syncConfig(vault: String?) async throws -> SyncConfig {
        try await get("/api/v1/sync/config", query: vaultQuery(vault))
    }
    @discardableResult
    public func setBackup(vault: String?, remote: String, enabled: Bool,
                          backupOnStartup: Bool, backupIntervalMinutes: Int, backupOnChange: Bool,
                          syncEnabled: Bool, syncIntervalMinutes: Int?) async throws -> SyncConfig {
        try await send("/api/v1/settings/backup", method: "PUT", query: vaultQuery(vault),
                       body: BackupConfigRequest(remote: remote, enabled: enabled,
                                                 backupOnStartup: backupOnStartup,
                                                 backupIntervalMinutes: backupIntervalMinutes,
                                                 backupOnChange: backupOnChange,
                                                 syncEnabled: syncEnabled,
                                                 syncIntervalMinutes: syncIntervalMinutes))
    }
    @discardableResult
    public func reindex(vault: String?) async throws -> MaintenanceAck {
        try await sendNoBody("/api/v1/maintenance/reindex", method: "POST", query: vaultQuery(vault), timeout: 180)
    }
    @discardableResult
    public func backupNow(vault: String?) async throws -> BackupAck {
        try await sendNoBody("/api/v1/backup/now", method: "POST", query: vaultQuery(vault), timeout: 180)
    }
    @discardableResult
    public func syncNow(vault: String?) async throws -> SyncAck {
        try await sendNoBody("/api/v1/sync/now", method: "POST", query: vaultQuery(vault), timeout: 180)
    }

    // MARK: embeddings & indexing (contract 0.8.0)
    @discardableResult
    public func setEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderInfo {
        try await send("/api/v1/embedder", method: "PUT", query: vaultQuery(vault), body: request)
    }
    public func testEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderTestResult {
        try await send("/api/v1/embedder/test", method: "POST", query: vaultQuery(vault), body: request)
    }
    public func embedderModels(_ request: EmbedderRequest, vault: String?) async throws -> [EmbedderModelOption] {
        let r: EmbedderModels = try await send("/api/v1/embedder/models", method: "POST", query: vaultQuery(vault), body: request)
        return r.models
    }
    @discardableResult
    public func reembed(vault: String?) async throws -> IndexStatus {
        try await sendNoBody("/api/v1/index/reembed", method: "POST", query: vaultQuery(vault))
    }
    @discardableResult
    public func pauseIndex(vault: String?) async throws -> IndexStatus {
        try await sendNoBody("/api/v1/index/pause", method: "POST", query: vaultQuery(vault))
    }
    @discardableResult
    public func resumeIndex(vault: String?) async throws -> IndexStatus {
        try await sendNoBody("/api/v1/index/resume", method: "POST", query: vaultQuery(vault))
    }

    // MARK: events (WebSocket)
    public func events() -> AsyncThrowingStream<SvodEvent, Error> {
        let wsURL = Self.websocketURL(from: baseURL)
        let task = session.webSocketTask(with: wsURL)
        let decoder = self.decoder
        return AsyncThrowingStream { continuation in
            task.resume()
            func receive() {
                task.receive { result in
                    switch result {
                    case .failure(let error):
                        continuation.finish(throwing: error)
                    case .success(let message):
                        let data: Data?
                        switch message {
                        case .string(let s): data = s.data(using: .utf8)
                        case .data(let d):   data = d
                        @unknown default:    data = nil
                        }
                        if let data, let ev = try? decoder.decode(SvodEvent.self, from: data) {
                            continuation.yield(ev)
                        }
                        receive()   // keep listening
                    }
                }
            }
            receive()
            continuation.onTermination = { _ in
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    static func websocketURL(from base: URL) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = "/api/v1/events"
        return comps.url!
    }

    // MARK: - HTTP plumbing
    private func makeURL(_ path: String, query: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent(""), resolvingAgainstBaseURL: false)!
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        return comps.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = "GET"
        return try await perform(req)
    }

    private func send<T: Decodable, B: Encodable>(_ path: String, method: String,
                                                  query: [URLQueryItem] = [], body: B,
                                                  timeout: TimeInterval? = nil) async throws -> T {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        if let timeout { req.timeoutInterval = timeout }
        return try await perform(req)
    }

    private func sendNoBody<T: Decodable>(_ path: String, method: String,
                                          query: [URLQueryItem] = [], timeout: TimeInterval? = nil) async throws -> T {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = method
        if let timeout { req.timeoutInterval = timeout }
        return try await perform(req)
    }

    /// Perform a request whose success response carries no body (e.g. 204).
    private func sendNoResult(_ path: String, method: String, query: [URLQueryItem] = []) async throws {
        var req = URLRequest(url: makeURL(path, query: query))
        req.httpMethod = method
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut: throw SvodClientError.offline
            default: throw SvodClientError.transport(e.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw SvodClientError.invalidResponse }
        switch http.statusCode {
        case 200...299: return
        case 404: throw SvodClientError.notFound
        case 501: throw SvodClientError.notImplemented(Self.message(from: data, decoder: decoder))
        default: throw SvodClientError.http(status: http.statusCode, message: Self.message(from: data, decoder: decoder))
        }
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlErr as URLError {
            switch urlErr.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .timedOut:
                throw SvodClientError.offline
            default:
                throw SvodClientError.transport(urlErr.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw SvodClientError.invalidResponse }

        switch http.statusCode {
        case 200...299:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw SvodClientError.decoding(String(describing: error)) }
        case 404:
            throw SvodClientError.notFound
        case 409:
            if let body = try? decoder.decode(ConflictBody.self, from: data) {
                throw SvodClientError.conflict(body)
            }
            throw SvodClientError.http(status: 409, message: "Conflict")
        case 400:
            throw SvodClientError.badRequest(Self.message(from: data, decoder: decoder))
        case 501:
            throw SvodClientError.notImplemented(Self.message(from: data, decoder: decoder))
        default:
            throw SvodClientError.http(status: http.statusCode, message: Self.message(from: data, decoder: decoder))
        }
    }

    private static func message(from data: Data, decoder: JSONDecoder) -> String? {
        (try? decoder.decode(APIErrorBody.self, from: data))?.message
    }
}
