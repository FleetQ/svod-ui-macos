import XCTest
@testable import Svod

/// The router: a vault key picks the engine; vault lists merge; one dead remote never hides the local engine.
final class MultiEngineClientTests: XCTestCase {

    /// A mock that knows which engine it is: distinct vault ids, records what it served.
    final class EngineMock: MockSvodClient, @unchecked Sendable {
        let tag: String
        let down: Bool
        var served: [String] = []
        init(tag: String, down: Bool = false) { self.tag = tag; self.down = down; super.init() }

        override func vaults() async throws -> Vaults {
            if down { throw SvodClientError.offline }
            served.append("vaults")
            return Vaults(vaults: [
                Vault(id: "\(tag)-main", name: "\(tag) main", isDefault: true, role: "editor"),
                Vault(id: "\(tag)-docs", name: "\(tag) docs", isDefault: false, role: "reader"),
            ])
        }
        override func tree() async throws -> TreeNode {
            served.append("tree@\(activeVault ?? "nil")")
            return TreeNode(name: tag, path: tag, type: .dir, children: [])
        }
        override func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
            served.append("write:\(path)@\(activeVault ?? "nil")")
            return WriteResult(path: path, revision: "r1", commit: "c1")
        }
        override func writeFile(path: String, content: String, expectedRevision: String?, inVault vault: String?) async throws -> WriteResult {
            served.append("write:\(path)@\(vault ?? activeVault ?? "nil")")
            return WriteResult(path: path, revision: "r1", commit: "c1")
        }
        override func health() async throws -> Health { served.append("health"); return Health(status: "ok") }
        override func me() async throws -> Me { served.append("me"); return Me(userId: tag, name: tag, admin: false, local: false) }
        override func events() -> AsyncThrowingStream<SvodEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(SvodEvent(type: .commitCreated, ts: 1, data: EventPayload(path: "\(tag).md", commit: "c-\(tag)", vault: tag == "local" ? "local-main" : nil)))
                c.finish()
            }
        }
    }

    private func make(remoteDown: Bool = false) -> (MultiEngineClient, EngineMock, EngineMock) {
        let local = EngineMock(tag: "local")
        let remote = EngineMock(tag: "remote", down: remoteDown)
        let router = MultiEngineClient(local: local, remotes: [.init(id: "central", name: "Company", client: remote)])
        return (router, local, remote)
    }

    func testVaultsMergeAndRekeyRemoteOnes() async throws {
        let (router, _, _) = make()
        let vs = try await router.vaults().vaults
        XCTAssertEqual(vs.map(\.id), ["local-main", "local-docs", "remote-main@central", "remote-docs@central"])
        XCTAssertEqual(vs.last?.engineId, "central")
        XCTAssertEqual(vs.last?.engineName, "Company")
        XCTAssertNil(vs.first?.engineId)
        XCTAssertEqual(vs.last?.role, "reader")
        XCTAssertTrue(vs.last!.isReadOnly)
        XCTAssertTrue(router.unreachable.isEmpty)
    }

    func testADeadRemoteLeavesTheLocalListIntact() async throws {
        let (router, _, _) = make(remoteDown: true)
        let vs = try await router.vaults().vaults
        XCTAssertEqual(vs.map(\.id), ["local-main", "local-docs"])
        XCTAssertEqual(router.unreachable, ["central"])
    }

    func testActiveVaultKeyRoutesCallsToThatEngine() async throws {
        let (router, local, remote) = make()
        router.setActiveVault("remote-docs@central")
        XCTAssertEqual(router.activeVault, "remote-docs@central")
        _ = try await router.tree()
        _ = try await router.writeFile(path: "n.md", content: "x", expectedRevision: nil)
        XCTAssertEqual(remote.served, ["tree@remote-docs", "write:n.md@remote-docs"], "the remote sees the BARE vault id")
        XCTAssertTrue(local.served.isEmpty)

        router.setActiveVault(nil)          // the local default
        _ = try await router.tree()
        XCTAssertEqual(local.served, ["tree@nil"])
        router.setActiveVault("local-docs")
        _ = try await router.tree()
        XCTAssertEqual(local.served.last, "tree@local-docs")
    }

    func testExplicitVaultOverloadsRouteByKey() async throws {
        let (router, local, remote) = make()
        router.setActiveVault(nil)
        _ = try await router.writeFile(path: "a.md", content: "x", expectedRevision: nil, inVault: "remote-main@central")
        XCTAssertEqual(remote.served.last, "write:a.md@remote-main")
        XCTAssertTrue(local.served.isEmpty)
    }

    func testLifecycleAlwaysHitsTheLocalEngine() async throws {
        let (router, local, remote) = make()
        router.setActiveVault("remote-main@central")
        _ = try await router.health()
        XCTAssertEqual(local.served, ["health"])
        XCTAssertFalse(remote.served.contains("health"))
        _ = try await router.me(profileId: "central")
        XCTAssertEqual(remote.served.last, "me")
    }

    func testEventsAreMergedAndRemoteOnesRekeyed() async throws {
        let (router, _, _) = make()
        _ = try await router.vaults()   // learns the remote's default vault for untagged events
        var seen: [String] = []
        for try await e in router.events() { seen.append("\(e.data.commit ?? "?")|\(e.data.vault ?? "nil")") }
        XCTAssertEqual(Set(seen), ["c-local|local-main", "c-remote|remote-main@central"])
    }

    func testUnknownProfileFallsBackToLocal() async throws {
        let (router, local, _) = make()
        router.setActiveVault("x@ghost")
        _ = try await router.tree()
        XCTAssertEqual(local.served, ["tree@nil"], "a vanished profile must not strand the app")
    }
}
