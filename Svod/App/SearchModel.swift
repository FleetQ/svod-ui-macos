import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 2 — Search & ⌘K Command Palette (Features/Search/)
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class SearchModel: ObservableObject {
    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var query: String = ""
    @Published public var mode: SearchMode = .hybrid
    @Published public var results: [SearchHit] = []
    @Published public var isSearching = false
    @Published public var errorMessage: String?
    @Published public var selectedIndex: Int = 0
    @Published public var filterTags: [String] = []
    @Published public var pathPrefix: String?
    // Memory typing/lifecycle filters (contract 0.14.0). Empty/false ⇒ pre-0.14.0.
    @Published public var filterType: String?
    @Published public var filterStatus: String?
    /// Reveal lifecycle-hidden notes (revoked/provisional/superseded/expired) — the
    /// "Manage memories" escape hatch.
    @Published public var includeAll: Bool = false

    /// Tag vocabulary for the filter chips (loaded lazily from `client.tags()`).
    @Published public var availableTags: [Tags.Tag] = []
    /// True once a search has run for the current query; drives the "no results"
    /// empty state vs the initial idle prompt.
    @Published public var hasSearched = false
    /// When true, use `federatedSearch` across all vaults. Default OFF (single-vault, existing behavior).
    @Published public var allVaults: Bool = false

    public init(client: SvodClient) { self.client = client }

    /// Debounced search driven by the search field. The view calls this on every
    /// keystroke and on every filter change; the leading-edge wait collapses bursts
    /// of typing into one request. Cancellation is cooperative — a newer call
    /// supersedes the in-flight wait via `debounceTask`.
    private var debounceTask: Task<Void, Never>?
    /// A tag/path/memory filter alone is enough to search (browse), even with no query.
    private var hasActiveFilters: Bool {
        !filterTags.isEmpty || (pathPrefix?.isEmpty == false) || memoryFilter.isActive
    }

    /// The memory typing/lifecycle filter assembled from the published state.
    public var memoryFilter: MemoryFilter {
        MemoryFilter(type: filterType?.isEmpty == true ? nil : filterType,
                     status: filterStatus?.isEmpty == true ? nil : filterStatus,
                     includeAll: includeAll)
    }

    public func search(debounce: Duration = .milliseconds(180)) {
        debounceTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || hasActiveFilters else {
            isSearching = false; results = []; hasSearched = false; errorMessage = nil; return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.runSearch()
        }
    }

    public func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || hasActiveFilters else { results = []; hasSearched = false; return }
        isSearching = true; errorMessage = nil
        defer { isSearching = false; hasSearched = true }
        let limit = app?.settings.searchResultLimit ?? 20
        do {
            let r: SearchResult
            if allVaults {
                do {
                    r = try await client.federatedSearch(query: q, mode: mode, limit: limit,
                                                         tags: filterTags, pathPrefix: pathPrefix,
                                                         memory: memoryFilter)
                } catch let e as SvodClientError where e.isNotImplemented {
                    // Engine doesn't support across=true yet — fall back to single-vault.
                    r = try await client.search(query: q, mode: mode, limit: limit,
                                                tags: filterTags, pathPrefix: pathPrefix,
                                                memory: memoryFilter)
                    self.errorMessage = "All-vaults search is not yet available on this engine. Showing active-vault results."
                }
            } else {
                r = try await client.search(query: q, mode: mode, limit: limit,
                                            tags: filterTags, pathPrefix: pathPrefix,
                                            memory: memoryFilter)
            }
            // The engine returns per-chunk/per-heading hits, so a note can appear many
            // times (very visible when browsing by tag). Collapse to one row per note,
            // keeping the best-scoring hit.
            self.results = Self.collapsedByNote(r.hits)
            self.selectedIndex = 0
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription; self.results = []
        } catch {
            self.errorMessage = error.localizedDescription; self.results = []
        }
    }

    /// One row per note (best-scoring hit), preserving the engine's relevance order.
    private static func collapsedByNote(_ hits: [SearchHit]) -> [SearchHit] {
        var best: [String: SearchHit] = [:]
        var order: [String] = []
        for h in hits {
            let key = (h.vault ?? "") + ":" + h.path
            if let cur = best[key] {
                if h.score > cur.score { best[key] = h }
            } else {
                best[key] = h; order.append(key)
            }
        }
        return order.compactMap { best[$0] }
    }

    /// Load the tag vocabulary once; failures are silent (chips just don't appear).
    public func loadTags() async {
        guard availableTags.isEmpty else { return }
        if let t = try? await client.tags() {
            availableTags = t.tags.sorted { $0.count > $1.count }
        }
    }

    // MARK: keyboard navigation
    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let next = selectedIndex + delta
        selectedIndex = min(max(next, 0), results.count - 1)
    }

    /// Toggle a tag filter and re-run (debounced) so chips feel live.
    public func toggleTag(_ tag: String) {
        if let i = filterTags.firstIndex(of: tag) { filterTags.remove(at: i) }
        else { filterTags.append(tag) }
        search()
    }

    public var selectedHit: SearchHit? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    public func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        let hit = results[selectedIndex]
        app?.open(path: hit.path, vault: hit.vault)
    }
}
