import Foundation

// MARK: - DTOs
//
// Hand-mapped 1:1 from contract/openapi.yaml (Svod App API v0.1.0). This file is
// part of the frozen foundation contract — feature teammates consume these
// read-only. Field names match the JSON wire format exactly (no CodingKeys needed
// unless the wire name is not a valid Swift identifier).

// MARK: lifecycle
public struct Health: Codable, Hashable, Sendable {
    public var status: String           // enum: [ok]
    public init(status: String) { self.status = status }
}

public struct Ready: Codable, Hashable, Sendable {
    public var ready: Bool
    public var engine: Bool
    public var index: Bool
    public init(ready: Bool, engine: Bool, index: Bool) {
        self.ready = ready; self.engine = engine; self.index = index
    }
}

public struct APIErrorBody: Codable, Hashable, Sendable {
    public var error: String
    public var message: String
}

// MARK: files
public struct FileContent: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var revision: String
    public var content: String
    public var id: String { path + "@" + revision }
    public init(path: String, revision: String, content: String) {
        self.path = path; self.revision = revision; self.content = content
    }
}

public struct WriteRequest: Codable, Hashable, Sendable {
    public var content: String
    /// Blob revision the client last saw; nil means "create new".
    public var expectedRevision: String?
    public init(content: String, expectedRevision: String? = nil) {
        self.content = content; self.expectedRevision = expectedRevision
    }
}

public struct WriteResult: Codable, Hashable, Sendable {
    public var path: String
    public var revision: String
    public var commit: String
}

/// Body returned on a 409 optimistic-concurrency conflict — enough to drive a
/// 3-way merge: `expected` (base rev the client had), `current` (theirs rev),
/// `currentContent` (theirs content). The client supplies "yours".
public struct ConflictBody: Codable, Hashable, Sendable {
    public var path: String
    public var expected: String?
    public var current: String?
    public var currentContent: String?
    public init(path: String, expected: String? = nil, current: String? = nil, currentContent: String? = nil) {
        self.path = path; self.expected = expected; self.current = current; self.currentContent = currentContent
    }
}

public struct MoveRequest: Codable, Hashable, Sendable {
    public var from: String
    public var to: String
    public var expectedRevision: String?
    public init(from: String, to: String, expectedRevision: String? = nil) {
        self.from = from; self.to = to; self.expectedRevision = expectedRevision
    }
}

public struct MoveResult: Codable, Hashable, Sendable {
    public var path: String
    public var revision: String
    public var commit: String
    /// Notes whose [[wikilinks]] were rewritten in the same commit.
    public var rewrittenBacklinks: [String]
}

public struct RestoreRequest: Codable, Hashable, Sendable {
    public var trashPath: String
    public var to: String?
    public init(trashPath: String, to: String? = nil) { self.trashPath = trashPath; self.to = to }
}

public struct TreeNode: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case file, dir }
    public var name: String
    public var path: String
    public var type: Kind
    public var children: [TreeNode]?
    public var id: String { path }
    /// Every file path under this node, recursively.
    public var filePaths: Set<String> {
        var out = Set<String>()
        func walk(_ n: TreeNode) {
            if n.type == .file { out.insert(n.path) }
            n.children?.forEach(walk)
        }
        walk(self)
        return out
    }
    public init(name: String, path: String, type: Kind, children: [TreeNode]? = nil) {
        self.name = name; self.path = path; self.type = type; self.children = children
    }
}

public struct CommitInfo: Codable, Hashable, Sendable, Identifiable {
    public var commit: String
    public var author: String
    public var email: String
    public var epochSeconds: Int64
    public var message: String
    public var id: String { commit }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(epochSeconds)) }
    public init(commit: String, author: String, email: String, epochSeconds: Int64, message: String) {
        self.commit = commit; self.author = author; self.email = email
        self.epochSeconds = epochSeconds; self.message = message
    }
}

public struct DiffResult: Codable, Hashable, Sendable {
    public var path: String
    public var from: String
    public var to: String
    public var diff: String          // unified diff text
    public init(path: String, from: String, to: String, diff: String) {
        self.path = path; self.from = from; self.to = to; self.diff = diff
    }
}

// MARK: search
public enum SearchMode: String, Codable, Hashable, Sendable, CaseIterable {
    case hybrid, keyword, semantic       // request values (lowercase per contract)
    public var label: String {
        switch self { case .hybrid: "Hybrid"; case .keyword: "Keyword"; case .semantic: "Semantic" }
    }
}

/// Memory typing/lifecycle filters for /search (contract 0.14.0). All optional;
/// `.none` reproduces pre-0.14.0 behavior. `type`/`status` match a note's reserved
/// frontmatter keys; `includeAll` bypasses the engine's default hiding of
/// revoked/provisional/superseded/expired memories.
public struct MemoryFilter: Hashable, Sendable {
    public var type: String?
    public var status: String?
    public var includeAll: Bool
    public init(type: String? = nil, status: String? = nil, includeAll: Bool = false) {
        self.type = type; self.status = status; self.includeAll = includeAll
    }
    public static let none = MemoryFilter()
    public var isActive: Bool { type != nil || status != nil || includeAll }
}

public struct SearchResult: Codable, Hashable, Sendable {
    public var mode: String              // response enum is UPPERCASE: HYBRID/KEYWORD/SEMANTIC
    public var hits: [SearchHit]
    public init(mode: String, hits: [SearchHit]) { self.mode = mode; self.hits = hits }
}

public struct SearchHit: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var heading: String
    public var snippet: String
    public var score: Double
    public var matchedKeyword: Bool
    public var matchedSemantic: Bool
    public var tags: [String]
    /// Vault id of this hit — only populated on a federated (`across=true`) search.
    /// nil on a single-vault search (the hit is in the active vault).
    public var vault: String?
    /// Estimated token cost of this hit's content, using the engine's ~4-chars/token
    /// estimator (the same one `context_pack` uses). nil when the engine predates the
    /// field — the UI then hides the token affordance rather than inventing a count.
    public var tokens: Int?
    // id must stay unique across vaults in federated results.
    public var id: String { (vault.map { $0 + ":" } ?? "") + path + "#" + heading }
    public init(path: String, heading: String, snippet: String, score: Double,
                matchedKeyword: Bool, matchedSemantic: Bool, tags: [String], vault: String? = nil,
                tokens: Int? = nil) {
        self.path = path; self.heading = heading; self.snippet = snippet; self.score = score
        self.matchedKeyword = matchedKeyword; self.matchedSemantic = matchedSemantic
        self.tags = tags; self.vault = vault; self.tokens = tokens
    }
}

// MARK: graph
public struct Graph: Codable, Hashable, Sendable {
    public struct Node: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var path: String
        public init(id: String, path: String) { self.id = id; self.path = path }
    }
    public struct Edge: Codable, Hashable, Sendable {
        public var source: String
        public var target: String
        public init(source: String, target: String) { self.source = source; self.target = target }
    }
    public var nodes: [Node]
    public var edges: [Edge]
    public var unresolved: [Edge]
    public init(nodes: [Node], edges: [Edge], unresolved: [Edge]) {
        self.nodes = nodes; self.edges = edges; self.unresolved = unresolved
    }
}

// MARK: graph communities (contract 0.24.0, additive)

/// One thematic community of the engine's derived graph.
///
/// `summary` is nil when the engine built the graph without a summary provider — the community is
/// still fully usable and `title` carries a machine-derived label, so the UI must never treat a nil
/// summary as an error state.
public struct GraphCommunity: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var level: Int
    public var title: String
    public var summary: String?
    public var size: Int
    public var members: [String]
    /// Contract 0.26.0. Members attached after the summary was written, so `summary` describes
    /// slightly fewer notes than `size` counts. Optional: an older engine simply omits it.
    public var addedSinceSummary: Int?
    public init(
        id: String, level: Int, title: String, summary: String? = nil, size: Int,
        members: [String], addedSinceSummary: Int? = nil
    ) {
        self.id = id; self.level = level; self.title = title
        self.summary = summary; self.size = size; self.members = members
        self.addedSinceSummary = addedSinceSummary
    }
}

public struct GraphCommunities: Codable, Hashable, Sendable {
    public var state: String
    public var stale: Bool
    public var communities: [GraphCommunity]
    public init(state: String, stale: Bool, communities: [GraphCommunity]) {
        self.state = state; self.stale = stale; self.communities = communities
    }
}

/// Build state of the derived graph. `stale` means the vault moved past the build's HEAD; the engine
/// still serves results, so this is a badge to show, not a reason to hide the pane.
public struct GraphStatus: Codable, Hashable, Sendable {
    public var state: String
    public var enabled: Bool
    public var stale: Bool
    public var head: String?
    public var currentHead: String?
    public var builtAt: Int64?
    public var noteCount: Int
    public var edgeCount: Int
    public var linkEdgeCount: Int
    public var simEdgeCount: Int
    public var communityCount: Int
    public var levelCount: Int
    public var vectorCoverage: Double
    public var summaryProvider: String
    public var summarisedCount: Int
    /// Contract 0.26.0. Whether the engine attaches new notes to existing themes between builds.
    ///
    /// Optional on purpose, and it must be read BEFORE the two counts below: an engine older than
    /// 0.26.0 omits all three, and with the feature switched off the counts are never computed — in
    /// both cases a bare `0` would read as "nothing has changed", which is a different claim.
    public var incremental: Bool?
    /// Notes placed on an existing theme since the last full build. Reachable through the themes.
    public var attachedCount: Int?
    /// Notes on no theme at all — not yet attached, or with no close-enough neighbour.
    public var pendingCount: Int?
    /// Contract 0.27.0. Fraction of attached notes whose placement vote no longer matches where they
    /// sit. A proxy: 0.0 means no sampled attachment has drifted, not that the partition is optimal.
    public var driftRatio: Double?
    public var error: String?
    public var progress: String?

    public init(
        state: String, enabled: Bool, stale: Bool = false, head: String? = nil, currentHead: String? = nil,
        builtAt: Int64? = nil, noteCount: Int = 0, edgeCount: Int = 0, linkEdgeCount: Int = 0,
        simEdgeCount: Int = 0, communityCount: Int = 0, levelCount: Int = 0, vectorCoverage: Double = 0,
        summaryProvider: String = "none", summarisedCount: Int = 0,
        incremental: Bool? = nil, attachedCount: Int? = nil, pendingCount: Int? = nil,
        driftRatio: Double? = nil, error: String? = nil, progress: String? = nil
    ) {
        self.state = state; self.enabled = enabled; self.stale = stale
        self.head = head; self.currentHead = currentHead; self.builtAt = builtAt
        self.noteCount = noteCount; self.edgeCount = edgeCount
        self.linkEdgeCount = linkEdgeCount; self.simEdgeCount = simEdgeCount
        self.communityCount = communityCount; self.levelCount = levelCount
        self.vectorCoverage = vectorCoverage; self.summaryProvider = summaryProvider
        self.summarisedCount = summarisedCount
        self.incremental = incremental; self.attachedCount = attachedCount; self.pendingCount = pendingCount
        self.driftRatio = driftRatio
        self.error = error; self.progress = progress
    }

    public var isBuilding: Bool { state == "BUILDING" }
    public var isReady: Bool { state == "READY" }

    /// How many notes arrived since the last full build, or nil when this engine cannot say.
    ///
    /// nil is not zero: it means the question was not answered (engine older than 0.26.0, or
    /// incremental attachment off), and the UI must fall back to the plain "stale" badge rather than
    /// claim nothing is missing.
    public var newSinceBuild: Int? {
        guard incremental == true else { return nil }
        return (attachedCount ?? 0) + (pendingCount ?? 0)
    }
}

public struct FileLinks: Codable, Hashable, Sendable {
    public struct OutLink: Codable, Hashable, Sendable, Identifiable {
        public var target: String
        public var resolved: String?
        public var id: String { target }
        public init(target: String, resolved: String? = nil) { self.target = target; self.resolved = resolved }
    }
    public var path: String
    public var outlinks: [OutLink]
    public var backlinks: [String]
    public var unresolved: [String]
    /// Notes in OTHER vaults that link here, as global ids ("vault:path"); engine v0.3.0+.
    /// nil when single-vault or the engine doesn't populate it.
    public var crossVaultBacklinks: [String]?
    /// Parsed cross-vault backlinks for navigation; empty when none.
    public var crossVaultRefs: [GlobalNoteRef] {
        (crossVaultBacklinks ?? []).compactMap(GlobalNoteRef.init(globalId:))
    }
    public init(path: String, outlinks: [OutLink], backlinks: [String], unresolved: [String],
                crossVaultBacklinks: [String]? = nil) {
        self.path = path; self.outlinks = outlinks; self.backlinks = backlinks
        self.unresolved = unresolved; self.crossVaultBacklinks = crossVaultBacklinks
    }
}

/// A note addressed across vaults: the global id form is "vault:path"
/// (e.g. "research:vault/method.md"). Used by qualified [[vault:note]] links
/// and `FileLinks.crossVaultBacklinks`.
public struct GlobalNoteRef: Hashable, Sendable, Identifiable {
    public var vault: String
    public var path: String
    public var globalId: String { vault + ":" + path }
    public var id: String { globalId }
    public init(vault: String, path: String) { self.vault = vault; self.path = path }
    /// Parse "vault:path"; nil if there's no vault prefix (a same-vault link).
    public init?(globalId: String) {
        guard let i = globalId.firstIndex(of: ":") else { return nil }
        let v = String(globalId[..<i])
        let p = String(globalId[globalId.index(after: i)...])
        guard !v.isEmpty, !p.isEmpty else { return nil }
        self.vault = v; self.path = p
    }
}

// MARK: meta
public struct Tags: Codable, Hashable, Sendable {
    public struct Tag: Codable, Hashable, Sendable, Identifiable {
        public var tag: String
        public var count: Int
        public var id: String { tag }
        public init(tag: String, count: Int) { self.tag = tag; self.count = count }
    }
    public var tags: [Tag]
    public init(tags: [Tag]) { self.tags = tags }
}

public struct Settings: Codable, Hashable, Sendable {
    public var vaultPath: String
    public var apiVersion: String
    public var embedderProvider: String
    public var embedderModel: String?
    public var embedderDim: Int?
    public var host: String
    /// Active embedder (contract 0.8.0); nil on older engines.
    public var embedder: EmbedderInfo? = nil
}

public struct IndexStatus: Codable, Hashable, Sendable {
    public var docCount: Int
    public var headIndexed: String?
    public var model: String
    public var dim: Int
    /// Contract 0.8.0: BM25 ready (keyword search works) + background-embedding progress.
    public var keywordReady: Bool
    public var embedding: EmbeddingStatus?
    public init(docCount: Int, headIndexed: String? = nil, model: String, dim: Int,
                keywordReady: Bool = true, embedding: EmbeddingStatus? = nil) {
        self.docCount = docCount; self.headIndexed = headIndexed; self.model = model; self.dim = dim
        self.keywordReady = keywordReady; self.embedding = embedding
    }
    // Tolerant decode so older engines (without the 0.8.0 fields) still parse.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        docCount = try c.decodeIfPresent(Int.self, forKey: .docCount) ?? 0
        headIndexed = try c.decodeIfPresent(String.self, forKey: .headIndexed)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        dim = try c.decodeIfPresent(Int.self, forKey: .dim) ?? 0
        keywordReady = try c.decodeIfPresent(Bool.self, forKey: .keywordReady) ?? true
        embedding = try c.decodeIfPresent(EmbeddingStatus.self, forKey: .embedding)
    }
}

// MARK: - Embeddings & indexing (engine v1.2.0 / contract 0.8.0)

/// The active embedder. `endpoint` is nil for in-process providers (local-onnx/none).
public struct EmbedderInfo: Codable, Hashable, Sendable {
    public var provider: String        // local-onnx | local-ollama | remote-openai | none
    public var model: String
    public var endpoint: String?
    public var dimension: Int          // 0 when BM25-only / not yet indexed
    public init(provider: String, model: String, endpoint: String? = nil, dimension: Int = 0) {
        self.provider = provider; self.model = model; self.endpoint = endpoint; self.dimension = dimension
    }
}

/// Background-embedding progress (also pushed as the `index.progress` WS event).
public struct EmbeddingStatus: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case idle, running, paused, error, unknown
        public init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    public var state: State
    public var done: Int
    public var total: Int
    public var provider: String
    public var model: String
    public var error: String?
    public init(state: State, done: Int, total: Int, provider: String, model: String, error: String? = nil) {
        self.state = state; self.done = done; self.total = total
        self.provider = provider; self.model = model; self.error = error
    }
    /// 0…1 progress, or nil when total is unknown/zero.
    public var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }
}

/// Switch (PUT /embedder) or probe (POST /embedder/test) the embedder.
/// `apiKeyRef` is a Secrets reference (env:/file:/keychain:) — a raw key is rejected (422).
public struct EmbedderRequest: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String?
    public var endpoint: String?
    public var apiKeyRef: String?
    public var maxThreads: Int?
    public init(provider: String, model: String? = nil, endpoint: String? = nil,
                apiKeyRef: String? = nil, maxThreads: Int? = nil) {
        self.provider = provider; self.model = model; self.endpoint = endpoint
        self.apiKeyRef = apiKeyRef; self.maxThreads = maxThreads
    }
}

public struct EmbedderTestResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var dimension: Int?
    public var latencyMs: Int64?
    public var error: String?
}

/// A model the engine can offer for a given embedder spec (Ollama tag / onnx bundle /
/// remote /v1/models id). `dimension` is filled only when cheaply known.
public struct EmbedderModelOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var dimension: Int?
    public init(id: String, dimension: Int? = nil) { self.id = id; self.dimension = dimension }
}

/// Response of POST /embedder/models — the models a provider/endpoint can serve.
/// An empty list means the provider couldn't be enumerated (unreachable, no key) —
/// the UI falls back to manual model entry.
public struct EmbedderModels: Codable, Hashable, Sendable {
    public var provider: String
    public var models: [EmbedderModelOption]
    public init(provider: String, models: [EmbedderModelOption]) {
        self.provider = provider; self.models = models
    }
}

public struct Conflicts: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable, Identifiable {
        public var path: String
        public var reasons: [String]?
        // engine v0.3.0+: 3-way content now ships with the conflict list.
        public var base: String?
        public var ours: String?
        public var theirs: String?
        public var ts: Int64?
        public var id: String { path }
        public init(path: String, reasons: [String]? = nil,
                    base: String? = nil, ours: String? = nil, theirs: String? = nil, ts: Int64? = nil) {
            self.path = path; self.reasons = reasons
            self.base = base; self.ours = ours; self.theirs = theirs; self.ts = ts
        }
    }
    public var conflicts: [Item]
    public init(conflicts: [Item]) { self.conflicts = conflicts }
}

/// Resolve a (sync) conflict with merged content — engine v0.3.0 `POST /conflicts/resolve`.
public struct ResolveConflictRequest: Codable, Hashable, Sendable {
    public var path: String
    public var content: String
    public var expectedRevision: String?
    public init(path: String, content: String, expectedRevision: String? = nil) {
        self.path = path; self.content = content; self.expectedRevision = expectedRevision
    }
}

// MARK: - Sync & backup (engine v0.4.0 UI-settings endpoints; per-vault via ?vault=)
public struct SyncConfig: Codable, Hashable, Sendable {
    public var backupRemote: String?
    public var backupEnabled: Bool
    // Auto-backup schedule (contract 0.11.0). `backupIntervalMinutes` nil/0 = no timer.
    public var backupOnStartup: Bool
    public var backupIntervalMinutes: Int?
    public var backupOnChange: Bool
    // Observable last-success markers (engine-tracked; survive restarts + scheduled runs).
    public var lastBackupAt: String?     // ISO-8601
    public var lastBackupHead: String?
    public var syncPeers: [String]
    public var role: String?
    public var hostId: String?
    // Two-way multi-machine sync (contract 0.12.0). When `syncEnabled`, the same
    // `backupRemote` is the bidirectional bus and one-way backup is retired.
    public var syncEnabled: Bool
    public var syncIntervalMinutes: Int?
    public init(backupRemote: String? = nil, backupEnabled: Bool = false,
                backupOnStartup: Bool = false, backupIntervalMinutes: Int? = nil,
                backupOnChange: Bool = false, lastBackupAt: String? = nil, lastBackupHead: String? = nil,
                syncPeers: [String] = [], role: String? = nil, hostId: String? = nil,
                syncEnabled: Bool = false, syncIntervalMinutes: Int? = nil) {
        self.backupRemote = backupRemote; self.backupEnabled = backupEnabled
        self.backupOnStartup = backupOnStartup; self.backupIntervalMinutes = backupIntervalMinutes
        self.backupOnChange = backupOnChange; self.lastBackupAt = lastBackupAt; self.lastBackupHead = lastBackupHead
        self.syncPeers = syncPeers; self.role = role; self.hostId = hostId
        self.syncEnabled = syncEnabled; self.syncIntervalMinutes = syncIntervalMinutes
    }
    // Tolerant decode so older engines (no schedule/marker fields) still work.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        backupRemote = try c.decodeIfPresent(String.self, forKey: .backupRemote)
        backupEnabled = try c.decodeIfPresent(Bool.self, forKey: .backupEnabled) ?? false
        backupOnStartup = try c.decodeIfPresent(Bool.self, forKey: .backupOnStartup) ?? false
        backupIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .backupIntervalMinutes)
        backupOnChange = try c.decodeIfPresent(Bool.self, forKey: .backupOnChange) ?? false
        lastBackupAt = try c.decodeIfPresent(String.self, forKey: .lastBackupAt)
        lastBackupHead = try c.decodeIfPresent(String.self, forKey: .lastBackupHead)
        syncPeers = try c.decodeIfPresent([String].self, forKey: .syncPeers) ?? []
        role = try c.decodeIfPresent(String.self, forKey: .role)
        hostId = try c.decodeIfPresent(String.self, forKey: .hostId)
        syncEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        syncIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .syncIntervalMinutes)
    }
}

public struct BackupConfigRequest: Codable, Hashable, Sendable {
    public var remote: String          // a git remote URL; secrets only as Secrets refs
    public var enabled: Bool
    public var backupOnStartup: Bool
    public var backupIntervalMinutes: Int   // 0 = no timer
    public var backupOnChange: Bool
    // Two-way sync (contract 0.12.0). When `syncEnabled`, `remote` becomes the
    // bidirectional bus. `syncIntervalMinutes` nil ⇒ engine default (3).
    public var syncEnabled: Bool
    public var syncIntervalMinutes: Int?
    public init(remote: String, enabled: Bool, backupOnStartup: Bool = false,
                backupIntervalMinutes: Int = 0, backupOnChange: Bool = false,
                syncEnabled: Bool = false, syncIntervalMinutes: Int? = nil) {
        self.remote = remote; self.enabled = enabled
        self.backupOnStartup = backupOnStartup
        self.backupIntervalMinutes = backupIntervalMinutes
        self.backupOnChange = backupOnChange
        self.syncEnabled = syncEnabled
        self.syncIntervalMinutes = syncIntervalMinutes
    }
}

public struct MaintenanceAck: Codable, Hashable, Sendable {
    public var started: Bool
    public var docCount: Int?
}

public struct BackupAck: Codable, Hashable, Sendable {
    public var ok: Bool
    public var head: String?
}

public struct SyncAck: Codable, Hashable, Sendable {
    public var ok: Bool
    public var head: String?
    public var conflicts: Int?
}

public struct Metrics: Codable, Hashable, Sendable {
    public struct Write: Codable, Hashable, Sendable {
        public var count: Int64
        public var avgMs: Double
        public var maxMs: Double
        public var lastMs: Double
    }
    public struct Index: Codable, Hashable, Sendable {
        public var docCount: Int
        public var head: String?
        public var indexedHead: String?
        public var lagging: Bool
    }
    public struct Sync: Codable, Hashable, Sendable {
        public var role: String
        public var lastHead: String?
        public var conflicts: Int
        // Live two-way sync standing (contract 0.12.0); absent on older engines.
        public var syncStatus: String?      // "inSync" | "syncing" | "conflicts" | "offline" | "error"
        public var lastSyncedAt: String?    // ISO-8601
    }
    public var write: Write
    public var queueDepth: Int
    public var peakQueueDepth: Int
    public var index: Index
    public var conflicts: Int
    public var sync: Sync?
}

// MARK: - Vaults (engine v0.3.0 multi-vault)

/// Per-vault sync standing (contract `SyncStatus`). Each vault is its own git repo,
/// lock, index and sync, so sync state is reported per vault.
public struct SyncStatus: Codable, Hashable, Sendable {
    public var role: String              // "synced" | "authority" | "follower" | "solo"
    public var lastHead: String?
    public var conflicts: Int
    // Live sync standing (contract 0.12.0). null until the first two-way sync.
    public var syncStatus: String?       // "inSync" | "syncing" | "conflicts" | "offline" | "error"
    public var lastSyncedAt: String?     // ISO-8601
    public init(role: String, lastHead: String? = nil, conflicts: Int = 0,
                syncStatus: String? = nil, lastSyncedAt: String? = nil) {
        self.role = role; self.lastHead = lastHead; self.conflicts = conflicts
        self.syncStatus = syncStatus; self.lastSyncedAt = lastSyncedAt
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "solo"
        lastHead = try c.decodeIfPresent(String.self, forKey: .lastHead)
        conflicts = try c.decodeIfPresent(Int.self, forKey: .conflicts) ?? 0
        syncStatus = try c.decodeIfPresent(String.self, forKey: .syncStatus)
        lastSyncedAt = try c.decodeIfPresent(String.self, forKey: .lastSyncedAt)
    }
}

public struct Vaults: Codable, Hashable, Sendable {
    public struct Vault: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// `default` on the wire — the vault used when `?vault=` is omitted.
        public var isDefault: Bool
        public var sync: SyncStatus?
        /// The caller's access to this vault: `admin` | `editor` | `reader` (contract 0.30.0; nil on older engines).
        public var role: String?
        /// App-side only (not on the wire): the engine profile this vault came from; nil ⇒ the local engine.
        public var engineId: String? = nil
        public var engineName: String? = nil
        public init(id: String, name: String, isDefault: Bool, sync: SyncStatus? = nil, role: String? = nil,
                    engineId: String? = nil, engineName: String? = nil) {
            self.id = id; self.name = name; self.isDefault = isDefault; self.sync = sync
            self.role = role; self.engineId = engineId; self.engineName = engineName
        }
        enum CodingKeys: String, CodingKey {
            case id, name, sync, role
            case isDefault = "default"   // `default` is a Swift keyword
        }
        public var isRemote: Bool { engineId != nil }
        /// True when the engine said this caller may only read here.
        public var isReadOnly: Bool { role == "reader" }
    }
    public var vaults: [Vault]
    public init(vaults: [Vault]) { self.vaults = vaults }
    public var defaultVault: Vault? { vaults.first(where: \.isDefault) ?? vaults.first }
}

public typealias Vault = Vaults.Vault

/// Create a brand-new (empty) vault. `id` is a unique slug; `name` defaults to it.
/// `path` is an optional absolute location for the vault's git repo — omit to let
/// the engine pick a default. (engine ≥ contract 0.15.0 — `POST /api/v1/vaults`.)
public struct CreateVaultRequest: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var path: String?
    public init(id: String, name: String? = nil, path: String? = nil) {
        self.id = id; self.name = name; self.path = path
    }
}

/// Result of deleting a vault (`DELETE /api/v1/vaults/{id}`). `path` is the vault's
/// former on-disk directory; when `filesDeleted` is false the engine left it in place
/// so the app can move it to the OS Trash. (engine ≥ contract 0.16.0.)
public struct DeleteVaultResult: Codable, Hashable, Sendable {
    public var id: String
    public var path: String?
    public var filesDeleted: Bool
    public init(id: String, path: String? = nil, filesDeleted: Bool = false) {
        self.id = id; self.path = path; self.filesDeleted = filesDeleted
    }
}

// MARK: - MCP agents (LLM access — contract 0.17.0)

/// One authorized MCP client (an LLM). `tokenRef` is the engine-side Secrets
/// reference (`file:`/`env:`/`keychain:`) — never the resolved secret; the app
/// reads a local `file:` ref itself to Copy the actual token. `prompt` is optional
/// convenience metadata (a system prompt to paste into the client); the engine does
/// not enforce it.
public struct Agent: Codable, Hashable, Sendable, Identifiable {
    public var agentId: String
    public var name: String
    public var role: String              // READ_ONLY | WRITE
    public var vaults: [String]
    public var tokenRef: String
    public var prompt: String?
    public var id: String { agentId }
    public init(agentId: String, name: String, role: String, vaults: [String], tokenRef: String, prompt: String? = nil) {
        self.agentId = agentId; self.name = name; self.role = role
        self.vaults = vaults; self.tokenRef = tokenRef; self.prompt = prompt
    }
    enum CodingKeys: String, CodingKey { case agentId, name, role, vaults, tokenRef, prompt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try c.decode(String.self, forKey: .agentId)
        name = (try? c.decode(String.self, forKey: .name)) ?? agentId
        role = (try? c.decode(String.self, forKey: .role)) ?? "READ_ONLY"
        vaults = (try? c.decode([String].self, forKey: .vaults)) ?? []
        tokenRef = (try? c.decode(String.self, forKey: .tokenRef)) ?? ""
        prompt = try? c.decodeIfPresent(String.self, forKey: .prompt)
    }
}

/// The `GET /api/v1/agents` envelope: the agents plus how an LLM reaches the MCP
/// endpoint (`mcpUrl` is shown for Copy; `mcpPort` for callers that build their own URL).
public struct AgentsInfo: Codable, Hashable, Sendable {
    public var agents: [Agent]
    public var mcpPort: Int?
    public var mcpUrl: String?
    public init(agents: [Agent], mcpPort: Int? = nil, mcpUrl: String? = nil) {
        self.agents = agents; self.mcpPort = mcpPort; self.mcpUrl = mcpUrl
    }
}

/// `tokenRef` must be a Secrets reference — a raw token is rejected by the engine (422).
public struct CreateAgentRequest: Codable, Hashable, Sendable {
    public var agentId: String
    public var name: String?
    public var role: String
    public var vaults: [String]
    public var tokenRef: String
    public var prompt: String?
    public init(agentId: String, name: String? = nil, role: String, vaults: [String], tokenRef: String, prompt: String? = nil) {
        self.agentId = agentId; self.name = name; self.role = role
        self.vaults = vaults; self.tokenRef = tokenRef; self.prompt = prompt
    }
}

/// Partial update — omitted fields are left unchanged engine-side.
public struct UpdateAgentRequest: Codable, Hashable, Sendable {
    public var name: String?
    public var role: String?
    public var vaults: [String]?
    public var tokenRef: String?
    public var prompt: String?
    public init(name: String? = nil, role: String? = nil, vaults: [String]? = nil, tokenRef: String? = nil, prompt: String? = nil) {
        self.name = name; self.role = role; self.vaults = vaults; self.tokenRef = tokenRef; self.prompt = prompt
    }
}

// MARK: - Engine self-update (contract 0.18.0)

/// Result of `GET /api/v1/update/check`. `updateAvailable` = a newer engine release exists;
/// `compatible` = it stays on the same App API major (safe to apply). `notes` carries the
/// release body (or a reason the check couldn't reach GitHub).
public struct UpdateCheck: Codable, Hashable, Sendable {
    public var currentVersion: String
    public var currentContract: String?
    public var latestVersion: String?
    public var updateAvailable: Bool
    public var compatible: Bool
    public var assetName: String?
    public var assetUrl: String?
    public var sha256: String?
    public var notes: String?
    public var publishedAt: String?
    public init(currentVersion: String, currentContract: String? = nil, latestVersion: String? = nil,
                updateAvailable: Bool = false, compatible: Bool = false, assetName: String? = nil,
                assetUrl: String? = nil, sha256: String? = nil, notes: String? = nil, publishedAt: String? = nil) {
        self.currentVersion = currentVersion; self.currentContract = currentContract
        self.latestVersion = latestVersion; self.updateAvailable = updateAvailable; self.compatible = compatible
        self.assetName = assetName; self.assetUrl = assetUrl; self.sha256 = sha256
        self.notes = notes; self.publishedAt = publishedAt
    }
    enum CodingKeys: String, CodingKey {
        case currentVersion, currentContract, latestVersion, updateAvailable, compatible, assetName, assetUrl, sha256, notes, publishedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentVersion = (try? c.decode(String.self, forKey: .currentVersion)) ?? "?"
        currentContract = try? c.decodeIfPresent(String.self, forKey: .currentContract)
        latestVersion = try? c.decodeIfPresent(String.self, forKey: .latestVersion)
        updateAvailable = (try? c.decode(Bool.self, forKey: .updateAvailable)) ?? false
        compatible = (try? c.decode(Bool.self, forKey: .compatible)) ?? false
        assetName = try? c.decodeIfPresent(String.self, forKey: .assetName)
        assetUrl = try? c.decodeIfPresent(String.self, forKey: .assetUrl)
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
        notes = try? c.decodeIfPresent(String.self, forKey: .notes)
        publishedAt = try? c.decodeIfPresent(String.self, forKey: .publishedAt)
    }
}

/// Result of `POST /api/v1/update/apply` — the engine spawned the detached self-update script.
public struct UpdateApply: Codable, Hashable, Sendable {
    public var started: Bool
    public var candidateVersion: String?
    public init(started: Bool, candidateVersion: String? = nil) {
        self.started = started; self.candidateVersion = candidateVersion
    }
}

/// Import an Obsidian vault directory (local path) into a Svod vault.
public struct ImportRequest: Codable, Hashable, Sendable {
    public var source: String            // local filesystem path to the Obsidian vault
    public var into: String?             // optional subfolder prefix within the target vault
    public var vault: String?            // target vault id; nil ⇒ default
    public var followSymlinks: Bool      // contract 0.7.0: materialize symlinks (else skipped)
    public init(source: String, into: String? = nil, vault: String? = nil, followSymlinks: Bool = false) {
        self.source = source; self.into = into; self.vault = vault; self.followSymlinks = followSymlinks
    }
}

/// imported = newly written, unchanged = already identical (idempotent re-run),
/// skipped = present-but-differing (left as-is) or blocked by secret scanning.
public struct ImportResult: Codable, Hashable, Sendable {
    public var imported: [String]
    public var unchanged: [String]
    public var skipped: [String]
    public init(imported: [String], unchanged: [String], skipped: [String]) {
        self.imported = imported; self.unchanged = unchanged; self.skipped = skipped
    }
    public var total: Int { imported.count + unchanged.count + skipped.count }
}

// MARK: - External sources (engine v0.6.0 — re-syncable external files/dirs)

/// A registered external source: a file/dir outside the vault that can be re-synced
/// in (external-wins-unless-locally-edited). `id` is derived from `path`.
public struct ExternalSource: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var path: String
    public var into: String
    public var followSymlinks: Bool
    public var prune: Bool
    public var lastSyncedAt: String?     // ISO-8601, nil if never synced
    // Auto-sync on filesystem change (contract 0.13.0). `watching` is read-only:
    // whether a watcher is live right now.
    public var autoSync: Bool
    public var watching: Bool
    /// Two-way write-back of vault edits to the external files (0.20.0).
    public var writeBack: Bool
    /// Vault paths whose local edits blocked the external update at the last sync (0.19.0).
    public var conflicts: [String]
    public init(id: String, path: String, into: String, followSymlinks: Bool, prune: Bool,
                lastSyncedAt: String? = nil, autoSync: Bool = false, watching: Bool = false,
                writeBack: Bool = false, conflicts: [String] = []) {
        self.id = id; self.path = path; self.into = into
        self.followSymlinks = followSymlinks; self.prune = prune; self.lastSyncedAt = lastSyncedAt
        self.autoSync = autoSync; self.watching = watching
        self.writeBack = writeBack; self.conflicts = conflicts
    }
    // Tolerant decode so a pre-0.13.0 engine (no autoSync/watching) still works.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        into = try c.decodeIfPresent(String.self, forKey: .into) ?? ""
        followSymlinks = try c.decodeIfPresent(Bool.self, forKey: .followSymlinks) ?? false
        prune = try c.decodeIfPresent(Bool.self, forKey: .prune) ?? false
        lastSyncedAt = try c.decodeIfPresent(String.self, forKey: .lastSyncedAt)
        autoSync = try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? false
        watching = try c.decodeIfPresent(Bool.self, forKey: .watching) ?? false
        writeBack = try c.decodeIfPresent(Bool.self, forKey: .writeBack) ?? false
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
    }
    /// Display name = last path component.
    public var name: String { (path as NSString).lastPathComponent }
}

public struct RegisterSourceRequest: Codable, Hashable, Sendable {
    public var path: String                 // absolute path to a file/dir outside the vault
    public var into: String?                // vault subpath prefix
    public var followSymlinks: Bool
    public var prune: Bool                   // propagate deletions (off by default)
    public var autoSync: Bool                // watch the source and sync on change (0.13.0)
    public var writeBack: Bool               // two-way: vault edits flow back to the files (0.20.0)
    public init(path: String, into: String? = nil, followSymlinks: Bool = false,
                prune: Bool = false, autoSync: Bool = false, writeBack: Bool = false) {
        self.path = path; self.into = into; self.followSymlinks = followSymlinks
        self.prune = prune; self.autoSync = autoSync; self.writeBack = writeBack
    }
}

/// Partial update of a registered source (contract 0.13.0). Only provided fields
/// change; toggling `autoSync` starts/stops the filesystem watcher immediately.
public struct SourceUpdateRequest: Codable, Hashable, Sendable {
    public var autoSync: Bool?
    public var followSymlinks: Bool?
    public var prune: Bool?
    public var writeBack: Bool?
    public init(autoSync: Bool? = nil, followSymlinks: Bool? = nil, prune: Bool? = nil,
                writeBack: Bool? = nil) {
        self.autoSync = autoSync; self.followSymlinks = followSymlinks; self.prune = prune
        self.writeBack = writeBack
    }
}

/// Per-source sync outcome. Arrays may be omitted on the wire → default to empty.
public struct SourceSyncResult: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var created: [String]
    public var updated: [String]
    public var unchanged: [String]
    public var conflicts: [String]          // vault copy locally edited → left as-is
    public var orphaned: [String]           // gone from source → left in vault
    public var deleted: [String]            // gone from source AND pruned (soft-deleted)
    public var skipped: [String]            // secret-scanner blocked
    public var pushed: [String]             // vault edits written back to the external files (0.20.0)
    public var error: String?               // source path unreadable (sync was a no-op)

    public init(id: String, created: [String] = [], updated: [String] = [], unchanged: [String] = [],
                conflicts: [String] = [], orphaned: [String] = [], deleted: [String] = [],
                skipped: [String] = [], pushed: [String] = [], error: String? = nil) {
        self.id = id; self.created = created; self.updated = updated; self.unchanged = unchanged
        self.conflicts = conflicts; self.orphaned = orphaned; self.deleted = deleted
        self.skipped = skipped; self.pushed = pushed; self.error = error
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        created = try c.decodeIfPresent([String].self, forKey: .created) ?? []
        updated = try c.decodeIfPresent([String].self, forKey: .updated) ?? []
        unchanged = try c.decodeIfPresent([String].self, forKey: .unchanged) ?? []
        conflicts = try c.decodeIfPresent([String].self, forKey: .conflicts) ?? []
        orphaned = try c.decodeIfPresent([String].self, forKey: .orphaned) ?? []
        deleted = try c.decodeIfPresent([String].self, forKey: .deleted) ?? []
        skipped = try c.decodeIfPresent([String].self, forKey: .skipped) ?? []
        pushed = try c.decodeIfPresent([String].self, forKey: .pushed) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
    /// New + updated — the "pulled in" count for a concise summary.
    public var changed: Int { created.count + updated.count }
}

// MARK: - Memory / recall (engine ≥ contract 0.22.0)
//
// The "recall" subsystem: a Stop-hook captures raw sessions into messy/sessions/
// (kept OUT of search/recall, like <private>); a nightly agent distills them into
// durable notes and appends skill/tool proposals to an inbox. These DTOs surface
// the engine's data plane — counts, the captured-session list, and the proposals
// inbox the operator reviews. Wire enum casing (kind/scope/status) is normalized
// to lowercase on decode so the UI is robust to the engine's house style.

/// Aggregate stats for the Memory panel. `compressionRatio` = capturedBytes / distilledBytes.
public struct MemoryDashboard: Codable, Hashable, Sendable {
    public var sessionsCaptured: Int
    public var sessionsDistilled: Int
    public var notesWritten: Int
    public var capturedBytes: Int
    public var distilledBytes: Int
    public var compressionRatio: Double
    public var lastDistillAt: Int?        // ms epoch; nil ⇒ never distilled
    public var openProposals: Int
    public init(sessionsCaptured: Int = 0, sessionsDistilled: Int = 0, notesWritten: Int = 0,
                capturedBytes: Int = 0, distilledBytes: Int = 0, compressionRatio: Double = 0,
                lastDistillAt: Int? = nil, openProposals: Int = 0) {
        self.sessionsCaptured = sessionsCaptured; self.sessionsDistilled = sessionsDistilled
        self.notesWritten = notesWritten; self.capturedBytes = capturedBytes
        self.distilledBytes = distilledBytes; self.compressionRatio = compressionRatio
        self.lastDistillAt = lastDistillAt; self.openProposals = openProposals
    }
    enum CodingKeys: String, CodingKey {
        case sessionsCaptured, sessionsDistilled, notesWritten, capturedBytes,
             distilledBytes, compressionRatio, lastDistillAt, openProposals
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionsCaptured = (try? c.decode(Int.self, forKey: .sessionsCaptured)) ?? 0
        sessionsDistilled = (try? c.decode(Int.self, forKey: .sessionsDistilled)) ?? 0
        notesWritten = (try? c.decode(Int.self, forKey: .notesWritten)) ?? 0
        capturedBytes = (try? c.decode(Int.self, forKey: .capturedBytes)) ?? 0
        distilledBytes = (try? c.decode(Int.self, forKey: .distilledBytes)) ?? 0
        compressionRatio = (try? c.decode(Double.self, forKey: .compressionRatio)) ?? 0
        lastDistillAt = try? c.decodeIfPresent(Int.self, forKey: .lastDistillAt)
        openProposals = (try? c.decode(Int.self, forKey: .openProposals)) ?? 0
    }
    /// True once at least one session has been captured — used to pick the empty state.
    public var hasActivity: Bool { sessionsCaptured > 0 }
}

/// A captured (raw) session note in messy/sessions/. `distilled` flips once the
/// nightly job has compressed it into durable knowledge.
public struct MemorySession: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var project: String?
    public var sessionId: String
    public var startedAt: Int              // ms epoch
    public var endedAt: Int                // ms epoch
    public var bytes: Int
    public var distilled: Bool
    public var id: String { path }
    public init(path: String, project: String? = nil, sessionId: String,
                startedAt: Int, endedAt: Int, bytes: Int, distilled: Bool) {
        self.path = path; self.project = project; self.sessionId = sessionId
        self.startedAt = startedAt; self.endedAt = endedAt; self.bytes = bytes; self.distilled = distilled
    }
    enum CodingKeys: String, CodingKey {
        case path, project, sessionId, startedAt, endedAt, bytes, distilled
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        project = try? c.decodeIfPresent(String.self, forKey: .project)
        sessionId = (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        startedAt = (try? c.decode(Int.self, forKey: .startedAt)) ?? 0
        endedAt = (try? c.decode(Int.self, forKey: .endedAt)) ?? 0
        bytes = (try? c.decode(Int.self, forKey: .bytes)) ?? 0
        distilled = (try? c.decode(Bool.self, forKey: .distilled)) ?? false
    }
}

/// A skill/tool proposal the distiller surfaced from a recurring cross-session pattern.
/// Nothing is created automatically (suggestions-over-automation) — the operator
/// accepts/rejects here, and `accept` only flags it for follow-up (e.g. the Foundry).
public struct MemoryProposal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String                // "skill" | "tool" (normalized lowercase)
    public var title: String
    public var scope: String               // "project" | "global" (normalized lowercase)
    public var confidence: Double
    public var rationale: String
    public var sourceSessions: [String]
    public var createdAt: Int              // ms epoch
    public var status: String              // "open" | "accepted" | "rejected" (normalized lowercase)
    public init(id: String, kind: String, title: String, scope: String, confidence: Double,
                rationale: String, sourceSessions: [String], createdAt: Int, status: String) {
        self.id = id; self.kind = kind.lowercased(); self.title = title
        self.scope = scope.lowercased(); self.confidence = confidence; self.rationale = rationale
        self.sourceSessions = sourceSessions; self.createdAt = createdAt; self.status = status.lowercased()
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, title, scope, confidence, rationale, sourceSessions, createdAt, status
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = ((try? c.decode(String.self, forKey: .kind)) ?? "skill").lowercased()
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled proposal"
        scope = ((try? c.decode(String.self, forKey: .scope)) ?? "project").lowercased()
        confidence = (try? c.decode(Double.self, forKey: .confidence)) ?? 0
        rationale = (try? c.decode(String.self, forKey: .rationale)) ?? ""
        sourceSessions = (try? c.decode([String].self, forKey: .sourceSessions)) ?? []
        createdAt = (try? c.decode(Int.self, forKey: .createdAt)) ?? 0
        status = ((try? c.decode(String.self, forKey: .status)) ?? "open").lowercased()
    }
    public var isOpen: Bool { status == "open" }
}

/// Body of `POST /api/v1/memory/proposals/{id}` — accept or reject a proposal.
public struct MemoryProposalAction: Codable, Hashable, Sendable {
    public var action: String              // "accept" | "reject"
    public var note: String?
    public init(action: String, note: String? = nil) { self.action = action; self.note = note }
}

// MARK: - People: App API principals (contract 0.30.0, ADR-0019)

/// One per-vault grant. `role` is `reader` | `editor`.
public struct VaultGrant: Codable, Hashable, Sendable, Identifiable {
    public var vault: String
    public var role: String
    public var id: String { vault }
    public init(vault: String, role: String) { self.vault = vault; self.role = role }
}

/// `GET /api/v1/me` — who the engine thinks we are. Doubles as the connection test for a central engine.
public struct Me: Codable, Hashable, Sendable {
    public var userId: String
    public var name: String
    public var admin: Bool
    /// The loopback UI identity (no key presented).
    public var local: Bool
    public var grants: [VaultGrant]
    /// When this key last authenticated (ISO-8601 UTC); nil on a 0.30 engine, for the local identity, or never.
    public var lastUsedAt: String?
    public init(userId: String, name: String, admin: Bool, local: Bool, grants: [VaultGrant] = [], lastUsedAt: String? = nil) {
        self.userId = userId; self.name = name; self.admin = admin; self.local = local; self.grants = grants; self.lastUsedAt = lastUsedAt
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? userId
        admin = try c.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        local = try c.decodeIfPresent(Bool.self, forKey: .local) ?? false
        grants = try c.decodeIfPresent([VaultGrant].self, forKey: .grants) ?? []
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt)
    }
}

/// One person with App API access. `keyRef` is the Secrets ref — never the key.
public struct UserInfo: Codable, Hashable, Sendable, Identifiable {
    public var userId: String
    public var name: String
    public var email: String?
    public var admin: Bool
    public var grants: [VaultGrant]
    public var keyRef: String
    /// When this key last authenticated (ISO-8601 UTC); nil on a 0.30 engine or if never used.
    public var lastUsedAt: String?
    /// `lastUsedAt` as a Date (the engine writes fractional seconds; both forms parse).
    public var lastUsedDate: Date? { lastUsedAt.flatMap(ISO8601.parse) }
    public var id: String { userId }
    public init(userId: String, name: String, email: String? = nil, admin: Bool = false, grants: [VaultGrant] = [], keyRef: String = "", lastUsedAt: String? = nil) {
        self.userId = userId; self.name = name; self.email = email; self.admin = admin; self.grants = grants; self.keyRef = keyRef; self.lastUsedAt = lastUsedAt
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        userId = try c.decode(String.self, forKey: .userId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? userId
        email = try c.decodeIfPresent(String.self, forKey: .email)
        admin = try c.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        grants = try c.decodeIfPresent([VaultGrant].self, forKey: .grants) ?? []
        keyRef = try c.decodeIfPresent(String.self, forKey: .keyRef) ?? ""
        lastUsedAt = try c.decodeIfPresent(String.self, forKey: .lastUsedAt)
    }
}

public struct UsersInfo: Codable, Hashable, Sendable {
    public var users: [UserInfo]
    public init(users: [UserInfo]) { self.users = users }
}

public struct CreateUserRequest: Codable, Hashable, Sendable {
    public var userId: String
    public var name: String
    public var email: String?
    public var admin: Bool
    public var grants: [VaultGrant]
    public init(userId: String, name: String, email: String? = nil, admin: Bool = false, grants: [VaultGrant] = []) {
        self.userId = userId; self.name = name; self.email = email; self.admin = admin; self.grants = grants
    }
}

/// Omitted (nil) fields are left unchanged by the engine.
public struct UpdateUserRequest: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String?
    public var admin: Bool?
    public var grants: [VaultGrant]?
    public init(name: String? = nil, email: String? = nil, admin: Bool? = nil, grants: [VaultGrant]? = nil) {
        self.name = name; self.email = email; self.admin = admin; self.grants = grants
    }
}

/// The only response that ever carries a raw key — show it once, then forget it.
public struct CreatedUser: Codable, Hashable, Sendable {
    public var user: UserInfo
    public var key: String
    public init(user: UserInfo, key: String) { self.user = user; self.key = key }
}

public struct RotatedKey: Codable, Hashable, Sendable {
    public var userId: String
    public var key: String
    public init(userId: String, key: String) { self.userId = userId; self.key = key }
}

public struct CreateSecretRequest: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

/// A `file:` Secrets ref on the engine host, usable wherever a ref is accepted (backup remote, API keys).
public struct SecretRef: Codable, Hashable, Sendable {
    public var ref: String
    public init(ref: String) { self.ref = ref }
}


/// ISO-8601 wire timestamps → Date, with and without fractional seconds.
public enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let plain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    public static func parse(_ s: String) -> Date? { withFraction.date(from: s) ?? plain.date(from: s) }
}
