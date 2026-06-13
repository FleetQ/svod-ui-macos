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
    // id must stay unique across vaults in federated results.
    public var id: String { (vault.map { $0 + ":" } ?? "") + path + "#" + heading }
    public init(path: String, heading: String, snippet: String, score: Double,
                matchedKeyword: Bool, matchedSemantic: Bool, tags: [String], vault: String? = nil) {
        self.path = path; self.heading = heading; self.snippet = snippet; self.score = score
        self.matchedKeyword = matchedKeyword; self.matchedSemantic = matchedSemantic
        self.tags = tags; self.vault = vault
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
}

public struct IndexStatus: Codable, Hashable, Sendable {
    public var docCount: Int
    public var headIndexed: String?
    public var model: String
    public var dim: Int
    public init(docCount: Int, headIndexed: String? = nil, model: String, dim: Int) {
        self.docCount = docCount; self.headIndexed = headIndexed; self.model = model; self.dim = dim
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
    public var syncPeers: [String]
    public var role: String?
    public var hostId: String?
    public init(backupRemote: String? = nil, backupEnabled: Bool = false,
                syncPeers: [String] = [], role: String? = nil, hostId: String? = nil) {
        self.backupRemote = backupRemote; self.backupEnabled = backupEnabled
        self.syncPeers = syncPeers; self.role = role; self.hostId = hostId
    }
}

public struct BackupConfigRequest: Codable, Hashable, Sendable {
    public var remote: String          // a git remote URL; secrets only as Secrets refs
    public var enabled: Bool
    public init(remote: String, enabled: Bool) { self.remote = remote; self.enabled = enabled }
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
    public var role: String              // e.g. "authority" | "follower" | "solo"
    public var lastHead: String?
    public var conflicts: Int
    public init(role: String, lastHead: String? = nil, conflicts: Int = 0) {
        self.role = role; self.lastHead = lastHead; self.conflicts = conflicts
    }
}

public struct Vaults: Codable, Hashable, Sendable {
    public struct Vault: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// `default` on the wire — the vault used when `?vault=` is omitted.
        public var isDefault: Bool
        public var sync: SyncStatus?
        public init(id: String, name: String, isDefault: Bool, sync: SyncStatus? = nil) {
            self.id = id; self.name = name; self.isDefault = isDefault; self.sync = sync
        }
        enum CodingKeys: String, CodingKey {
            case id, name, sync
            case isDefault = "default"   // `default` is a Swift keyword
        }
    }
    public var vaults: [Vault]
    public init(vaults: [Vault]) { self.vaults = vaults }
    public var defaultVault: Vault? { vaults.first(where: \.isDefault) ?? vaults.first }
}

public typealias Vault = Vaults.Vault

/// Import an Obsidian vault directory (local path) into a Svod vault.
public struct ImportRequest: Codable, Hashable, Sendable {
    public var source: String            // local filesystem path to the Obsidian vault
    public var into: String?             // optional subfolder prefix within the target vault
    public var vault: String?            // target vault id; nil ⇒ default
    public init(source: String, into: String? = nil, vault: String? = nil) {
        self.source = source; self.into = into; self.vault = vault
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
    public init(id: String, path: String, into: String, followSymlinks: Bool, prune: Bool, lastSyncedAt: String? = nil) {
        self.id = id; self.path = path; self.into = into
        self.followSymlinks = followSymlinks; self.prune = prune; self.lastSyncedAt = lastSyncedAt
    }
    /// Display name = last path component.
    public var name: String { (path as NSString).lastPathComponent }
}

public struct RegisterSourceRequest: Codable, Hashable, Sendable {
    public var path: String                 // absolute path to a file/dir outside the vault
    public var into: String?                // vault subpath prefix
    public var followSymlinks: Bool
    public var prune: Bool                   // propagate deletions (off by default)
    public init(path: String, into: String? = nil, followSymlinks: Bool = false, prune: Bool = false) {
        self.path = path; self.into = into; self.followSymlinks = followSymlinks; self.prune = prune
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
    public var error: String?               // source path unreadable (sync was a no-op)

    public init(id: String, created: [String] = [], updated: [String] = [], unchanged: [String] = [],
                conflicts: [String] = [], orphaned: [String] = [], deleted: [String] = [],
                skipped: [String] = [], error: String? = nil) {
        self.id = id; self.created = created; self.updated = updated; self.unchanged = unchanged
        self.conflicts = conflicts; self.orphaned = orphaned; self.deleted = deleted
        self.skipped = skipped; self.error = error
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
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
    /// New + updated — the "pulled in" count for a concise summary.
    public var changed: Int { created.count + updated.count }
}
