import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Sidebar (Features/Sidebar/)
// File tree + tag taxonomy + saved searches + pinned notes.
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
    /// Notes the user pinned, in pin order. Per vault, persisted; personal like a
    /// saved search, not vault content. See `pinnedNotes` for what is shown.
    @Published public private(set) var pinned: [String] = []
    /// The single hovered row path. Shared (not per-row @State) so hover is mutually
    /// exclusive — entering one row clears any other, even when AppKit drops a row's
    /// onHover(false) exit event during rapid clicks (which left several rows stuck
    /// highlighted at once).
    @Published public var hoveredPath: String?
    @Published public var isLoading = false
    @Published public var errorMessage: String?

    private let defaults: UserDefaults

    public init(client: SvodClient, defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
    }

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
        loadPins()
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

    /// Set by `reveal(_:)`; the Notes tab scrolls this path into view, then clears it.
    @Published public var revealTarget: String?

    /// Expand every ancestor folder of `path` and ask the tree to scroll it into view.
    public func reveal(_ path: String) {
        var prefix = ""
        for comp in path.split(separator: "/").dropLast() {
            prefix = prefix.isEmpty ? String(comp) : prefix + "/" + comp
            expanded.insert(prefix)
        }
        revealTarget = path
    }

    // MARK: - Pinned notes

    private var pinsKey: String {
        "svod.sidebar.pinned.\(app?.vault.activeVaultId ?? "default")"
    }

    /// Re-read the active vault's pins. `load()` calls this, and `load()` already runs
    /// on every vault switch (reloadEpoch), so pins follow the vault.
    public func loadPins() {
        pinned = defaults.stringArray(forKey: pinsKey) ?? []
    }

    public func isPinned(_ path: String) -> Bool { pinned.contains(path) }

    public func togglePin(_ path: String) {
        if let i = pinned.firstIndex(of: path) { pinned.remove(at: i) } else { pinned.append(path) }
        defaults.set(pinned, forKey: pinsKey)
    }

    /// Pins whose note exists in the current tree, in pin order. A pin for a note that
    /// is gone (trashed, moved) is hidden rather than dropped, so it comes back if the
    /// note does. Empty until the tree has loaded.
    public var pinnedNotes: [String] {
        guard !pinned.isEmpty, let tree else { return [] }
        var files = Set<String>()
        func walk(_ n: TreeNode) {
            if n.type == .file { files.insert(n.path) } else { (n.children ?? []).forEach(walk) }
        }
        walk(tree)
        return pinned.filter { files.contains($0) }
    }
}
