import SwiftUI
import Foundation

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 5 — Engine Lifecycle (Features/Engine/)
// Foundation ships a working detect → start → poll → connect flow + WS loop so
// the app is alive on launch. Teammate 5 owns the Engine *surface* (status UI,
// the prominent "Start Svod" button, settings/index/metrics presentation) and
// may refine this driver — keep `startConnecting()` / `start()` working.
// ════════════════════════════════════════════════════════════════════════

@MainActor
public final class EngineModel: ObservableObject {
    public weak var app: AppModel?
    public let client: SvodClient

    @Published public var settings: Settings?
    @Published public var indexStatus: IndexStatus?
    @Published public var metrics: Metrics?
    @Published public var startError: String?

    private var eventTask: Task<Void, Never>?
    private var reconnectAttempts = 0

    /// launchd label for the engine agent (see dist/README.md).
    public static let launchdLabel = "dev.svod.engine"

    public init(client: SvodClient) { self.client = client }

    public var state: ConnectionState { app?.connection ?? .disconnected }

    // MARK: detect → connect (called on launch)
    public func startConnecting() {
        Task { await connect() }
    }

    /// Health/ready check; on success open the WebSocket and load engine meta.
    public func connect() async {
        guard let app else { return }
        if case .connected = app.connection { return }
        app.connection = .connecting
        do {
            let ready = try await client.ready()
            guard ready.ready else { app.connection = .disconnected; return }
            app.connection = .connected
            reconnectAttempts = 0
            await loadMeta()
            startEventStream()
        } catch let e as SvodClientError where e.isOffline {
            app.connection = .disconnected
        } catch {
            app.connection = .error((error as? SvodClientError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: one-button start (launchctl kickstart → poll /ready → connect)
    public func start() async {
        guard let app else { return }
        startError = nil
        app.connection = .starting
        kickstart()
        // Poll /ready for up to ~20s.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let ready = try? await client.ready(), ready.ready {
                await connect()
                return
            }
        }
        app.connection = .error("Engine did not become ready in time.")
        startError = "Timed out waiting for the engine. Check the launchd agent."
    }

    /// `launchctl kickstart -k gui/<uid>/dev.svod.engine`. No-ops gracefully if the
    /// agent isn't installed (the poll loop then times out into an error state).
    private func kickstart() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(Self.launchdLabel)"]
        process.standardOutput = nil
        process.standardError = nil
        do { try process.run() } catch {
            startError = "Couldn't run launchctl: \(error.localizedDescription)"
        }
    }

    // MARK: live event stream (with gentle backoff reconnect)
    private func startEventStream() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in self.client.events() {
                    if Task.isCancelled { break }
                    self.app?.latestEvent = event
                    self.app?.activity.ingest(event)
                    if event.type == .indexUpdated { await self.refreshIndex() }
                    if event.type == .engineStatus, event.data.ready == false {
                        self.app?.connection = .disconnected
                    }
                }
            } catch {
                // stream dropped
            }
            if !Task.isCancelled { await self.handleDisconnect() }
        }
    }

    private func handleDisconnect() async {
        guard let app else { return }
        if case .connected = app.connection { app.connection = .disconnected }
        reconnectAttempts += 1
        let delay = min(8.0, pow(1.6, Double(reconnectAttempts)))   // 1.6s … 8s
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        if !Task.isCancelled { await connect() }
    }

    public func disconnect() {
        eventTask?.cancel(); eventTask = nil
        app?.connection = .disconnected
    }

    // MARK: meta
    public func loadMeta() async {
        async let s = try? await client.settings()
        async let i = try? await client.indexStatus()
        async let m = try? await client.metrics()
        self.settings = await s
        self.indexStatus = await i
        self.metrics = await m
    }

    private func refreshIndex() async {
        self.indexStatus = try? await client.indexStatus()
    }
}
