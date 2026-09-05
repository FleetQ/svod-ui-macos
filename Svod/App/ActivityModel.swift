import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Agent Activity (Features/Activity/)
// Live, WebSocket-driven feed. EngineModel forwards each event via `ingest`.
//
// Also the review inbox: every agent commit is kept in `pending` until the
// user marks it reviewed or reverts it. Unlike the feed, `pending` survives a
// relaunch — the question it answers is "what did agents change while I was
// away", and the feed only exists while the app is running.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class ActivityModel: ObservableObject {
    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var feed: [SvodEvent] = []

    /// Agent commits nobody has looked at yet, newest first. Persisted.
    @Published public private(set) var pending: [SvodEvent] = []

    public enum RevertOutcome: Equatable {
        case reverted, trashed, changedSince, conflict
        case failed(String)
    }

    private var shownCommits = Set<String>()
    private var pendingCommits = Set<String>()
    private let cap = 200
    private let defaults: UserDefaults
    private static let pendingKey = "svod.activity.pending"

    public init(client: SvodClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pendingKey),
           let saved = try? JSONDecoder().decode([SvodEvent].self, from: data) {
            pending = saved
            pendingCommits = Set(saved.compactMap(\.data.commit))
        }
    }

    /// Append a live event, de-duping by commit id (an MCP write surfaces as both
    /// agent.activity and commit.created for the same commit — show it once).
    public func ingest(_ event: SvodEvent) {
        trackPending(event)
        switch event.type {
        case .agentActivity, .commitCreated, .conflict, .fileChanged:
            // Honor the feed type filters from settings (conflicts always shown).
            if let s = app?.settings, event.type != .conflict, !s.showsEvent(event.type) { return }
            if let commit = event.data.commit {
                if shownCommits.contains(commit) { return }
                shownCommits.insert(commit)
            }
            let limit = app?.settings.feedCap ?? cap
            let animate = app?.settings.feedAnimation ?? true
            withAnimation(animate ? Motion.arrive : nil) {
                feed.insert(event, at: 0)
                if feed.count > limit { feed.removeLast(feed.count - limit) }
            }
        case .indexUpdated, .indexProgress, .sourceSynced, .engineStatus, .unknown:
            break
        }
    }

    /// Events for a specific note (used by the Inspector's per-note activity).
    public func events(for path: String) -> [SvodEvent] {
        feed.filter { $0.data.path == path }
    }

    public func clear() { feed.removeAll(); shownCommits.removeAll() }

    // MARK: - Review inbox

    /// An agent commit. The engine tags MCP writes with `agentId` on both events it
    /// emits; App-API writes carry only `author`, watcher commits `author: "external"`
    /// and no path. So `agentId` is the whole criterion — the user's own edits never
    /// land in their own review list.
    public static func isReviewable(_ event: SvodEvent) -> Bool {
        guard event.type == .agentActivity || event.type == .commitCreated else { return false }
        guard let agent = event.data.agentId, !agent.isEmpty else { return false }
        return event.data.commit != nil && event.data.path != nil
    }

    /// Revert restores the pre-commit content of ONE path, so only single-path content
    /// writes qualify. `delete` already left the note in `.trash/`; `move` and `promote`
    /// touch two paths (the event carries the destination, whose parent copy is absent —
    /// reverting would trash the moved note); `remember` may write two files in one commit.
    public static func canRevert(_ event: SvodEvent) -> Bool {
        guard isReviewable(event) else { return false }
        return [nil, "write", "edit"].contains(event.data.tool)
    }

    /// Independent of the feed's type filters: hiding agent.activity from the feed must
    /// not also hide the commit from review.
    private func trackPending(_ event: SvodEvent) {
        guard Self.isReviewable(event), let commit = event.data.commit else { return }
        guard !pendingCommits.contains(commit) else { return }
        pendingCommits.insert(commit)
        pending.insert(event, at: 0)
        if pending.count > cap {
            for dropped in pending[cap...] { if let c = dropped.data.commit { pendingCommits.remove(c) } }
            pending.removeLast(pending.count - cap)
        }
        persistPending()
    }

    public func markReviewed(_ event: SvodEvent) {
        guard let commit = event.data.commit else { return }
        pendingCommits.remove(commit)
        pending.removeAll { $0.data.commit == commit }
        persistPending()
    }

    public func markAllReviewed() {
        pendingCommits.removeAll()
        pending.removeAll()
        persistPending()
    }

    private func persistPending() {
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: Self.pendingKey)
        }
    }

    /// Write the content from before this commit back as a new commit (nothing is
    /// lost — the agent's version stays in history). Refuses when the file has moved on
    /// since: reverting blindly would drop the later edits as well.
    public func revert(_ event: SvodEvent) async -> RevertOutcome {
        guard Self.canRevert(event), let path = event.data.path, let commit = event.data.commit else {
            return .failed("This change can't be reverted from here.")
        }
        // Every call below resolves the vault at call time, and a vault switch can land on
        // any suspension point. Re-check after each await so a switch mid-revert aborts
        // before anything is written, instead of writing vault A's content into vault B.
        let vault = app?.vault.activeVaultId
        func sameVault() -> Bool { app?.vault.activeVaultId == vault }
        let switched = RevertOutcome.failed("The active vault changed during the revert. Nothing was written.")
        do {
            // MCP events carry no vault tag and this runs against the active vault; a path
            // from another vault either 404s here or has a different head, so this check
            // also fails closed on a wrong-vault item.
            let head = try await client.history(path: path, max: 1).first?.commit
            guard head == commit else { return .changedSince }
            guard sameVault() else { return switched }

            let parent: FileContent?
            do {
                parent = try await client.revision(path: path, revision: "\(commit)~1")
            } catch SvodClientError.badRequest, SvodClientError.notFound {
                parent = nil
            }
            guard sameVault() else { return switched }

            let current = try await client.readFile(path: path)
            guard sameVault() else { return switched }
            if let parent {
                _ = try await client.writeFile(path: path, content: parent.content,
                                               expectedRevision: current.revision)
                markReviewed(event)
                return .reverted
            }
            // No parent copy: the agent created this note. Soft-delete it (restorable).
            _ = try await client.deleteFile(path: path, expectedRevision: current.revision)
            markReviewed(event)
            app?.refreshActiveVault()
            return .trashed
        } catch let SvodClientError.conflict(body) {
            app?.presentConflict(body)
            return .conflict
        } catch let e as SvodClientError {
            return .failed(e.errorDescription ?? "Couldn't revert.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
