import Foundation

// MARK: - Live WebSocket events (/api/v1/events)
//
// Wire shape: { "type": <EventType>, "ts": <epochMillis>, "data": { ... } }.
// `data` is freeform per the contract (additionalProperties: true). We decode the
// fields the UI actually uses (all optional) and ignore the rest. Confirmed
// against examples/web-viewer/app.js.

public enum EventType: String, Codable, Hashable, Sendable {
    case fileChanged   = "file.changed"
    case indexUpdated  = "index.updated"
    case commitCreated = "commit.created"
    case conflict      = "conflict"
    case engineStatus  = "engine.status"
    case agentActivity = "agent.activity"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EventType(rawValue: raw) ?? .unknown
    }
}

/// Decoded payload of an event's `data` object. Every field is optional because
/// the contract leaves `data` freeform and fields vary by event type.
public struct EventPayload: Codable, Hashable, Sendable {
    public var path: String?
    public var commit: String?
    public var agentId: String?
    public var author: String?
    public var source: String?      // e.g. "watcher" for external changes
    public var tool: String?        // write | delete | move | promote | restore
    public var message: String?
    public var docCount: Int?
    public var ready: Bool?
    /// Vault id this event belongs to (engine v0.3.0 multi-vault). The contract
    /// leaves `data` freeform, so this is best-effort: nil means default/unknown.
    public var vault: String?

    /// Best-effort author identity for display, mirroring the reference viewer:
    /// agentId → author → "external" (watcher) → "ui".
    public var displayActor: String {
        if let a = agentId, !a.isEmpty { return a }
        if let a = author, !a.isEmpty { return a }
        if source == "watcher" { return "external" }
        return "ui"
    }

    /// Human verb for the tool, mirroring the reference viewer.
    public var verb: String {
        switch tool {
        case "write": "wrote"
        case "delete": "deleted"
        case "move": "moved"
        case "promote": "promoted"
        case "restore": "restored"
        case let t?: t
        case nil: "wrote"
        }
    }
}

public struct SvodEvent: Codable, Hashable, Sendable, Identifiable {
    public var type: EventType
    public var ts: Int64            // epoch milliseconds
    public var data: EventPayload

    /// Stable-ish identity for list diffing: commit when present, else type+ts+path.
    public var id: String {
        if let c = data.commit { return c }
        return "\(type.rawValue):\(ts):\(data.path ?? "")"
    }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000.0) }

    public init(type: EventType, ts: Int64, data: EventPayload) {
        self.type = type; self.ts = ts; self.data = data
    }
}
