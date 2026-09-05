import XCTest
@testable import Svod

/// Profiles persist in an INJECTED defaults suite; keys live in an injected 0600 file dir.
@MainActor
final class EngineProfileStoreTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!
    private var dir: URL!

    override func setUp() {
        super.setUp()
        suite = "svod.tests.engines.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("svod-engines-\(UUID().uuidString)")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func store() -> EngineProfileStore { EngineProfileStore(defaults: defaults, secretsDir: dir) }

    func testAddPersistsProfileAndStoresKey0600() throws {
        let s = store()
        let p = try s.add(EngineProfile(id: "central", name: "Company", baseURL: URL(string: "https://svod.example.com")!), apiKey: "svk_abc")
        XCTAssertEqual(s.profiles, [p])
        XCTAssertEqual(s.apiKey(for: "central"), "svk_abc")
        let attrs = try FileManager.default.attributesOfItem(atPath: s.keyFile("central").path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? 0, 0o600)
        XCTAssertNil(defaults.string(forKey: EngineProfileStore.defaultsKey)?.range(of: "svk_abc"), "the key must not reach UserDefaults")

        let fresh = store()
        XCTAssertEqual(fresh.profiles, [p], "profiles survive a relaunch through the injected suite")
        XCTAssertEqual(fresh.apiKey(for: "central"), "svk_abc")
    }

    func testRemoveDeletesProfileAndKey() throws {
        let s = store()
        try s.add(EngineProfile(id: "x", name: "X", baseURL: URL(string: "https://x.example")!), apiKey: "svk_x")
        s.remove("x")
        XCTAssertTrue(s.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.keyFile("x").path))
        XCTAssertNil(s.apiKey(for: "x"))
    }

    func testReplacingAProfileKeepsOneEntry() throws {
        let s = store()
        try s.add(EngineProfile(id: "c", name: "Old", baseURL: URL(string: "https://a.example")!), apiKey: "k1")
        try s.add(EngineProfile(id: "c", name: "New", baseURL: URL(string: "https://b.example")!), apiKey: "k2")
        XCTAssertEqual(s.profiles.count, 1)
        XCTAssertEqual(s.profiles.first?.name, "New")
        XCTAssertEqual(s.apiKey(for: "c"), "k2")
    }
}
