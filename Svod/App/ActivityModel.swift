import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Agent Activity (Features/Activity/)
// Live, WebSocket-driven feed. EngineModel forwards each event via `ingest`.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class ActivityModel: ObservableObject {
    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var feed: [SvodEvent] = []

    private var shownCommits = Set<String>()
    private let cap = 200

    public init(client: SvodClient) { self.client = client }

    /// Append a live event, de-duping by commit id (an MCP write surfaces as both
    /// agent.activity and commit.created for the same commit — show it once).
    public func ingest(_ event: SvodEvent) {
        switch event.type {
        case .agentActivity, .commitCreated, .conflict, .fileChanged:
            if let commit = event.data.commit {
                if shownCommits.contains(commit) { return }
                shownCommits.insert(commit)
            }
            withAnimation(Motion.arrive) {
                feed.insert(event, at: 0)
                if feed.count > cap { feed.removeLast(feed.count - cap) }
            }
        case .indexUpdated, .engineStatus, .unknown:
            break
        }
    }

    /// Events for a specific note (used by the Inspector's per-note activity).
    public func events(for path: String) -> [SvodEvent] {
        feed.filter { $0.data.path == path }
    }

    public func clear() { feed.removeAll(); shownCommits.removeAll() }
}
