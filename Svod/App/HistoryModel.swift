import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Drives the per-file timeline, side-by-side diff, restore, and the 3-way merge
// UI presented via `app.activeConflict` (set on a write 409).
// Also owns ConflictsListModel — the GET /conflicts surface introduced in v0.3.0.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class HistoryModel: ObservableObject {
    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var path: String?
    @Published public var commits: [CommitInfo] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var selectedCommit: String?
    @Published public var diff: DiffResult?
    @Published public var isLoadingDiff = false

    // Teammate-4 additions (UI state; foundation API above is untouched).
    /// Structured form of `diff` the diff views render. Nil until a commit is selected.
    @Published var parsedDiff: ParsedDiff?
    /// True when the diff shown is a first-commit fallback (full content, all-added).
    @Published var diffIsFirstCommit = false
    /// Drives the restore confirmation alert.
    @Published var pendingRestore: CommitInfo?
    @Published var isRestoring = false

    public init(client: SvodClient) { self.client = client }

    public func load(path: String) async {
        self.path = path
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            self.commits = try await client.history(path: path, max: 100)
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription; self.commits = []
        } catch {
            self.errorMessage = error.localizedDescription; self.commits = []
        }
    }

    public func loadDiff(path: String, from: String, to: String) async {
        isLoadingDiff = true
        diffIsFirstCommit = false
        defer { isLoadingDiff = false }
        do {
            let result = try await client.diff(path: path, from: from, to: to)
            self.diff = result
            self.parsedDiff = ParsedDiff.parse(result.diff)
        } catch SvodClientError.badRequest {
            // First commit has no parent (`<commit>~1` 400s) — render the revision
            // itself as an all-added diff so the surface still shows what landed.
            await loadFirstCommitDiff(path: path, commit: to)
        } catch {
            self.diff = nil
            self.parsedDiff = nil
        }
    }

    private func loadFirstCommitDiff(path: String, commit: String) async {
        guard let rev = try? await client.revision(path: path, revision: commit) else {
            self.diff = nil; self.parsedDiff = nil; return
        }
        self.diff = DiffResult(path: path, from: commit, to: commit, diff: rev.content)
        self.parsedDiff = ParsedDiff.allAdded(rev.content)
        self.diffIsFirstCommit = true
    }

    /// Select a commit and load its own change (`<commit>~1` → `<commit>`).
    func select(commit: CommitInfo) async {
        guard let path else { return }
        selectedCommit = commit.commit
        await loadDiff(path: path, from: "\(commit.commit)~1", to: commit.commit)
    }

    public func restore(path: String, to revision: String) async {
        // Restore = write the older revision's content back as a new commit. We pass
        // the editor's current revision as the optimistic-concurrency token so a
        // stale restore surfaces the same 3-way merge as a normal write (never a
        // silent overwrite).
        isRestoring = true
        defer { isRestoring = false }
        guard let old = try? await client.revision(path: path, revision: revision) else { return }
        do {
            _ = try await client.writeFile(path: path, content: old.content,
                                           expectedRevision: app?.editor.currentRevision)
        } catch let SvodClientError.conflict(body) {
            app?.presentConflict(body)
            return
        } catch {
            errorMessage = (error as? SvodClientError)?.errorDescription ?? error.localizedDescription
            return
        }
        await load(path: path)
    }

    /// Confirm-then-restore entry the timeline UI calls.
    func confirmRestore(_ commit: CommitInfo) async {
        guard let path else { return }
        await restore(path: path, to: commit.commit)
        pendingRestore = nil
    }
}

// ════════════════════════════════════════════════════════════════════════
// ConflictsListModel — drives the GET /conflicts surface (v0.3.0+).
// Lives in HistoryModel.swift (same owner) and is exposed on AppModel
// as `app.conflictsList` by Teammate-1.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class ConflictsListModel: ObservableObject {
    public let client: SvodClient

    @Published public var items: [Conflicts.Item] = []
    @Published public var isLoading = false
    @Published public var errorMessage: String?

    /// The item currently open in the 3-way merge sheet.
    @Published var activeItem: Conflicts.Item?

    public init(client: SvodClient) { self.client = client }

    public func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.conflicts()
            self.items = result.conflicts
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Called by ConflictMergeModel (item-path) after a successful resolve.
    /// Removes the resolved item and refreshes from the engine.
    func onResolved(path: String) async {
        items.removeAll { $0.path == path }
        await load()
    }

    /// Resolve a conflict with merged content. Returns true on success.
    /// On 409 (changed again): updates the active item with new content and
    /// returns false so the merge view stays open with a re-fetch message.
    func resolve(path: String, content: String, expectedRevision: String?) async -> Bool {
        do {
            _ = try await client.resolveConflict(path: path, content: content,
                                                 expectedRevision: expectedRevision)
            await onResolved(path: path)
            return true
        } catch let SvodClientError.conflict(body) {
            // The file changed again while the user was merging.
            // Re-fetch the full conflicts list so activeItem gets fresh content.
            await load()
            // Update activeItem in-place if still present, or synthesize from body.
            if var updated = items.first(where: { $0.path == path }) {
                // ours = what we tried to write, theirs = what won
                updated.ours = content
                updated.theirs = body.currentContent
                activeItem = updated
            }
            errorMessage = "Changed again while you were merging — review the updated versions and resolve once more."
            return false
        } catch let e as SvodClientError {
            errorMessage = e.errorDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
