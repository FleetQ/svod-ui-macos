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

    public init(client: SvodClient) { self.client = client }

    public func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }
        isSearching = true; errorMessage = nil
        defer { isSearching = false }
        do {
            let r = try await client.search(query: q, mode: mode, limit: 20,
                                            tags: filterTags, pathPrefix: pathPrefix)
            self.results = r.hits
            self.selectedIndex = 0
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription; self.results = []
        } catch {
            self.errorMessage = error.localizedDescription; self.results = []
        }
    }

    public func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        app?.open(path: results[selectedIndex].path)
    }
}
