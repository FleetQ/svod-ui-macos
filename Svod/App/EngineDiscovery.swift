import Foundation

/// Where the local engine says it is: `~/.config/svod/engine.json`, rewritten by the engine on
/// every start. The app defaults to 127.0.0.1:7517 and launchd label `dev.svod.engine`; an engine
/// installed on other ports or under another label is found through this file instead of the app
/// sitting in "offline" with nothing to go on.
public struct EngineDiscovery: Codable, Equatable, Sendable {
    public var host: String
    public var appApiPort: Int
    public var mcpPort: Int?
    public var launchdLabel: String?

    public static let defaultLabel = "dev.svod.engine"

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/svod/engine.json")
    }

    public static func load(from url: URL = defaultURL) -> EngineDiscovery? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EngineDiscovery.self, from: data)
    }

    /// The endpoint to switch to, or nil to keep the configured one. Only a loopback engine
    /// replaces a loopback endpoint: a remote address the user typed in is never overridden by
    /// a local file.
    public func endpointToAdopt(currentHost: String, currentPort: Int) -> (host: String, port: Int)? {
        guard EngineAddress.isLoopback(currentHost), EngineAddress.isLoopback(host),
              (1...65535).contains(appApiPort),
              host != currentHost || appApiPort != currentPort
        else { return nil }
        return (host, appApiPort)
    }
}
