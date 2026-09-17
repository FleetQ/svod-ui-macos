import Foundation

// The memory review queue for the ACTIVE vault (contract 0.33.0). Agents store fact/policy
// memories as provisional, and recall hides them until a person confirms them here.
// Approve/decline remove the row at once and put it back if the engine refuses; each acted
// row keeps what Undo needs (the revision the action produced) until the queue is reloaded.

@MainActor
public final class MemoryReviewModel: ObservableObject {
    @Published public private(set) var items: [MemoryReviewItem] = []
    @Published public private(set) var total = 0
    /// Paths with a request in flight.
    @Published public private(set) var busy: Set<String> = []
    @Published public private(set) var loaded = false
    @Published public var errorMessage: String?
    /// Rows approved or declined in this view, newest first, for Undo.
    @Published public private(set) var acted: [Acted] = []

    public struct Acted: Identifiable, Hashable, Sendable {
        public let item: MemoryReviewItem
        public let action: MemoryReviewVerb
        /// The status the memory had before the action (what Undo restores in the queue).
        public let previousStatus: String?
        /// Revision the action wrote — Undo's `expectedRevision`.
        public let revision: String
        public var id: String { item.path }
    }

    public static let pageSize = 200

    private let client: SvodClient
    /// Called after every successful action, e.g. to refresh an "awaiting review" count elsewhere.
    public var onChange: (() -> Void)?

    public init(client: SvodClient) { self.client = client }

    public func load() async {
        do {
            let list = try await client.memoryReview(limit: Self.pageSize)
            items = list.items
            total = list.total
            acted.removeAll { a in list.items.contains { $0.path == a.item.path } }
            loaded = true
        } catch let e as SvodClientError where e.isOffline {
            // keep the last good queue
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    public func approve(_ item: MemoryReviewItem) async { await act(item, .approve) }
    public func decline(_ item: MemoryReviewItem) async { await act(item, .decline) }

    private func act(_ item: MemoryReviewItem, _ action: MemoryReviewVerb) async {
        guard !busy.contains(item.path), let index = items.firstIndex(where: { $0.path == item.path }) else { return }
        errorMessage = nil
        busy.insert(item.path); defer { busy.remove(item.path) }
        items.remove(at: index)
        total = max(0, total - 1)
        do {
            let result = try await client.reviewMemory(path: item.path, action: action, expectedRevision: item.revision)
            acted.removeAll { $0.item.path == item.path }
            acted.insert(Acted(item: item, action: action, previousStatus: item.status, revision: result.revision), at: 0)
            onChange?()
        } catch {
            items.insert(item, at: min(index, items.count))
            total += 1
            if Self.isConflict(error) {
                errorMessage = Self.conflictMessage(error)
                await load()
            } else {
                errorMessage = Self.describe(error)
            }
        }
    }

    /// Reopen an acted memory: back to provisional, back in the queue.
    public func undo(_ entry: Acted) async {
        let path = entry.item.path
        guard !busy.contains(path) else { return }
        errorMessage = nil
        busy.insert(path); defer { busy.remove(path) }
        do {
            let result = try await client.reviewMemory(path: path, action: .reopen, expectedRevision: entry.revision)
            acted.removeAll { $0.item.path == path }
            var restored = entry.item
            restored.revision = result.revision
            restored.status = result.status
            items.insert(restored, at: 0)
            total += 1
            onChange?()
        } catch {
            errorMessage = Self.isConflict(error) ? Self.conflictMessage(error) : Self.describe(error)
            if Self.isConflict(error) {
                acted.removeAll { $0.item.path == path }
                await load()
            }
        }
    }

    static func isConflict(_ error: Error) -> Bool {
        switch error as? SvodClientError {
        case .conflict?: return true
        case .http(409, _)?: return true
        default: return false
        }
    }

    private static func conflictMessage(_ error: Error) -> String {
        if case .http(409, let message)? = error as? SvodClientError, let message, message != "Conflict" {
            return message + " The list was reloaded."
        }
        return "This memory changed since the list loaded. The list was reloaded."
    }

    private static func describe(_ error: Error) -> String {
        (error as? SvodClientError)?.errorDescription ?? error.localizedDescription
    }
}
