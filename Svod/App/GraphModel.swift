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
}
