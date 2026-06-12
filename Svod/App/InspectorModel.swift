import SwiftUI

// MARK: - InspectorModel  (owned by Teammate 5 — Inspector pane)
//
// Loads the per-note inspector data: backlinks, cross-vault backlinks (notes in
// OTHER vaults that link here), and a short history summary. The view (Teammate 5)
// observes this; AppModel composes it. Cross-vault navigation calls
// `app.openGlobal(_:)` so a jump can switch vaults first.
//
// This is the minimal frozen seam: published state + a load(path:) entry point.
// Teammate 5 fleshes out presentation and any extra signals in their folder.

@MainActor
public final class InspectorModel: ObservableObject {
    public weak var app: AppModel?
    private let client: SvodClient

    @Published public private(set) var links: FileLinks?
    @Published public private(set) var recentCommits: [CommitInfo] = []
    @Published public private(set) var loading = false
    @Published public private(set) var errorText: String?

    public init(client: SvodClient) { self.client = client }

    public var crossVaultBacklinks: [GlobalNoteRef] { links?.crossVaultRefs ?? [] }

    /// Load inspector data for a note in the active vault. No-op for nil path.
    public func load(path: String?) async {
        guard let path else { links = nil; recentCommits = []; return }
        loading = true; errorText = nil
        defer { loading = false }
        do {
            async let l = client.fileLinks(path: path)
            async let h = client.history(path: path, max: 5)
            links = try await l
            recentCommits = try await h
        } catch let e as SvodClientError where e.isOffline {
            errorText = e.errorDescription
        } catch {
            // Links/history are best-effort; surface nothing noisy on transient misses.
            errorText = nil
        }
    }
}
