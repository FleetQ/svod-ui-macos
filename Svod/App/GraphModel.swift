import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 3 — Graph View (Features/Graph/)
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class GraphModel: ObservableObject {
    public enum Scope: Hashable, Sendable { case global, local }

    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var graph: Graph?
    @Published public var scope: Scope = .global
    @Published public var isLoading = false
    @Published public var errorMessage: String?
    @Published public var hoveredNodeID: String?

    // ---- derived thematic graph (contract 0.24.0) ----
    //
    // Support is decided by `EngineModel.supportsGraphCommunities` (apiVersion >= 0.24.0), NOT by
    // catching a 404 here: the engine serves the web viewer as an SPA fallback, so an unknown path
    // returns 200 text/html and the client raises a DECODING error, not `notFound`. An earlier
    // version of this file gated on `.notFound` and would have left the pane visible-but-empty
    // against every older engine — caught by probing the live 0.23.0 engine.

    @Published public var communities: [GraphCommunity] = []
    @Published public var communitiesState: String = "NOT_BUILT"
    @Published public var communitiesStale = false
    @Published public var communitiesLoading = false
    @Published public var selectedCommunityID: String?

    /// Notes written since the last full build (contract 0.26.0), or nil when the engine cannot say.
    ///
    /// nil and 0 mean different things and the pane renders them differently: nil is "not reported"
    /// (older engine, or incremental attachment switched off) and falls back to the bare stale badge,
    /// while 0 is a positive statement that nothing is missing from the map.
    @Published public var newSinceBuild: Int?
    /// Of those, the ones on no theme at all — the part a rebuild would actually fix.
    @Published public var pendingNotes = 0
    /// Share of attached notes that would now be placed elsewhere; nil when the engine cannot say.
    @Published public var driftRatio: Double?

    /// Which hierarchy level the pane is showing; nil means the coarsest (the engine's default).
    ///
    /// Worth exposing because the coarse level is the least precise one: measured on the real vault,
    /// its median theme holds 44 notes and the largest holds 320, while one level down the median is
    /// 7. The finer levels were reachable through the API from the start and unreachable from the UI.
    @Published public var level: Int?
    /// How many levels this vault's graph has, so the picker only offers ones that exist.
    @Published public var levelCount = 0

    /// Themes worth listing.
    ///
    /// A Louvain level partitions the WHOLE corpus, so most of its communities are single notes that
    /// simply had no close neighbour — measured, the coarsest level of `personal` has 546 communities
    /// of which 38 have three or more members. Those singletons are rows with a filename for a title
    /// and nothing to say; the engine already hides them from summarisation for the same reason.
    public var visibleCommunities: [GraphCommunity] {
        communities.filter { $0.size >= Self.minThemeSize }
    }

    /// Mirrors the engine's `minCommunitySize` default — the size below which it will not summarise.
    private static let minThemeSize = 3

    public init(client: SvodClient) { self.client = client }

    public func load() async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            self.graph = try await client.graph()
        } catch let e as SvodClientError {
            self.errorMessage = e.errorDescription
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// Wipe current graph so the canvas animates out before a vault-switch reload.
    public func clearGraph() {
        graph = nil
        errorMessage = nil
        communities = []
        selectedCommunityID = nil
        communitiesState = "NOT_BUILT"
        communitiesStale = false
        newSinceBuild = nil
        pendingNotes = 0
        driftRatio = nil
        level = nil
        levelCount = 0
    }

    /// Switch the pane to a different hierarchy level and reload it.
    ///
    /// Clears the theme selection first: ids are per-level, so keeping one would leave the notes tree
    /// filtered to a theme that is no longer on screen.
    public func showLevel(_ next: Int?) async {
        guard next != level else { return }
        level = next
        selectedCommunityID = nil
        app?.themeFilter = nil
        await loadCommunities()
    }

    /// Load the thematic communities. Only called when the engine advertises 0.24.0 or newer.
    public func loadCommunities() async {
        communitiesLoading = true
        defer { communitiesLoading = false }
        do {
            let status = try await client.graphStatus()
            communitiesState = status.state
            communitiesStale = status.stale
            newSinceBuild = status.newSinceBuild
            pendingNotes = status.pendingCount ?? 0
            driftRatio = status.driftRatio
            levelCount = status.levelCount
            // A level that no longer exists (vault switched, graph rebuilt shallower) must not be
            // requested — the engine would clamp it silently and the picker would lie about what is
            // on screen.
            if let l = level, l >= status.levelCount { level = nil }
            guard status.state != "NOT_BUILT" else { communities = []; return }
            // `sample`, not `full`: the complete membership of 50 themes was ~44k tokens / 177 KB of
            // paths the list never shows. The one theme in focus fetches its own via graphCommunity.
            let result = try await client.graphCommunities(query: nil, level: level, limit: 50, members: "sample")
            communities = result.communities
            communitiesState = result.state
            communitiesStale = result.stale
        } catch {
            // The pane is only shown on a supporting engine, so a failure here is transient
            // (engine restarting, vault switching). Drop the data and leave the pane to retry.
            communities = []
            communitiesState = "NOT_BUILT"
            newSinceBuild = nil
            pendingNotes = 0
            driftRatio = nil
        }
    }

    /// Ask the engine to rebuild, then poll until it settles so the pane reflects the new state.
    public func rebuildCommunities() async {
        communitiesLoading = true
        defer { communitiesLoading = false }
        do {
            _ = try await client.graphRebuild()
            for _ in 0..<120 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let status = try await client.graphStatus()
                communitiesState = status.state
                if !status.isBuilding { break }
            }
        } catch {
            // Rebuild is a convenience; a failure leaves whatever was already loaded in place.
        }
        await loadCommunities()
    }

    public var selectedCommunity: GraphCommunity? {
        guard let id = selectedCommunityID else { return nil }
        return communities.first { $0.id == id }
    }

    /// Select a theme and narrow the notes tree to its members — the point of selecting one.
    ///
    /// The listing only carries a preview of the membership, so the full set is fetched here, for
    /// this one theme. Passing nil clears both the selection and the tree filter.
    public func selectCommunity(_ id: String?) async {
        selectedCommunityID = id
        guard let id, let app else {
            app?.themeFilter = nil
            return
        }
        do {
            let full = try await client.graphCommunity(id: id)
            app.themeFilter = AppModel.ThemeFilter(id: full.id, title: full.title, paths: Set(full.members))
        } catch {
            // An older engine or a rebuild mid-flight: keep the selection visible in the pane but do
            // not filter the tree to a set we could not load — an empty tree would look like data loss.
            app.themeFilter = nil
        }
    }

    /// Path the local view re-centers on (the open note). Read from AppModel.
    public var focusPath: String? { app?.selectedPath }

    /// The graph to render for the current scope. Global returns the full graph;
    /// local returns a 1-hop neighborhood around `focusPath`, derived by filtering
    /// the already-loaded global graph (no extra round-trip). Unresolved edges are
    /// kept only when their source survives the filter.
    /// Selecting a theme deliberately does NOT scope this canvas.
    ///
    /// It used to, and the result was an almost-empty view: this graph is the WIKILINK graph, while
    /// themes are formed mostly from embedding similarity. Measured on the real vault, the 300-note
    /// "Documentation and Policies" theme had **zero** wikilink edges among its members, and several
    /// others had one or two — so scoping to a theme reliably produced a field of unconnected dots.
    /// Filtering the notes tree is where a theme selection now leads instead.
    public func scopedGraph() -> Graph? {
        guard let graph else { return nil }
        guard scope == .local, let focus = focusPath, graph.nodes.contains(where: { $0.id == focus })
        else { return graph }

        var keep: Set<String> = [focus]
        for e in graph.edges where e.source == focus || e.target == focus {
            keep.insert(e.source); keep.insert(e.target)
        }
        let nodes = graph.nodes.filter { keep.contains($0.id) }
        let edges = graph.edges.filter { keep.contains($0.source) && keep.contains($0.target) }
        let unresolved = graph.unresolved.filter { keep.contains($0.source) }
        return Graph(nodes: nodes, edges: edges, unresolved: unresolved)
    }
}
