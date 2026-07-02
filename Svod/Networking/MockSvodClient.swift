import Foundation

// MARK: - MockSvodClient
//
// Canned, dependency-free implementation so every feature builds, runs in SwiftUI
// previews, and demos without a live engine. Data is internally consistent: paths
// in the tree match files, links, search hits, history and the synthetic event
// stream. Feature teammates should use `MockSvodClient.preview` in #Preview blocks.

public final class MockSvodClient: SvodClient, @unchecked Sendable {

    public let baseURL = URL(string: "http://127.0.0.1:7517")!
    public private(set) var activeVault: String?
    public func setActiveVault(_ vault: String?) { activeVault = vault }

    /// The vault canned methods read from: the active vault, or the default ("notes").
    private var currentVault: String { activeVault ?? "notes" }

    /// Toggle behaviors for previewing non-happy states.
    public enum Behavior: Sendable { case ok, offline, slow, empty }
    private let behavior: Behavior
    public init(behavior: Behavior = .ok) { self.behavior = behavior }

    public static let preview = MockSvodClient()
    public static let offline = MockSvodClient(behavior: .offline)
    public static let empty = MockSvodClient(behavior: .empty)

    private func gate() async throws {
        if behavior == .offline { throw SvodClientError.offline }
        if behavior == .slow { try? await Task.sleep(nanoseconds: 1_200_000_000) }
    }

    // MARK: lifecycle
    public func health() async throws -> Health { try await gate(); return Health(status: "ok") }
    public func ready() async throws -> Ready { try await gate(); return Ready(ready: true, engine: true, index: true) }

    // MARK: files
    public func tree() async throws -> TreeNode {
        try await gate()
        if behavior == .empty { return TreeNode(name: "vault", path: "vault", type: .dir, children: []) }
        return Self.tree(for: currentVault)
    }

    public func readFile(path: String) async throws -> FileContent {
        try await gate()
        guard let f = Self.files(for: currentVault)[path] else { throw SvodClientError.notFound }
        return f
    }

    public func readFile(path: String, inVault vault: String) async throws -> FileContent {
        try await gate()
        guard let f = Self.files(for: vault)[path] else { throw SvodClientError.notFound }
        return f
    }

    @discardableResult
    public func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await gate()
        // Simulate a conflict when the caller's expectedRevision is stale.
        if let expectedRevision, let current = Self.files(for: currentVault)[path], current.revision != expectedRevision {
            throw SvodClientError.conflict(ConflictBody(
                path: path, expected: expectedRevision, current: current.revision,
                currentContent: current.content))
        }
        return WriteResult(path: path, revision: "rev-\(abs(content.hashValue) % 100000)", commit: Self.newCommit())
    }

    @discardableResult
    public func deleteFile(path: String, expectedRevision: String?) async throws -> WriteResult {
        try await gate()
        return WriteResult(path: ".trash/\(path)", revision: "del", commit: Self.newCommit())
    }

    @discardableResult
    public func moveFile(from: String, to: String, expectedRevision: String?) async throws -> MoveResult {
        try await gate()
        return MoveResult(path: to, revision: "rev-moved", commit: Self.newCommit(),
                          rewrittenBacklinks: ["vault/architecture.md"])
    }

    @discardableResult
    public func restoreFile(trashPath: String, to: String?) async throws -> WriteResult {
        try await gate()
        return WriteResult(path: to ?? trashPath.replacingOccurrences(of: ".trash/", with: ""),
                           revision: "rev-restored", commit: Self.newCommit())
    }

    // MARK: history
    public func history(path: String, max: Int?) async throws -> [CommitInfo] {
        try await gate()
        if behavior == .empty { return [] }
        return Self.commits
    }

    public func diff(path: String, from: String, to: String) async throws -> DiffResult {
        try await gate()
        return DiffResult(path: path, from: from, to: to, diff: Self.sampleDiff)
    }

    public func revision(path: String, revision: String) async throws -> FileContent {
        try await gate()
        let base = Self.files(for: currentVault)[path]?.content ?? "# (older revision)\n"
        return FileContent(path: path, revision: revision, content: base)
    }

    // MARK: graph / links
    public func fileLinks(path: String) async throws -> FileLinks {
        try await gate()
        // The default vault's architecture note is linked-to from the research vault,
        // so it carries a cross-vault backlink ("research:research/method.md").
        let cross = (currentVault == "notes" && path == "vault/architecture.md")
            ? ["research:research/method.md"] : nil
        return FileLinks(
            path: path,
            outlinks: [
                .init(target: "embeddings", resolved: "vault/embeddings.md"),
                .init(target: "lucene-index", resolved: "vault/lucene-index.md"),
                .init(target: "research:method", resolved: "research:research/method.md"),
                .init(target: "graal-native", resolved: nil),
            ],
            backlinks: ["vault/architecture.md", "vault/build-order.md"],
            unresolved: ["graal-native"],
            crossVaultBacklinks: cross)
    }

    public func graph() async throws -> Graph {
        try await gate()
        if behavior == .empty { return Graph(nodes: [], edges: [], unresolved: []) }
        return Self.graph(for: currentVault)
    }

    // MARK: search
    public func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?, memory: MemoryFilter) async throws -> SearchResult {
        try await gate()
        let q = query.isEmpty && memory.isActive ? "memory" : query
        if behavior == .empty || q.isEmpty {
            return SearchResult(mode: mode.rawValue.uppercased(), hits: [])
        }
        return SearchResult(mode: mode.rawValue.uppercased(), hits: Self.hits(for: q, vault: currentVault, tagged: false))
    }

    public func federatedSearch(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?, memory: MemoryFilter) async throws -> SearchResult {
        try await gate()
        let q = query.isEmpty && memory.isActive ? "memory" : query
        if behavior == .empty || q.isEmpty {
            return SearchResult(mode: mode.rawValue.uppercased(), hits: [])
        }
        // Hits from every vault, each tagged with its `vault`.
        let all = Self.hits(for: q, vault: "notes", tagged: true)
                + Self.hits(for: q, vault: "research", tagged: true)
        return SearchResult(mode: mode.rawValue.uppercased(), hits: all)
    }

    // MARK: meta
    public func tags() async throws -> Tags {
        try await gate()
        return Tags(tags: [
            .init(tag: "architecture", count: 8), .init(tag: "svod", count: 14),
            .init(tag: "index", count: 5), .init(tag: "agents", count: 6),
            .init(tag: "adr", count: 3), .init(tag: "embeddings", count: 4),
        ])
    }

    public func settings() async throws -> Settings {
        try await gate()
        return Settings(vaultPath: "/Users/katsarov/Svod", apiVersion: "0.8.0",
                        embedderProvider: Self.mockEmbedder.provider, embedderModel: Self.mockEmbedder.model,
                        embedderDim: Self.mockEmbedder.dimension, host: "127.0.0.1",
                        embedder: Self.mockEmbedder)
    }

    public func indexStatus() async throws -> IndexStatus {
        try await gate()
        return IndexStatus(docCount: 1287, headIndexed: "32af73c",
                           model: Self.mockEmbedder.model, dim: Self.mockEmbedder.dimension,
                           keywordReady: true,
                           embedding: EmbeddingStatus(state: .running, done: 1240, total: 2727,
                                                      provider: Self.mockEmbedder.provider,
                                                      model: Self.mockEmbedder.model))
    }

    public func metrics() async throws -> Metrics {
        try await gate()
        return Metrics(
            write: .init(count: 4213, avgMs: 8.4, maxMs: 142.0, lastMs: 6.1),
            queueDepth: 0, peakQueueDepth: 3,
            index: .init(docCount: 1287, head: "32af73c", indexedHead: "32af73c", lagging: false),
            conflicts: 0, sync: nil)
    }

    public func conflicts() async throws -> Conflicts {
        try await gate()
        if behavior == .empty { return Conflicts(conflicts: []) }
        // One real sync conflict (default vault) with full 3-way content, so the
        // History merge UI previews against base/ours/theirs.
        return Conflicts(conflicts: [Self.sampleConflict])
    }

    // MARK: vaults / import
    // Vaults created via createVault during a preview/offline session — appended so
    // the switcher reflects them without a real engine.
    private static var mockCreatedVaults: [Vault] = []

    public func vaults() async throws -> Vaults {
        try await gate()
        return Vaults(vaults: [
            .init(id: "notes", name: "Notes", isDefault: true,
                  sync: SyncStatus(role: "authority", lastHead: "32af73c", conflicts: 1)),
            .init(id: "research", name: "Research", isDefault: false,
                  sync: SyncStatus(role: "follower", lastHead: "9f1c0d2", conflicts: 0)),
        ] + Self.mockCreatedVaults)
    }

    @discardableResult
    public func createVault(id: String, name: String?, path: String?) async throws -> Vault {
        try await gate()
        let v = Vault(id: id, name: name ?? id, isDefault: false,
                      sync: SyncStatus(role: "solo", lastHead: nil, conflicts: 0))
        Self.mockCreatedVaults.append(v)
        return v
    }

    @discardableResult
    public func deleteVault(id: String, deleteFiles: Bool) async throws -> DeleteVaultResult {
        try await gate()
        Self.mockCreatedVaults.removeAll { $0.id == id }
        return DeleteVaultResult(id: id, path: nil, filesDeleted: deleteFiles)
    }

    // MARK: engine self-update
    public func updateCheck() async throws -> UpdateCheck {
        try await gate()
        // Default mock: engine is current. (Flip updateAvailable to preview the banner.)
        return UpdateCheck(currentVersion: "1.7.0", currentContract: "0.18.0",
                           latestVersion: "1.7.0", updateAvailable: false, compatible: true,
                           notes: "Up to date.")
    }

    @discardableResult
    public func updateApply() async throws -> UpdateApply {
        try await gate()
        return UpdateApply(started: true, candidateVersion: "1.7.0")
    }

    // MARK: MCP agents — LLM access
    private static var mockAgents: [Agent] = [
        Agent(agentId: "svod-foundry", name: "Svod Foundry", role: "WRITE",
              vaults: ["notes", "research"], tokenRef: "file:/tmp/foundry-token.secret"),
        Agent(agentId: "claude-desktop", name: "Claude Desktop", role: "WRITE",
              vaults: ["notes"], tokenRef: "file:/tmp/claude-desktop-token.secret"),
    ]

    public func agents() async throws -> AgentsInfo {
        try await gate()
        return AgentsInfo(agents: Self.mockAgents, mcpPort: 7620, mcpUrl: "http://127.0.0.1:7620")
    }

    @discardableResult
    public func createAgent(_ request: CreateAgentRequest) async throws -> Agent {
        try await gate()
        let a = Agent(agentId: request.agentId, name: request.name ?? request.agentId,
                      role: request.role, vaults: request.vaults, tokenRef: request.tokenRef, prompt: request.prompt)
        Self.mockAgents.append(a)
        return a
    }

    @discardableResult
    public func updateAgent(id: String, _ request: UpdateAgentRequest) async throws -> Agent {
        try await gate()
        guard let i = Self.mockAgents.firstIndex(where: { $0.agentId == id }) else { throw SvodClientError.notFound }
        var a = Self.mockAgents[i]
        if let v = request.name { a.name = v }
        if let v = request.role { a.role = v }
        if let v = request.vaults { a.vaults = v }
        if let v = request.tokenRef { a.tokenRef = v }
        if let v = request.prompt { a.prompt = v }
        Self.mockAgents[i] = a
        return a
    }

    public func deleteAgent(id: String) async throws {
        try await gate()
        guard Self.mockAgents.contains(where: { $0.agentId == id }) else { throw SvodClientError.notFound }
        Self.mockAgents.removeAll { $0.agentId == id }
    }

    @discardableResult
    public func importVault(source: String, into: String?, vault: String?, followSymlinks: Bool) async throws -> ImportResult {
        try await gate()
        let base = (into.map { $0 + "/" } ?? "")
        var imported = [base + "Daily/2026-06-10.md", base + "Projects/svod.md", base + "Inbox/idea.md"]
        var skipped = [base + "Projects/secret.env"]   // secret-blocked
        // With followSymlinks on, a symlinked note is materialized instead of skipped.
        if followSymlinks { imported.append(base + "Linked/shared-spec.md") }
        else { skipped.append(base + "Linked/shared-spec.md (symlink)") }
        return ImportResult(imported: imported, unchanged: [base + "README.md"], skipped: skipped)
    }

    // external sources — a tiny in-memory registry for previews
    private static var mockSources: [ExternalSource] = [
        .init(id: "src-docs", path: "/Users/you/htdocs/boruna-ide/docs", into: "boruna/docs",
              followSymlinks: false, prune: false, lastSyncedAt: "2026-06-13T17:20:00Z"),
    ]
    public func listSources(vault: String?) async throws -> [ExternalSource] {
        try await gate(); return Self.mockSources
    }
    @discardableResult
    public func registerSource(vault: String?, path: String, into: String?, followSymlinks: Bool, prune: Bool, autoSync: Bool) async throws -> ExternalSource {
        try await gate()
        let s = ExternalSource(id: "src-\(abs(path.hashValue) % 100000)", path: path,
                               into: into ?? (path as NSString).lastPathComponent,
                               followSymlinks: followSymlinks, prune: prune, lastSyncedAt: nil,
                               autoSync: autoSync, watching: autoSync)
        Self.mockSources.append(s); return s
    }
    public func updateSource(id: String, vault: String?, autoSync: Bool?, followSymlinks: Bool?, prune: Bool?) async throws -> ExternalSource {
        try await gate()
        guard let i = Self.mockSources.firstIndex(where: { $0.id == id }) else { throw SvodClientError.notFound }
        var s = Self.mockSources[i]
        if let a = autoSync { s.autoSync = a; s.watching = a }
        if let f = followSymlinks { s.followSymlinks = f }
        if let p = prune { s.prune = p }
        Self.mockSources[i] = s; return s
    }
    public func removeSource(id: String, vault: String?) async throws {
        try await gate(); Self.mockSources.removeAll { $0.id == id }
    }
    @discardableResult
    public func syncSource(id: String, vault: String?) async throws -> SourceSyncResult {
        try await gate()
        return SourceSyncResult(id: id, created: ["boruna/docs/setup.md"], updated: ["boruna/docs/api.md"],
                                unchanged: ["boruna/docs/intro.md"], conflicts: [], orphaned: [], deleted: [], skipped: [])
    }
    @discardableResult
    public func syncAllSources(vault: String?) async throws -> [SourceSyncResult] {
        try await gate()
        var out: [SourceSyncResult] = []
        for s in Self.mockSources { out.append(try await syncSource(id: s.id, vault: vault)) }
        return out
    }
    @discardableResult
    public func resolveSourceConflict(id: String, path: String, strategy: String, vault: String?) async throws -> SourceSyncResult {
        try await gate()
        if let i = Self.mockSources.firstIndex(where: { $0.id == id }) {
            Self.mockSources[i].conflicts.removeAll { $0 == path }
        }
        return SourceSyncResult(id: id,
                                created: [], updated: strategy == "takeExternal" ? [path] : [],
                                unchanged: strategy == "keepVault" ? [path] : [],
                                conflicts: [], orphaned: [], deleted: [], skipped: [])
    }

    // embeddings & indexing — in-memory embedder for previews
    private static var mockEmbedder = EmbedderInfo(provider: "local-onnx",
                                                   model: "multilingual-e5-small", endpoint: nil, dimension: 384)
    @discardableResult
    public func setEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderInfo {
        try await gate()
        let dim: Int = {
            switch request.provider {
            case "none": return 0
            case "local-ollama": return 768
            case "remote-openai": return 1536
            default: return 384
            }
        }()
        Self.mockEmbedder = EmbedderInfo(provider: request.provider,
                                         model: request.model ?? Self.mockEmbedder.model,
                                         endpoint: request.endpoint, dimension: dim)
        return Self.mockEmbedder
    }
    public func testEmbedder(_ request: EmbedderRequest, vault: String?) async throws -> EmbedderTestResult {
        try await gate()
        if request.provider == "remote-openai", (request.apiKeyRef ?? "").isEmpty {
            return EmbedderTestResult(ok: false, dimension: nil, latencyMs: nil,
                                      error: "Missing apiKeyRef (use a keychain:/env:/file: reference).")
        }
        let dim = request.provider == "none" ? 0 : (request.provider == "remote-openai" ? 1536 : 384)
        return EmbedderTestResult(ok: true, dimension: dim, latencyMs: 42, error: nil)
    }
    public func embedderModels(_ request: EmbedderRequest, vault: String?) async throws -> [EmbedderModelOption] {
        try await gate()
        let ids: [String]
        switch request.provider {
        case "local-ollama":  ids = ["bge-m3", "nomic-embed-text", "mxbai-embed-large"]
        case "local-onnx":    ids = ["multilingual-e5-small", "bge-small-en-v1.5"]
        case "remote-openai": ids = (request.apiKeyRef ?? "").isEmpty ? [] : ["text-embedding-3-small", "text-embedding-3-large"]
        default:              ids = []
        }
        return ids.map { EmbedderModelOption(id: $0) }
    }
    @discardableResult
    public func reembed(vault: String?) async throws -> IndexStatus { try await gate(); return try await indexStatus() }
    @discardableResult
    public func pauseIndex(vault: String?) async throws -> IndexStatus {
        try await gate()
        return IndexStatus(docCount: 1287, headIndexed: "32af73c", model: Self.mockEmbedder.model,
                           dim: Self.mockEmbedder.dimension, keywordReady: true,
                           embedding: EmbeddingStatus(state: .paused, done: 1240, total: 2727,
                                                      provider: Self.mockEmbedder.provider, model: Self.mockEmbedder.model))
    }
    @discardableResult
    public func resumeIndex(vault: String?) async throws -> IndexStatus { try await gate(); return try await indexStatus() }

    @discardableResult
    public func resolveConflict(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await gate()
        return WriteResult(path: path, revision: "rev-resolved", commit: Self.newCommit())
    }

    // sync & backup — canned config + acks; syncNow exercises the 501 path.
    public func syncConfig(vault: String?) async throws -> SyncConfig {
        try await gate()
        return SyncConfig(backupRemote: "git@hetzner:svod-backup.git", backupEnabled: true,
                          syncPeers: [], role: "authority", hostId: "mac")
    }
    @discardableResult
    public func setBackup(vault: String?, remote: String, enabled: Bool,
                          backupOnStartup: Bool, backupIntervalMinutes: Int, backupOnChange: Bool,
                          syncEnabled: Bool, syncIntervalMinutes: Int?) async throws -> SyncConfig {
        try await gate()
        return SyncConfig(backupRemote: remote, backupEnabled: enabled,
                          backupOnStartup: backupOnStartup,
                          backupIntervalMinutes: backupIntervalMinutes == 0 ? nil : backupIntervalMinutes,
                          backupOnChange: backupOnChange,
                          syncPeers: syncEnabled ? [remote] : [],
                          role: syncEnabled ? "synced" : "authority", hostId: "mac",
                          syncEnabled: syncEnabled, syncIntervalMinutes: syncIntervalMinutes)
    }
    @discardableResult
    public func reindex(vault: String?) async throws -> MaintenanceAck {
        try await gate(); return MaintenanceAck(started: true, docCount: 1287)
    }
    @discardableResult
    public func backupNow(vault: String?) async throws -> BackupAck {
        try await gate(); return BackupAck(ok: true, head: "32af73c")
    }
    @discardableResult
    public func syncNow(vault: String?) async throws -> SyncAck {
        try await gate()
        throw SvodClientError.notImplemented("Multi-host sync is not available yet (Step 7).")
    }

    // MARK: events — synthetic, calm cadence
    public func events() -> AsyncThrowingStream<SvodEvent, Error> {
        AsyncThrowingStream { continuation in
            if behavior == .offline { continuation.finish(throwing: SvodClientError.offline); return }
            let task = Task {
                // seed a few recent items immediately
                var t: Int64 = 1_749_700_000_000
                for ev in Self.seedEvents(baseTs: &t) {
                    continuation.yield(ev)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }
                // then a gentle live trickle
                var i = 0
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if Task.isCancelled { break }
                    t += 4000
                    continuation.yield(Self.liveEvent(index: i, ts: t))
                    i += 1
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Canned data
extension MockSvodClient {

    static func newCommit() -> String { String(format: "%08x", Int.random(in: 0..<0x7fffffff)) }

    // MARK: per-vault dispatch (two vaults: "notes" default, "research")
    static func tree(for vault: String) -> TreeNode { vault == "research" ? researchTree : notesTree }
    static func files(for vault: String) -> [String: FileContent] { vault == "research" ? researchFiles : notesFiles }
    static func graph(for vault: String) -> Graph { vault == "research" ? researchGraph : notesGraph }

    static let notesTree = TreeNode(name: "vault", path: "vault", type: .dir, children: [
        TreeNode(name: "architecture.md", path: "vault/architecture.md", type: .file),
        TreeNode(name: "embeddings.md", path: "vault/embeddings.md", type: .file),
        TreeNode(name: "lucene-index.md", path: "vault/lucene-index.md", type: .file),
        TreeNode(name: "adr", path: "vault/adr", type: .dir, children: [
            TreeNode(name: "0001-write-actor.md", path: "vault/adr/0001-write-actor.md", type: .file),
            TreeNode(name: "0007-socket-activation.md", path: "vault/adr/0007-socket-activation.md", type: .file),
        ]),
        TreeNode(name: "agents", path: "vault/agents", type: .dir, children: [
            TreeNode(name: "friday.md", path: "vault/agents/friday.md", type: .file),
        ]),
    ])

    static let notesFiles: [String: FileContent] = {
        func f(_ path: String, _ rev: String, _ content: String) -> (String, FileContent) {
            (path, FileContent(path: path, revision: rev, content: content))
        }
        return Dictionary(uniqueKeysWithValues: [
            f("vault/architecture.md", "a1b2c3", """
            ---
            title: Architecture
            tags: [architecture, svod]
            status: design-complete
            updated: 2026-06-12
            ---

            # Architecture

            Svod is a local, git-backed markdown knowledge base that serves many
            local AI agents and **never loses files**. The engine is the single
            writer; it guards the source of truth.

            ## Pieces

            - The engine is a headless daemon. See [[embeddings]] and [[lucene-index]].
            - The UI is a controller + client over a stable contract.
            - Agents connect over [[graal-native]] — still unresolved.

            ## Write path

            1. Serialize through the write-actor.
            2. Atomic `tmp → fsync → rename`.
            3. Commit per mutation; revision = blob hash.
            """),
            f("vault/embeddings.md", "d4e5f6", """
            ---
            title: Embeddings
            tags: [embeddings, index]
            ---

            # Embeddings

            Pluggable `Embedder`: `onnx-local` (default) | `ollama` | `none`.
            BM25 is the guaranteed baseline; semantics are opt-in.
            """),
            f("vault/lucene-index.md", "778899", """
            ---
            title: Lucene index
            tags: [index]
            ---

            # Lucene index

            BM25 + HNSW kNN with RRF fusion. Incremental indexing from commits.
            """),
            f("vault/agents/friday.md", "ff00aa", """
            ---
            title: friday
            tags: [agents]
            role: WRITE
            ---

            # friday

            Primary writing agent. Identity maps to git author.
            """),
        ])
    }()

    static let commits: [CommitInfo] = [
        .init(commit: "32af73c1", author: "friday", email: "friday@svod.local", epochSeconds: 1_749_690_000, message: "Refine write path section"),
        .init(commit: "1b9e4d22", author: "you", email: "katsarov@gmail.com", epochSeconds: 1_749_603_600, message: "Add unresolved link to graal-native"),
        .init(commit: "0a7c2f80", author: "sage", email: "sage@svod.local", epochSeconds: 1_749_520_200, message: "Initial architecture note"),
    ]

    static let sampleDiff = """
    diff --git a/vault/architecture.md b/vault/architecture.md
    index 1b9e4d2..32af73c 100644
    --- a/vault/architecture.md
    +++ b/vault/architecture.md
    @@ -10,6 +10,9 @@
     ## Write path

    -1. Serialize writes.
    +1. Serialize through the write-actor.
    +2. Atomic `tmp → fsync → rename`.
    +3. Commit per mutation; revision = blob hash.
    """

    static let notesGraph: Graph = Graph(
        nodes: [
            .init(id: "vault/architecture.md", path: "vault/architecture.md"),
            .init(id: "vault/embeddings.md", path: "vault/embeddings.md"),
            .init(id: "vault/lucene-index.md", path: "vault/lucene-index.md"),
            .init(id: "vault/adr/0001-write-actor.md", path: "vault/adr/0001-write-actor.md"),
            .init(id: "vault/agents/friday.md", path: "vault/agents/friday.md"),
        ],
        edges: [
            .init(source: "vault/architecture.md", target: "vault/embeddings.md"),
            .init(source: "vault/architecture.md", target: "vault/lucene-index.md"),
            .init(source: "vault/embeddings.md", target: "vault/lucene-index.md"),
            .init(source: "vault/adr/0001-write-actor.md", target: "vault/architecture.md"),
        ],
        unresolved: [.init(source: "vault/architecture.md", target: "graal-native")])

    // MARK: research vault (second vault, smaller)
    static let researchTree = TreeNode(name: "research", path: "research", type: .dir, children: [
        TreeNode(name: "method.md", path: "research/method.md", type: .file),
        TreeNode(name: "sources.md", path: "research/sources.md", type: .file),
        TreeNode(name: "findings", path: "research/findings", type: .dir, children: [
            TreeNode(name: "retrieval-eval.md", path: "research/findings/retrieval-eval.md", type: .file),
        ]),
    ])

    static let researchFiles: [String: FileContent] = {
        func f(_ path: String, _ rev: String, _ content: String) -> (String, FileContent) {
            (path, FileContent(path: path, revision: rev, content: content))
        }
        return Dictionary(uniqueKeysWithValues: [
            f("research/method.md", "9f1c0d", """
            ---
            title: Method
            tags: [research, method]
            ---

            # Method

            Evaluating hybrid retrieval quality. The engine architecture is
            documented in [[notes:vault/architecture.md]] — a cross-vault link.

            We compare BM25, dense, and RRF fusion across a held-out set.
            """),
            f("research/sources.md", "7a2b11", """
            ---
            title: Sources
            tags: [research]
            ---

            # Sources

            - RRF (Cormack et al.)
            - E5 multilingual embeddings
            """),
            f("research/findings/retrieval-eval.md", "3c4d55", """
            ---
            title: Retrieval eval
            tags: [research, findings]
            ---

            # Retrieval eval

            RRF fusion wins on recall@10 with negligible latency cost.
            """),
        ])
    }()

    static let researchGraph: Graph = Graph(
        nodes: [
            .init(id: "research/method.md", path: "research/method.md"),
            .init(id: "research/sources.md", path: "research/sources.md"),
            .init(id: "research/findings/retrieval-eval.md", path: "research/findings/retrieval-eval.md"),
        ],
        edges: [
            .init(source: "research/method.md", target: "research/sources.md"),
            .init(source: "research/method.md", target: "research/findings/retrieval-eval.md"),
        ],
        unresolved: [])

    /// A surfaced sync conflict with full 3-way content (default vault).
    static let sampleConflict = Conflicts.Item(
        path: "vault/architecture.md",
        reasons: ["Concurrent edit on two hosts"],
        base: """
        # Architecture

        Svod is a local, git-backed markdown knowledge base.

        ## Write path

        1. Serialize through the write-actor.
        """,
        ours: """
        # Architecture

        Svod is a local, git-backed markdown knowledge base.

        ## Write path

        1. Serialize through the write-actor.
        2. Atomic `tmp → fsync → rename`.
        """,
        theirs: """
        # Architecture

        Svod is a local, git-backed markdown knowledge base that never loses files.

        ## Write path

        1. Serialize through the write-actor.
        """,
        ts: 1_749_700_000_000)

    /// Back-compat shim for preview call sites that predate multi-vault.
    static func hits(for query: String) -> [SearchHit] { hits(for: query, vault: "notes", tagged: false) }

    static func hits(for query: String, vault: String, tagged: Bool) -> [SearchHit] {
        let tag: String? = tagged ? vault : nil
        if vault == "research" {
            return [
                .init(path: "research/method.md", heading: "Method", snippet: "Evaluating **hybrid retrieval** quality across a held-out set.", score: 0.88, matchedKeyword: true, matchedSemantic: true, tags: ["research", "method"], vault: tag),
                .init(path: "research/findings/retrieval-eval.md", heading: "Retrieval eval", snippet: "**RRF** fusion wins on recall@10.", score: 0.66, matchedKeyword: true, matchedSemantic: false, tags: ["research", "findings"], vault: tag),
            ]
        }
        return [
            .init(path: "vault/architecture.md", heading: "Write path", snippet: "Serialize through the **write-actor**. Atomic tmp → fsync → rename.", score: 0.94, matchedKeyword: true, matchedSemantic: true, tags: ["architecture", "svod"], vault: tag),
            .init(path: "vault/embeddings.md", heading: "Embeddings", snippet: "BM25 is the guaranteed baseline; **semantics** are opt-in.", score: 0.71, matchedKeyword: false, matchedSemantic: true, tags: ["embeddings", "index"], vault: tag),
            .init(path: "vault/lucene-index.md", heading: "Lucene index", snippet: "BM25 + HNSW kNN with **RRF** fusion.", score: 0.63, matchedKeyword: true, matchedSemantic: false, tags: ["index"], vault: tag),
        ]
    }

    static func seedEvents(baseTs: inout Int64) -> [SvodEvent] {
        var out: [SvodEvent] = []
        func ev(_ type: EventType, _ payload: EventPayload) -> SvodEvent {
            baseTs += 1500
            return SvodEvent(type: type, ts: baseTs, data: payload)
        }
        out.append(ev(.agentActivity, .init(path: "vault/architecture.md", commit: "32af73c1", agentId: "friday", tool: "write")))
        out.append(ev(.agentActivity, .init(path: "vault/embeddings.md", commit: "1b9e4d22", agentId: "sage", tool: "write")))
        out.append(ev(.fileChanged, .init(path: "vault/lucene-index.md", commit: "0a7c2f80", source: "watcher", tool: "write")))
        out.append(ev(.indexUpdated, .init(docCount: 1287)))
        return out
    }

    static func liveEvent(index: Int, ts: Int64) -> SvodEvent {
        let agents = ["friday", "sage", "you"]
        let paths = ["vault/architecture.md", "vault/embeddings.md", "vault/agents/friday.md"]
        let a = agents[index % agents.count]
        let p = paths[index % paths.count]
        return SvodEvent(type: .agentActivity,
                         ts: ts,
                         data: .init(path: p, commit: newCommit(), agentId: a, tool: "write"))
    }
}
