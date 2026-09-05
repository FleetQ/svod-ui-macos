import Foundation

// MARK: - MultiEngineClient
//
// One `SvodClient` for the whole app that fans out to SEVERAL engines: the local one (personal
// vaults, the connection EngineModel manages) and any number of central engines reached with a
// personal key (company vaults, contract 0.30.0 / ADR-0019). The app keeps its "one shared
// client, ambient active vault" design: `setActiveVault` takes a vault KEY
// (`<vault>@<profile>` for a remote engine, the bare id for the local one), picks the engine
// behind it, and every subsequent call goes there. Explicit-vault overloads route the same way.
//
// Lifecycle calls (`health`, `ready`) always hit the LOCAL engine — EngineModel owns that
// lifecycle. `vaults()` merges every reachable engine and never fails because a central one is
// down; `events()` merges every engine's stream, re-tagging remote events with the vault key.

public final class MultiEngineClient: SvodClient, @unchecked Sendable {

    public struct Remote: Sendable {
        public let id: String
        public let name: String
        public let client: SvodClient
        public init(id: String, name: String, client: SvodClient) { self.id = id; self.name = name; self.client = client }
    }

    public let local: SvodClient
    /// Where a vault whose engine profile has VANISHED is routed: a client that fails every call
    /// with `.offline` (nothing listens on port 1). Falling back to the local engine instead let an
    /// autosave in flight during a profile removal land in the local default vault.
    private let deadEngine: SvodClient = LiveSvodClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    private let lock = NSLock()
    private var remotes: [String: Remote] = [:]
    /// Each remote's default vault id, learnt from its last `vaults()` — used to tag untagged events.
    private var remoteDefaults: [String: String] = [:]
    /// The local engine's default vault id (same source) — an untagged local event means this vault.
    private var localDefault: String?
    private var current: SvodClient
    private var activeKey: String?
    /// Profiles whose engine did not answer the last `vaults()` (shown in Settings).
    public private(set) var unreachable: Set<String> = []
    /// Profiles saved by an older build with a plain-http address to a non-loopback host. They
    /// are never talked to (the key would travel in clear); Settings says so, remove + re-add over https.
    public private(set) var insecure: Set<String> = []

    public init(local: SvodClient, remotes: [Remote] = []) {
        self.local = local
        self.current = local
        for r in remotes { self.remotes[r.id] = r }
    }

    /// Production wiring: one `LiveSvodClient` per engine profile, each with its key.
    @MainActor
    public convenience init(local: LiveSvodClient, profiles: EngineProfileStore) {
        self.init(local: local)
        configure(store: profiles)
    }

    /// Rebuild the remote set from the profile store (after Settings changes). The active
    /// vault, if it lives on a rebuilt profile, is re-pointed at the new client.
    @MainActor
    public func configure(store: EngineProfileStore) {
        var bad: Set<String> = []
        let built = store.profiles.map { p -> Remote in
            if EngineAddress.parse(p.baseURL.absoluteString) == nil {
                bad.insert(p.id)
                return Remote(id: p.id, name: p.name, client: deadEngine)
            }
            return Remote(id: p.id, name: p.name, client: LiveSvodClient(baseURL: p.baseURL, bearerKey: store.apiKey(for: p.id)))
        }
        lock.lock(); insecure = bad; lock.unlock()
        configure(remotes: built)
    }

    public func configure(remotes built: [Remote]) {
        lock.lock()
        remotes = Dictionary(uniqueKeysWithValues: built.map { ($0.id, $0) })
        insecure = insecure.intersection(remotes.keys)   // a profile that is gone is not "insecure" any more
        let key = activeKey
        lock.unlock()
        setActiveVault(key)   // re-points `current` at the rebuilt client (or back to local)
    }

    public var remoteList: [Remote] { lock.lock(); defer { lock.unlock() }; return remotes.values.sorted { $0.name < $1.name } }
    public func remote(_ id: String) -> Remote? { lock.lock(); defer { lock.unlock() }; return remotes[id] }

    /// Redirect the LOCAL engine (Settings → Connection). Remote engines carry their own URLs.
    public func updateLocalBaseURL(_ url: URL) { (local as? LiveSvodClient)?.updateBaseURL(url) }
    /// The local engine's endpoint — what `health()`/`ready()` and "Start Svod" actually target.
    public var localBaseURL: URL { local.baseURL }

    // MARK: routing

    public var baseURL: URL { current.baseURL }
    public var activeVault: String? { activeKey }

    public func setActiveVault(_ vault: String?) {
        let (bare, pid) = VaultKey.parse(vault)
        lock.lock(); defer { lock.unlock() }
        activeKey = vault
        if let pid {
            if let r = remotes[pid] {
                // A remote vault is ALWAYS addressed explicitly: nil would mean that engine's own default.
                r.client.setActiveVault(bare)
                current = r.client
            } else {
                current = deadEngine   // until VaultModel.load() re-selects a vault that exists
            }
        } else {
            local.setActiveVault(vault)
            current = local
        }
    }

    /// The engine + bare vault id behind an explicit vault argument (nil ⇒ the active engine, ambient vault).
    private func target(_ vault: String?) -> (client: SvodClient, vault: String?) {
        guard let vault else { return (current, nil) }
        let (bare, pid) = VaultKey.parse(vault)
        lock.lock(); defer { lock.unlock() }
        if let pid { return remotes[pid].map { ($0.client, bare) } ?? (deadEngine, bare) }
        return (local, vault)
    }

    private func rekey(_ v: Vault, _ r: Remote) -> Vault {
        var out = v
        out.id = VaultKey.make(v.id, profileId: r.id)
        out.engineId = r.id
        out.engineName = r.name
        return out
    }

    // MARK: lifecycle — the LOCAL engine (EngineModel owns this)
    public func health() async throws -> Health { try await local.health() }
    public func ready() async throws -> Ready { try await local.ready() }
    /// Probe one central engine: who am I there (401/403/offline surface as errors).
    public func me(profileId: String) async throws -> Me {
        guard let r = remote(profileId) else { throw SvodClientError.notFound }
        return try await r.client.me()
    }

    // MARK: files
    public func tree() async throws -> TreeNode { try await current.tree() }
    public func readFile(path: String) async throws -> FileContent { try await current.readFile(path: path) }
    public func readFile(path: String, inVault vault: String) async throws -> FileContent {
        let t = target(vault)
        return try await t.client.readFile(path: path, inVault: t.vault ?? vault)
    }
    @discardableResult
    public func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await current.writeFile(path: path, content: content, expectedRevision: expectedRevision)
    }
    @discardableResult
    public func writeFile(path: String, content: String, expectedRevision: String?, inVault vault: String?) async throws -> WriteResult {
        let t = target(vault)
        return try await t.client.writeFile(path: path, content: content, expectedRevision: expectedRevision, inVault: t.vault)
    }
    @discardableResult
    public func deleteFile(path: String, expectedRevision: String?) async throws -> WriteResult {
        try await current.deleteFile(path: path, expectedRevision: expectedRevision)
    }
    @discardableResult
    public func deleteFile(path: String, expectedRevision: String?, inVault vault: String?) async throws -> WriteResult {
        let t = target(vault)
        return try await t.client.deleteFile(path: path, expectedRevision: expectedRevision, inVault: t.vault)
    }
    @discardableResult
    public func moveFile(from: String, to: String, expectedRevision: String?) async throws -> MoveResult {
        try await current.moveFile(from: from, to: to, expectedRevision: expectedRevision)
    }
    @discardableResult
    public func restoreFile(trashPath: String, to: String?) async throws -> WriteResult {
        try await current.restoreFile(trashPath: trashPath, to: to)
    }

    // MARK: history
    public func history(path: String, max: Int?) async throws -> [CommitInfo] { try await current.history(path: path, max: max) }
    public func history(path: String, max: Int?, inVault vault: String?) async throws -> [CommitInfo] {
        let t = target(vault)
        return try await t.client.history(path: path, max: max, inVault: t.vault)
    }
    public func diff(path: String, from: String, to: String) async throws -> DiffResult { try await current.diff(path: path, from: from, to: to) }
    public func revision(path: String, revision: String) async throws -> FileContent { try await current.revision(path: path, revision: revision) }
    public func revision(path: String, revision: String, inVault vault: String?) async throws -> FileContent {
        let t = target(vault)
        return try await t.client.revision(path: path, revision: revision, inVault: t.vault)
    }

    // MARK: graph / links
    public func fileLinks(path: String) async throws -> FileLinks { try await current.fileLinks(path: path) }
    public func graph() async throws -> Graph { try await current.graph() }
    public func graphCommunities(query: String?, level: Int?, limit: Int?, members: String?) async throws -> GraphCommunities {
        try await current.graphCommunities(query: query, level: level, limit: limit, members: members)
    }
    public func graphCommunity(id: String) async throws -> GraphCommunity { try await current.graphCommunity(id: id) }
    public func graphStatus() async throws -> GraphStatus { try await current.graphStatus() }
    public func graphRebuild() async throws -> GraphStatus { try await current.graphRebuild() }

    // MARK: search
    public func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?, memory: MemoryFilter) async throws -> SearchResult {
        try await current.search(query: query, mode: mode, limit: limit, tags: tags, pathPrefix: pathPrefix, memory: memory)
    }
    /// Federation stays WITHIN the active engine; the hits' `vault` tags are re-keyed for a remote.
    public func federatedSearch(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?, memory: MemoryFilter) async throws -> SearchResult {
        var r = try await current.federatedSearch(query: query, mode: mode, limit: limit, tags: tags, pathPrefix: pathPrefix, memory: memory)
        if let pid = VaultKey.parse(activeKey).profileId {
            r.hits = r.hits.map { var h = $0; if let v = h.vault { h.vault = VaultKey.make(v, profileId: pid) }; return h }
        }
        return r
    }

    // MARK: vaults — merged across every reachable engine
    /// Remotes are asked CONCURRENTLY: an unreachable engine costs one request timeout in total,
    /// not one per engine, and the vault list (which launch and every reconnect wait on) is never
    /// held up by a dead central engine longer than by one.
    public func vaults() async throws -> Vaults {
        let localVaults = try await local.vaults().vaults
        let remotes = remoteList
        let results: [(Remote, Result<[Vault], Error>)] = await withTaskGroup(of: (Remote, Result<[Vault], Error>).self) { group in
            for r in remotes {
                group.addTask {
                    do { return (r, .success(try await r.client.vaults().vaults)) }
                    catch { return (r, .failure(error)) }
                }
            }
            var collected: [(Remote, Result<[Vault], Error>)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0.name < $1.0.name }
        }
        var out = localVaults
        var down = Set<String>()
        var defaults: [String: String] = [:]
        for (r, result) in results {
            switch result {
            case .success(let vs):
                defaults[r.id] = vs.first(where: \.isDefault)?.id ?? vs.first?.id
                out += vs.map { rekey($0, r) }
            case .failure:
                down.insert(r.id)
            }
        }
        lock.lock()
        unreachable = down; remoteDefaults = defaults
        localDefault = localVaults.first(where: \.isDefault)?.id ?? localVaults.first?.id
        lock.unlock()
        return Vaults(vaults: out)
    }

    /// A vault created from this Mac is created on THIS Mac's engine: the sheet takes a local
    /// path, and a central engine's vaults are its admin's business (its own config or CLI).
    @discardableResult
    public func createVault(id: String, name: String?, path: String?) async throws -> Vault {
        try await local.createVault(id: id, name: name, path: path)
    }

    @discardableResult
    public func deleteVault(id: String, deleteFiles: Bool) async throws -> DeleteVaultResult {
        let t = target(id)
        if t.client === deadEngine { throw SvodClientError.offline }
        // The app trashes the returned directory PATH: on a central engine that is a server path
        // (or, worse, a path that also exists on this Mac). Refuse until there is a remote-safe flow.
        if t.client !== local { throw SvodClientError.notImplemented("A vault on a central engine is removed by that engine's admin, not from this Mac.") }
        return try await t.client.deleteVault(id: t.vault ?? id, deleteFiles: deleteFiles)
    }

    @discardableResult
    public func importVault(source: String, into: String?, vault: String?, followSymlinks: Bool) async throws -> ImportResult {
        let t = target(vault)
        if t.client === deadEngine { throw SvodClientError.offline }
        // `source` is a folder on THIS Mac; a central engine cannot read it.
        if t.client !== local { throw SvodClientError.notImplemented("Importing a folder from this Mac into a vault on a central engine isn’t supported yet.") }
        return try await t.client.importVault(source: source, into: into, vault: t.vault, followSymlinks: followSymlinks)
    }

    // MARK: engine self-update — THIS Mac's engine, like health/ready. A central engine is
    // updated by its admin on its host; the Updates pane must never "download, swap and restart"
    // a machine the user does not own just because a company vault is selected.
    public func updateCheck() async throws -> UpdateCheck { try await local.updateCheck() }
    @discardableResult
    public func updateApply() async throws -> UpdateApply { try await local.updateApply() }

    public func agents() async throws -> AgentsInfo { try await current.agents() }
    @discardableResult
    public func createAgent(_ request: CreateAgentRequest) async throws -> Agent { try await current.createAgent(request) }
    @discardableResult
    public func updateAgent(id: String, _ request: UpdateAgentRequest) async throws -> Agent { try await current.updateAgent(id: id, request) }
    public func deleteAgent(id: String) async throws { try await current.deleteAgent(id: id) }

    public func me() async throws -> Me { try await current.me() }
    public func users() async throws -> UsersInfo { try await current.users() }
    @discardableResult
    public func createUser(_ request: CreateUserRequest) async throws -> CreatedUser { try await current.createUser(request) }
    @discardableResult
    public func updateUser(id: String, _ request: UpdateUserRequest) async throws -> UserInfo { try await current.updateUser(id: id, request) }
    public func deleteUser(id: String) async throws { try await current.deleteUser(id: id) }
    @discardableResult
    public func rotateUserKey(id: String) async throws -> RotatedKey { try await current.rotateUserKey(id: id) }
    @discardableResult
    public func createSecret(name: String, value: String) async throws -> SecretRef { try await current.createSecret(name: name, value: value) }

    public func memoryDashboard() async throws -> MemoryDashboard { try await current.memoryDashboard() }
    public func memorySessions(distilled: Bool?, limit: Int?) async throws -> [MemorySession] { try await current.memorySessions(distilled: distilled, limit: limit) }
    public func memoryProposals(status: String?) async throws -> [MemoryProposal] { try await current.memoryProposals(status: status) }
    @discardableResult
    public func resolveProposal(id: String, action: String, note: String?) async throws -> MemoryProposal {
        try await current.resolveProposal(id: id, action: action, note: note)
    }

    // MARK: external sources (per-vault)
    public func listSources(vault: String?) async throws -> [ExternalSource] {
        let t = target(vault); return try await t.client.listSources(vault: t.vault)
    }
    @discardableResult
    public func registerSource(vault: String?, path: String, into: String?, followSymlinks: Bool, prune: Bool, autoSync: Bool, writeBack: Bool) async throws -> ExternalSource {
        let t = target(vault)
        if t.client === deadEngine { throw SvodClientError.offline }
        // An external source is a path on THIS Mac; a central engine cannot watch it.
        if t.client !== local { throw SvodClientError.notImplemented("Sources on this Mac can’t feed a vault on a central engine yet.") }
        return try await t.client.registerSource(vault: t.vault, path: path, into: into, followSymlinks: followSymlinks, prune: prune, autoSync: autoSync, writeBack: writeBack)
    }
    @discardableResult
    public func updateSource(id: String, vault: String?, autoSync: Bool?, followSymlinks: Bool?, prune: Bool?, writeBack: Bool?) async throws -> ExternalSource {
        let t = target(vault)
        return try await t.client.updateSource(id: id, vault: t.vault, autoSync: autoSync, followSymlinks: followSymlinks, prune: prune, writeBack: writeBack)
    }
    public func removeSource(id: String, vault: String?) async throws {
        let t = target(vault); try await t.client.removeSource(id: id, vault: t.vault)
    }
    @discardableResult
    public func syncSource(id: String, vault: String?) async throws -> SourceSyncResult {
        let t = target(vault); return try await t.client.syncSource(id: id, vault: t.vault)
    }
    @discardableResult
    public func syncAllSources(vault: String?) async throws -> [SourceSyncResult] {
        let t = target(vault); return try await t.client.syncAllSources(vault: t.vault)
    }
    @discardableResult
    public func resolveSourceConflict(id: String, path: String, strategy: String, vault: String?) async throws -> SourceSyncResult {
        let t = target(vault)
        return try await t.client.resolveSourceConflict(id: id, path: path, strategy: strategy, vault: t.vault)
    }

    // MARK: meta
    public func tags() async throws -> Tags { try await current.tags() }
    public func settings() async throws -> Settings { try await current.settings() }
    public func indexStatus() async throws -> IndexStatus { try await current.indexStatus() }
    public func metrics() async throws -> Metrics { try await current.metrics() }
    public func conflicts() async throws -> Conflicts { try await current.conflicts() }
    @discardableResult
    public func resolveConflict(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await current.resolveConflict(path: path, content: content, expectedRevision: expectedRevision)
    }

    // MARK: sync & backup (per-vault)
    public func syncConfig(vault: String?) async throws -> SyncConfig {
        let t = target(vault); return try await t.client.syncConfig(vault: t.vault)
    }
    @discardableResult
    public func setBackup(vault: String?, remote: String, enabled: Bool,
                          backupOnStartup: Bool, backupIntervalMinutes: Int, backupOnChange: Bool,
                          syncEnabled: Bool, syncIntervalMinutes: Int?) async throws -> SyncConfig {
        let t = target(vault)
        return try await t.client.setBackup(vault: t.vault, remote: remote, enabled: enabled,
                                            backupOnStartup: backupOnStartup, backupIntervalMinutes: backupIntervalMinutes,
                                            backupOnChange: backupOnChange, syncEnabled: syncEnabled, syncIntervalMinutes: syncIntervalMinutes)
    }
    @discardableResult
    public func reindex(vault: String?) async throws -> MaintenanceAck {
        let t = target(vault); return try await t.client.reindex(vault: t.vault)
    }
    @discardableResult
    public func backupNow(vault: String?) async throws -> BackupAck {
        let t = target(vault); return try await t.client.backupNow(vault: t.vault)
    }
    @discardableResult
    public func syncNow(vault: String?) async throws -> SyncAck {
        let t = target(vault); return try await t.client.syncNow(vault: t.vault)
    }

    // MARK: embeddings & indexing (per-vault)
    @discardableResult
    public func setEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderInfo {
        let t = target(vault); return try await t.client.setEmbedder(request, vault: t.vault)
    }
    public func testEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderTestResult {
        let t = target(vault); return try await t.client.testEmbedder(request, vault: t.vault)
    }
    public func embedderModels(_ request: EmbedderRequest, vault: String?) async throws -> [EmbedderModelOption] {
        let t = target(vault); return try await t.client.embedderModels(request, vault: t.vault)
    }
    @discardableResult
    public func reembed(vault: String?) async throws -> IndexStatus {
        let t = target(vault); return try await t.client.reembed(vault: t.vault)
    }
    @discardableResult
    public func pauseIndex(vault: String?) async throws -> IndexStatus {
        let t = target(vault); return try await t.client.pauseIndex(vault: t.vault)
    }
    @discardableResult
    public func resumeIndex(vault: String?) async throws -> IndexStatus {
        let t = target(vault); return try await t.client.resumeIndex(vault: t.vault)
    }

    // MARK: events — every engine, one stream
    /// The local stream's failure ends the merged stream (EngineModel reconnects, which
    /// re-subscribes everything). A remote stream that drops simply goes quiet until then.
    public func events() -> AsyncThrowingStream<SvodEvent, Error> {
        let local = self.local
        let remotes = remoteList
        // Looked up per event, not captured at stream start: EngineModel opens this stream
        // before the first `vaults()` has taught us each remote's default vault id.
        let defaultFor: (String?) -> String? = { [weak self] pid in
            guard let self else { return nil }
            self.lock.lock(); defer { self.lock.unlock() }
            return pid.map { self.remoteDefaults[$0] } ?? self.localDefault
        }
        return AsyncThrowingStream { continuation in
            let localTask = Task {
                do {
                    for try await e in local.events() {
                        // An untagged local event means the local DEFAULT vault. Say so, or the
                        // "nil ⇒ active vault" gate in EngineModel applies it to a remote vault.
                        var tagged = e
                        if tagged.data.vault == nil, let d = defaultFor(nil) { tagged.data.vault = d }
                        continuation.yield(tagged)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let remoteTasks = remotes.map { r in
                Task {
                    do {
                        for try await e in r.client.events() {
                            var tagged = e
                            // Re-key so the vault gate (reconcile, activity filter) compares like with like.
                            tagged.data.vault = VaultKey.make(e.data.vault ?? defaultFor(r.id) ?? "default", profileId: r.id)
                            continuation.yield(tagged)
                        }
                    } catch { /* a dropped remote stream is retried on the next (re)connect */ }
                }
            }
            continuation.onTermination = { _ in
                localTask.cancel()
                remoteTasks.forEach { $0.cancel() }
            }
        }
    }
}
