import Foundation

// MARK: - SyncRun
//
// One press of "Sync now" on an engine with the async mode (contract 0.35.0): the cycle the
// request started or joined, followed through sync.* events or GET /sync/status until it ends.
// Pure state, so the view only feeds it and reads the texts back.

public struct SyncRun: Equatable {
    public enum Outcome: Equatable {
        case synced
        case conflicts(Int)
        case failed(String)
    }

    /// Vault key the request went to (a router key for a vault on a central engine); nil = default.
    public let vault: String?
    /// The press found a cycle already running and joined it instead of starting a second one.
    public let joined: Bool
    /// Trigger of the followed cycle. A sync.finished of another cycle (an older poll cycle whose
    /// event arrives after our 202) must not end this run.
    public let trigger: String?
    public private(set) var phase: String?
    public private(set) var outcome: Outcome?

    public init(vault: String?, accepted: SyncRunStatus, wasRunning: Bool) {
        self.vault = vault
        self.trigger = accepted.trigger
        // The engine joins silently: the 202 looks the same either way. A cycle started by
        // anything but this press has another trigger; a manual one from elsewhere shows up
        // only in the status read just before the press.
        self.joined = wasRunning || (accepted.running && accepted.trigger.map { $0 != "manual" } ?? false)
        self.phase = accepted.phase
        if !accepted.running { outcome = Self.outcome(status: accepted.syncStatus, conflicts: accepted.conflicts) }
    }

    public var isFinished: Bool { outcome != nil }

    public mutating func apply(_ event: SvodEvent) {
        guard outcome == nil, belongs(event) else { return }
        switch event.type {
        case .syncProgress:
            phase = event.data.phase
        case .syncFinished:
            if let t = trigger, let et = event.data.trigger, et != t { return }
            outcome = Self.outcome(status: event.data.status, conflicts: event.data.conflicts ?? 0)
        default:
            break
        }
    }

    public mutating func apply(_ status: SyncRunStatus) {
        guard outcome == nil else { return }
        if status.running {
            phase = status.phase
        } else {
            outcome = Self.outcome(status: status.syncStatus, conflicts: status.conflicts)
        }
    }

    /// An untagged event means the default vault; a run on the default vault takes any.
    private func belongs(_ event: SvodEvent) -> Bool {
        guard let vault, let ev = event.data.vault else { return true }
        return ev == vault
    }

    static func outcome(status: String?, conflicts: Int) -> Outcome {
        switch status {
        case "conflicts": return .conflicts(max(conflicts, 1))
        case "offline":   return .failed("the remote could not be reached")
        case "error":     return .failed("the engine reported an error (see its log)")
        default:          return conflicts > 0 ? .conflicts(conflicts) : .synced
        }
    }

    /// Label while running, e.g. "Joined the running sync · fetching".
    public var progressLabel: String {
        let base = joined ? "Joined the running sync" : "Syncing"
        let step: String? = switch phase {
        case "commit": "committing"
        case "fetch":  "fetching"
        case "merge":  "merging"
        case "push":   "pushing"
        default:       nil
        }
        return step.map { "\(base) · \($0)" } ?? base
    }

    public var resultText: String? {
        guard let outcome else { return nil }
        let text: String
        switch outcome {
        case .synced:           text = "Synced"
        case .conflicts(let n): text = "Synced · \(n) conflict\(n == 1 ? "" : "s") to resolve"
        case .failed(let why):  text = "Sync failed: \(why)"
        }
        return joined ? "\(text) (joined a sync that was already running)" : text
    }
}
