import XCTest
@testable import Svod

/// Pinned notes: personal, per vault, and only shown while the note still exists.
@MainActor
final class SidebarPinsTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "svod.tests.sidebar.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func model() -> SidebarModel { SidebarModel(client: MockSvodClient(), defaults: defaults) }

    func testTogglePinsAndUnpins() {
        let m = model()
        m.togglePin("vault/a.md")
        XCTAssertTrue(m.isPinned("vault/a.md"))
        m.togglePin("vault/a.md")
        XCTAssertFalse(m.isPinned("vault/a.md"))
        XCTAssertEqual(m.pinned, [])
    }

    func testPinsSurviveARelaunchInPinOrder() {
        let m = model()
        m.togglePin("vault/b.md")
        m.togglePin("vault/a.md")
        let fresh = model()
        fresh.loadPins()
        XCTAssertEqual(fresh.pinned, ["vault/b.md", "vault/a.md"])
    }

    func testPinsAreScopedToTheActiveVault() async throws {
        let app = AppModel(client: MockSvodClient())
        await app.vault.load()
        let ids = app.vault.vaults.map(\.id)
        guard ids.count >= 2, let first = app.vault.activeVaultId,
              let other = ids.first(where: { $0 != first }) else {
            throw XCTSkip("mock exposes a single vault")
        }
        let m = model()
        m.app = app
        m.togglePin("vault/a.md")
        XCTAssertEqual(defaults.stringArray(forKey: "svod.sidebar.pinned.\(first)"), ["vault/a.md"])

        app.vault.switchVault(other)
        m.loadPins()
        XCTAssertTrue(m.pinned.isEmpty, "another vault's pins must not leak across a switch")

        app.vault.switchVault(first)
        m.loadPins()
        XCTAssertEqual(m.pinned, ["vault/a.md"])
    }

    func testOnlyPinsWhoseNoteExistsAreShown() {
        let m = model()
        m.togglePin("vault/gone.md")
        m.togglePin("vault/a.md")
        XCTAssertEqual(m.pinnedNotes, [], "nothing to show before the tree has loaded")

        m.tree = TreeNode(name: "vault", path: "vault", type: .dir, children: [
            TreeNode(name: "a.md", path: "vault/a.md", type: .file),
            TreeNode(name: "sub", path: "vault/sub", type: .dir, children: [
                TreeNode(name: "c.md", path: "vault/sub/c.md", type: .file),
            ]),
        ])
        m.togglePin("vault/sub/c.md")

        // Hidden, not dropped: the pin is still stored and comes back if the note does.
        XCTAssertEqual(m.pinnedNotes, ["vault/a.md", "vault/sub/c.md"])
        XCTAssertTrue(m.isPinned("vault/gone.md"))
    }
}
