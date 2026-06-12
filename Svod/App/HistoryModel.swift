import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 4 — History, Diff & Conflict (Features/History/)
// Drives the per-file timeline, side-by-side diff, restore, and the 3-way merge
// UI presented via `app.activeConflict` (set on a write 409).
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
        defer { isLoadingDiff = false }
        self.diff = try? await client.diff(path: path, from: from, to: to)
    }

    public func restore(path: String, to revision: String) async {
        // Restore = write the older revision's content back as a new commit.
        guard let old = try? await client.revision(path: path, revision: revision) else { return }
        _ = try? await client.writeFile(path: path, content: old.content,
                                        expectedRevision: app?.editor.currentRevision)
        await load(path: path)
    }
}
