import XCTest
@testable import Svod

/// The engine's discovery file lets the app find an engine on non-default ports or labels.
final class EngineDiscoveryTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsWhatTheEngineWrites() throws {
        let url = try write(#"{"host":"127.0.0.1","appApiPort":7619,"mcpPort":7620,"pid":1505,"launchdLabel":"com.example.svod"}"#)
        let d = try XCTUnwrap(EngineDiscovery.load(from: url))
        XCTAssertEqual(d.appApiPort, 7619)
        XCTAssertEqual(d.mcpPort, 7620)
        XCTAssertEqual(d.launchdLabel, "com.example.svod")
    }

    func testMissingOrBrokenFileIsNil() throws {
        XCTAssertNil(EngineDiscovery.load(from: URL(fileURLWithPath: "/nonexistent/engine.json")))
        XCTAssertNil(EngineDiscovery.load(from: try write("{not json")))
    }

    func testAdoptsOnlyADifferentLoopbackEndpoint() {
        let d = EngineDiscovery(host: "127.0.0.1", appApiPort: 7619, mcpPort: 7620, launchdLabel: nil)
        XCTAssertEqual(d.endpointToAdopt(currentHost: "127.0.0.1", currentPort: 7517)?.port, 7619)
        XCTAssertNil(d.endpointToAdopt(currentHost: "127.0.0.1", currentPort: 7619), "already there")
        XCTAssertNil(d.endpointToAdopt(currentHost: "10.0.0.5", currentPort: 7517), "a remote endpoint is the user's choice")
        let remote = EngineDiscovery(host: "0.0.0.0", appApiPort: 7619, mcpPort: nil, launchdLabel: nil)
        XCTAssertNil(remote.endpointToAdopt(currentHost: "127.0.0.1", currentPort: 7517))
    }

    /// 7619 is an SSH tunnel to a central engine; 7629 is a local engine with other vaults. While
    /// the tunnel is down the app must not switch to 7629 and stay there.
    func testNeverLeavesAPinnedEndpoint() {
        let local = EngineDiscovery(host: "127.0.0.1", appApiPort: 7629, mcpPort: 7630, launchdLabel: nil)
        XCTAssertNil(local.endpointToAdopt(currentHost: "127.0.0.1", currentPort: 7619, pinned: true))
        XCTAssertEqual(local.endpointToAdopt(currentHost: "127.0.0.1", currentPort: 7619, pinned: false)?.port, 7629)
    }

    func testOldInstallsPinOnlyAnEndpointTheUserTypedIn() {
        let local = EngineDiscovery(host: "127.0.0.1", appApiPort: 7629, mcpPort: 7630, launchdLabel: nil)
        XCTAssertFalse(SettingsStore.wasChosenByUser(host: "127.0.0.1", port: 7517, discovered: local), "default")
        XCTAssertFalse(SettingsStore.wasChosenByUser(host: "127.0.0.1", port: 7629, discovered: local), "taken from the discovery file")
        XCTAssertTrue(SettingsStore.wasChosenByUser(host: "127.0.0.1", port: 7619, discovered: local))
        XCTAssertTrue(SettingsStore.wasChosenByUser(host: "127.0.0.1", port: 7619, discovered: nil))
    }
}
