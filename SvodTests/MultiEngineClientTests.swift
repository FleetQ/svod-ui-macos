import XCTest
@testable import Svod

/// The router: a vault key picks the engine; vault lists merge; one dead remote never hides the local engine.
final class MultiEngineClientTests: XCTestCase {

    /// A mock that knows which engine it is: distinct vault ids, records what it served.
    final class EngineMock: MockSvodClient, @unchecked Sendable {
        let tag: String
        let down: Bool
        var served: [String] = []
        /// A live socket never ends; the mock's does at once unless a test keeps it open.
        var eventsStayOpen = false
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
        override func updateCheck() async throws -> UpdateCheck { served.append("updateCheck"); return try await super.updateCheck() }
        override func updateApply() async throws -> UpdateApply { served.append("updateApply"); return try await super.updateApply() }
        override func deleteVault(id: String, deleteFiles: Bool) async throws -> DeleteVaultResult { served.append("delete@\(id)"); return try await super.deleteVault(id: id, deleteFiles: deleteFiles) }
        override func me() async throws -> Me { served.append("me"); return Me(userId: tag, name: tag, admin: false, local: false) }
        override func events() -> AsyncThrowingStream<SvodEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(SvodEvent(type: .commitCreated, ts: 1, data: EventPayload(path: "\(tag).md", commit: "c-\(tag)", vault: nil)))   // UNTAGGED on both engines: the router must tag each with that engine's default
                if !eventsStayOpen { c.finish() }
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

    func testEngineSelfUpdateAlwaysTargetsThisMac() async throws {
        let (router, local, remote) = make()
        router.setActiveVault("remote-docs@central")
        _ = try await router.updateCheck()
        _ = try await router.updateApply()
        XCTAssertEqual(local.served, ["updateCheck", "updateApply"])
        XCTAssertTrue(remote.served.isEmpty, "a company vault being active must not update the company's engine")
    }

    func testLocalOnlyOperationsRefuseARemoteTarget() async throws {
        let (router, local, remote) = make()
        do { _ = try await router.deleteVault(id: "remote-docs@central", deleteFiles: false); XCTFail("must refuse") }
        catch let e as SvodClientError { XCTAssertTrue(e.isNotImplemented) }
        do { _ = try await router.importVault(source: "/tmp/x", into: nil, vault: "remote-docs@central", followSymlinks: false); XCTFail("must refuse") }
        catch let e as SvodClientError { XCTAssertTrue(e.isNotImplemented) }
        do { _ = try await router.registerSource(vault: "remote-docs@central", path: "/tmp/x", into: nil, followSymlinks: false, prune: false, autoSync: false, writeBack: false); XCTFail("must refuse") }
        catch let e as SvodClientError { XCTAssertTrue(e.isNotImplemented) }
        XCTAssertTrue(remote.served.isEmpty, "the remote engine was never asked")
        // …while the same calls for a LOCAL vault still go through.
        _ = try await router.deleteVault(id: "local-docs", deleteFiles: false)
        XCTAssertEqual(local.served, ["delete@local-docs"])
    }

    func testUntaggedLocalEventsAreTaggedWithTheLocalDefault() async throws {
        let (router, _, _) = make()
        _ = try await router.vaults()   // learns the defaults
        var seen: [String?] = []
        // The merged stream ends when the LOCAL stream ends (a live socket never does; the mock's
        // does at once), so the remote's event may or may not have arrived by then — the local one
        // always has: it is yielded before its own stream finishes.
        for try await e in router.events() { seen.append(e.data.vault) }
        XCTAssertTrue(seen.contains("local-main"), "untagged local event must name the local default vault: \(seen)")
        XCTAssertFalse(seen.contains(nil), "no event leaves the router untagged: \(seen)")
    }

    func testBasePathIsKeptInFrontOfEveryApiPath() {
        XCTAssertEqual(LiveSvodClient.basePath(of: URL(string: "http://127.0.0.1:7517")!), "")
        XCTAssertEqual(LiveSvodClient.basePath(of: URL(string: "https://svod.example.com/svod/")!), "/svod")
        XCTAssertEqual(LiveSvodClient.websocketURL(from: URL(string: "https://svod.example.com/svod")!).absoluteString, "wss://svod.example.com/svod/api/v1/events")
        XCTAssertEqual(LiveSvodClient.websocketURL(from: URL(string: "http://127.0.0.1:7517")!).absoluteString, "ws://127.0.0.1:7517/api/v1/events")
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
        let (router, local, _) = make()
        _ = try await router.vaults()   // learns each engine's default vault for untagged events
        // The merged stream closes when the LOCAL stream closes (never in production). Keep the
        // local mock open so the remote's event is guaranteed a chance to arrive; stop at two.
        local.eventsStayOpen = true
        var seen: [String] = []
        // Bounded: if remote delivery ever broke completely, the loop must fail, not hang the run.
        let collect = Task {
            for try await e in router.events() {
                seen.append("\(e.data.commit ?? "?")|\(e.data.vault ?? "nil")")
                if seen.count == 2 { break }
            }
        }
        let deadline = Task { try await Task.sleep(nanoseconds: 3_000_000_000); collect.cancel() }
        _ = try? await collect.value
        deadline.cancel()
        XCTAssertEqual(Set(seen), ["c-local|local-main", "c-remote|remote-main@central"], "both events within 3 s")
    }

    @MainActor func testAnInsecureSavedProfileIsNeverContacted() async throws {
        let defaults = UserDefaults(suiteName: "svod.tests.insecure.\(UUID().uuidString)")!
        let store = EngineProfileStore(defaults: defaults, secretsDir: FileManager.default.temporaryDirectory.appendingPathComponent("svod-insecure-\(UUID().uuidString)"))
        // Saved by 0.2.23, which only warned: a plain-http address to a remote host.
        _ = try store.add(EngineProfile(id: "old", name: "Old", baseURL: URL(string: "http://engine.company.example:7517")!), apiKey: "svk_leak")
        _ = try store.add(EngineProfile(id: "ok", name: "Ok", baseURL: URL(string: "https://svod.example.com")!), apiKey: "svk_fine")
        let router = MultiEngineClient(local: EngineMock(tag: "local"))
        router.configure(store: store)
        XCTAssertEqual(router.insecure, ["old"])
        router.setActiveVault("notes@old")
        do { _ = try await router.tree(); XCTFail("the insecure engine must not be contacted") }
        catch let e as SvodClientError { XCTAssertTrue(e.isOffline, "\(e)") }
    }

    @MainActor func testRemovingAnInsecureProfileClearsItsMark() async throws {
        let defaults = UserDefaults(suiteName: "svod.tests.insecure2.\(UUID().uuidString)")!
        let store = EngineProfileStore(defaults: defaults, secretsDir: FileManager.default.temporaryDirectory.appendingPathComponent("svod-insecure2-\(UUID().uuidString)"))
        _ = try store.add(EngineProfile(id: "old", name: "Old", baseURL: URL(string: "http://engine.company.example:7517")!), apiKey: "svk_leak")
        _ = try store.add(EngineProfile(id: "ok", name: "Ok", baseURL: URL(string: "https://svod.example.com")!), apiKey: "svk_fine")
        let router = MultiEngineClient(local: EngineMock(tag: "local"))
        router.configure(store: store)
        XCTAssertEqual(router.insecure, ["old"])
        store.remove("old")
        router.configure(store: store)
        XCTAssertTrue(router.insecure.isEmpty, "a removed profile is not 'insecure' any more: \(router.insecure)")
        XCTAssertEqual(router.remoteList.map(\.id), ["ok"])
    }

    func testVanishedProfileFailsClosedInsteadOfWritingLocally() async throws {
        let (router, local, _) = make()
        router.setActiveVault("remote-docs@central")
        router.configure(remotes: [])   // the profile was removed while this vault was active
        do { _ = try await router.tree(); XCTFail("must not answer from another engine") }
        catch let e as SvodClientError { XCTAssertTrue(e.isOffline, "\(e)") }
        do { _ = try await router.writeFile(path: "n.md", content: "x", expectedRevision: nil); XCTFail("must not write anywhere") }
        catch let e as SvodClientError { XCTAssertTrue(e.isOffline, "\(e)") }
        do { _ = try await router.writeFile(path: "n.md", content: "x", expectedRevision: nil, inVault: "remote-docs@central"); XCTFail("explicit vault, same rule") }
        catch let e as SvodClientError { XCTAssertTrue(e.isOffline, "\(e)") }
        XCTAssertTrue(local.served.isEmpty, "the local engine must never see traffic meant for the vanished engine: \(local.served)")
        // The app re-selects a vault that exists (VaultModel.load); from then on everything works.
        router.setActiveVault("local-main")
        _ = try await router.tree()
        XCTAssertEqual(local.served, ["tree@local-main"])
    }
}
