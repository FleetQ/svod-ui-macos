import Foundation

// MARK: - MockSvodClient
//
// Canned, dependency-free implementation so every feature builds, runs in SwiftUI
// previews, and demos without a live engine. Data is internally consistent: paths
// in the tree match files, links, search hits, history and the synthetic event
// stream. Feature teammates should use `MockSvodClient.preview` in #Preview blocks.

public final class MockSvodClient: SvodClient, @unchecked Sendable {

    public let baseURL = URL(string: "http://127.0.0.1:7517")!

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
        return Self.tree
    }

    public func readFile(path: String) async throws -> FileContent {
        try await gate()
        guard let f = Self.files[path] else { throw SvodClientError.notFound }
        return f
    }

    @discardableResult
    public func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        try await gate()
        // Simulate a conflict when the caller's expectedRevision is stale.
        if let expectedRevision, let current = Self.files[path], current.revision != expectedRevision {
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
        let base = Self.files[path]?.content ?? "# (older revision)\n"
        return FileContent(path: path, revision: revision, content: base)
    }

    // MARK: graph / links
    public func fileLinks(path: String) async throws -> FileLinks {
        try await gate()
        return FileLinks(
            path: path,
            outlinks: [
                .init(target: "embeddings", resolved: "vault/embeddings.md"),
                .init(target: "lucene-index", resolved: "vault/lucene-index.md"),
                .init(target: "graal-native", resolved: nil),
            ],
            backlinks: ["vault/architecture.md", "vault/build-order.md"],
            unresolved: ["graal-native"])
    }

    public func graph() async throws -> Graph {
        try await gate()
        if behavior == .empty { return Graph(nodes: [], edges: [], unresolved: []) }
        return Self.graph
    }

    // MARK: search
    public func search(query: String, mode: SearchMode, limit: Int?, tags: [String], pathPrefix: String?) async throws -> SearchResult {
        try await gate()
        if behavior == .empty || query.isEmpty {
            return SearchResult(mode: mode.rawValue.uppercased(), hits: [])
        }
        return SearchResult(mode: mode.rawValue.uppercased(), hits: Self.hits(for: query))
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
        return Settings(vaultPath: "/Users/katsarov/Svod", apiVersion: "0.1.0",
                        embedderProvider: "onnx-local", embedderModel: "multilingual-e5-small",
                        embedderDim: 384, host: "127.0.0.1")
    }

    public func indexStatus() async throws -> IndexStatus {
        try await gate()
        return IndexStatus(docCount: 1287, headIndexed: "32af73c", model: "multilingual-e5-small", dim: 384)
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
        return Conflicts(conflicts: [])   // none by default; sync (Step 7) is not live yet
    }

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
    public func setBackup(vault: String?, remote: String, enabled: Bool) async throws -> SyncConfig {
        try await gate()
        return SyncConfig(backupRemote: remote, backupEnabled: enabled, syncPeers: [], role: "authority", hostId: "mac")
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

    static let tree = TreeNode(name: "vault", path: "vault", type: .dir, children: [
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

    static let files: [String: FileContent] = {
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

    static let graph: Graph = Graph(
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

    static func hits(for query: String) -> [SearchHit] {
        [
            .init(path: "vault/architecture.md", heading: "Write path", snippet: "Serialize through the **write-actor**. Atomic tmp → fsync → rename.", score: 0.94, matchedKeyword: true, matchedSemantic: true, tags: ["architecture", "svod"]),
            .init(path: "vault/embeddings.md", heading: "Embeddings", snippet: "BM25 is the guaranteed baseline; **semantics** are opt-in.", score: 0.71, matchedKeyword: false, matchedSemantic: true, tags: ["embeddings", "index"]),
            .init(path: "vault/lucene-index.md", heading: "Lucene index", snippet: "BM25 + HNSW kNN with **RRF** fusion.", score: 0.63, matchedKeyword: true, matchedSemantic: false, tags: ["index"]),
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
