import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Sidebar (Features/Sidebar/)
// File tree + tag taxonomy + saved searches.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class SidebarModel: ObservableObject {
    public struct SavedSearch: Identifiable, Hashable, Sendable {
        public var id = UUID()
        public var name: String
        public var query: String
        public init(name: String, query: String) { self.name = name; self.query = query }
    }

    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var tree: TreeNode?
    @Published public var tags: [Tags.Tag] = []
    @Published public var savedSearches: [SavedSearch] = []
    @Published public var expanded: Set<String> = []
    /// The single hovered row path. Shared (not per-row @State) so hover is mutually
    /// exclusive — entering one row clears any other, even when AppKit drops a row's
    /// onHover(false) exit event during rapid clicks (which left several rows stuck
    /// highlighted at once).
    @Published public var hoveredPath: String?
    @Published public var isLoading = false
    @Published public var errorMessage: String?

    public init(client: SvodClient) { self.client = client }

    private var refreshTask: Task<Void, Never>?

    /// Called from the view on relevant WS events. Debounces 500 ms so a burst of
    /// agent writes (many commit.created events) collapses into a single tree reload.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            await self.load()
        }
    }

    public func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            async let tree = client.tree()
            async let tags = client.tags()
            self.tree = try await tree
            self.tags = try await tags.tags
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    public func toggle(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
    }
}
