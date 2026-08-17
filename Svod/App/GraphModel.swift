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
    }

    /// Load the thematic communities. Only called when the engine advertises 0.24.0 or newer.
    public func loadCommunities() async {
        communitiesLoading = true
        defer { communitiesLoading = false }
        do {
            let status = try await client.graphStatus()
            communitiesState = status.state
            communitiesStale = status.stale
            guard status.state != "NOT_BUILT" else { communities = []; return }
            // `sample`, not `full`: the complete membership of 50 themes was ~44k tokens / 177 KB of
            // paths the list never shows. The one theme in focus fetches its own via graphCommunity.
            let result = try await client.graphCommunities(query: nil, level: nil, limit: 50, members: "sample")
            communities = result.communities
            communitiesState = result.state
            communitiesStale = result.stale
        } catch {
            // The pane is only shown on a supporting engine, so a failure here is transient
            // (engine restarting, vault switching). Drop the data and leave the pane to retry.
            communities = []
            communitiesState = "NOT_BUILT"
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
