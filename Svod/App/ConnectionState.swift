import SwiftUI

// MARK: - ConnectionState
//
// Engine connection lifecycle, shared by the toolbar, offline states, and the
// Engine surface. Driven by EngineModel (Teammate 5), read everywhere.

public enum ConnectionState: Equatable, Sendable {
    case disconnected
    case starting        // "Start Svod" issued launchctl kickstart; polling /ready
    case connecting      // /ready returned ok; opening the WebSocket
    case connected
    case error(String)

    public var isConnected: Bool { self == .connected }

    public var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .starting:     "Starting…"
        case .connecting:   "Connecting…"
        case .connected:    "Connected"
        case .error:        "Error"
        }
    }

    public var pillTone: StatusPill.Tone {
        switch self {
        case .disconnected: .offline
        case .starting, .connecting: .warning
        case .connected: .success
        case .error: .danger
        }
    }
}

// MARK: - Center pane mode
public enum CenterMode: Hashable, Sendable {
    case editor      // the note editor (Teammate 1)
    case graph       // graph view (Teammate 3)
    case history     // per-file timeline + diff (Teammate 4)
}
