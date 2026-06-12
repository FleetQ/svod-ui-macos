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

    /// Path the local view re-centers on (the open note). Read from AppModel.
    public var focusPath: String? { app?.selectedPath }

    /// The graph to render for the current scope. Global returns the full graph;
    /// local returns a 1-hop neighborhood around `focusPath`, derived by filtering
    /// the already-loaded global graph (no extra round-trip). Unresolved edges are
    /// kept only when their source survives the filter.
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
