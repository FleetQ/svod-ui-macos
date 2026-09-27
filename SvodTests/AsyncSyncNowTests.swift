import XCTest
@testable import Svod

/// "Sync now" with the async mode of contract 0.35.0: the request, both answer shapes (a 0.35.0
/// engine's 202 and an older engine's blocking SyncAck), the status read, router routing, and the
/// run that follows the cycle through events or polling.
final class AsyncSyncNowTests: XCTestCase {

    private func client() -> LiveSvodClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return LiveSvodClient(baseURL: URL(string: "http://127.0.0.1:7619")!, session: URLSession(configuration: cfg))
    }

    // MARK: client call + decoding

    func testSyncNowSendsTheAsyncOptInAndDecodesAccepted() async throws {
        StubProtocol.respond(202, #"{"vault":"personal","synced":true,"running":true,"trigger":"manual","startedAt":"2026-09-27T10:00:00Z","phase":"fetch","pending":false,"syncStatus":"syncing","conflicts":0}"#)
        let result = try await client().syncNow(vault: "personal")

        let req = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/sync/now")
        let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(q.contains(URLQueryItem(name: "wait", value: "false")), "\(q)")
        XCTAssertTrue(q.contains(URLQueryItem(name: "vault", value: "personal")), "\(q)")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Prefer"), "respond-async")
        // An older engine ignores the opt-in and blocks, so the long timeout must stay.
        XCTAssertEqual(req.timeoutInterval, 180)

        guard case .started(let s) = result else { return XCTFail("expected .started, got \(result)") }
        XCTAssertEqual(s.vault, "personal")
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.trigger, "manual")
        XCTAssertEqual(s.phase, "fetch")
        XCTAssertEqual(s.syncStatus, "syncing")
    }

    /// An engine older than 0.35.0 holds the request and answers the old SyncAck.
    func testOldEngineBlockingAnswerDecodesAsFinished() async throws {
        StubProtocol.respond(200, #"{"ok":true,"head":"abc123","conflicts":2}"#)
        let result = try await client().syncNow(vault: nil)
        XCTAssertEqual(result, .finished(SyncAck(ok: true, head: "abc123", conflicts: 2)))
    }

    /// 0.35.0 answers a vault without two-way sync with SyncAck ok=false even in async mode.
    func testNotSyncedVaultInAsyncModeDecodesAsFinished() async throws {
        StubProtocol.respond(200, #"{"ok":false,"head":"abc123","conflicts":0}"#)
        let result = try await client().syncNow(vault: "v")
        XCTAssertEqual(result, .finished(SyncAck(ok: false, head: "abc123", conflicts: 0)))
    }

    /// Null fields are omitted on the wire (explicitNulls=false).
    func testSyncStatusReadsTheStatusEndpoint() async throws {
        StubProtocol.respond(200, #"{"vault":"v","synced":true,"running":false,"pending":false,"syncStatus":"conflicts","head":"def","conflicts":3,"lastSyncedAt":"2026-09-27T10:01:00Z"}"#)
        let s = try await client().syncStatus(vault: "v")
        let req = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.path, "/api/v1/sync/status")
        XCTAssertEqual(req.url?.query, "vault=v")
        XCTAssertFalse(s.running)
        XCTAssertNil(s.trigger)
        XCTAssertNil(s.phase)
        XCTAssertEqual(s.syncStatus, "conflicts")
        XCTAssertEqual(s.conflicts, 3)
    }

    func testSyncStatusOnOldEngineIsNotFound() async {
        StubProtocol.respond(404, #"{"error":"not_found","message":"no such route"}"#)
        do { _ = try await client().syncStatus(vault: "v"); XCTFail("expected notFound") }
        catch let e as SvodClientError { if case .notFound = e {} else { XCTFail("\(e)") } }
        catch { XCTFail("\(error)") }
    }

    func testSyncFinishedEventDecodes() throws {
        let json = #"{"type":"sync.finished","ts":1,"data":{"vault":"v","trigger":"manual","status":"conflicts","head":"abc","conflicts":2,"durationMs":1200,"pending":true}}"#
        let e = try JSONDecoder().decode(SvodEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.type, .syncFinished)
        XCTAssertEqual(e.data.status, "conflicts")
        XCTAssertEqual(e.data.conflicts, 2)
        XCTAssertEqual(e.data.trigger, "manual")
        XCTAssertEqual(e.data.pending, true)
        let p = try JSONDecoder().decode(SvodEvent.self, from: Data(#"{"type":"sync.progress","ts":1,"data":{"vault":"v","phase":"push"}}"#.utf8))
        XCTAssertEqual(p.type, .syncProgress)
        XCTAssertEqual(p.data.phase, "push")
    }

    // MARK: router

    func testRouterSendsARemoteVaultToItsEngineWithTheBareId() async throws {
        let local = RecordingMock(), remote = RecordingMock()
        let router = MultiEngineClient(local: local, remotes: [.init(id: "central", name: "Company", client: remote)])
        _ = try await router.syncNow(vault: VaultKey.make("docs", profileId: "central"))
        _ = try await router.syncStatus(vault: VaultKey.make("docs", profileId: "central"))
        _ = try await router.syncNow(vault: "personal")
        XCTAssertEqual(remote.calls, ["syncNow@docs", "syncStatus@docs"])
        XCTAssertEqual(local.calls, ["syncNow@personal"])
    }

    // MARK: the followed run

    private func status(running: Bool, trigger: String? = "manual", phase: String? = nil,
                        syncStatus: String? = nil, conflicts: Int = 0) -> SyncRunStatus {
        SyncRunStatus(vault: "v", running: running, trigger: trigger, phase: phase, syncStatus: syncStatus, conflicts: conflicts)
    }
    private func event(_ type: EventType, vault: String? = "v", trigger: String? = "manual", phase: String? = nil,
                       status: String? = nil, conflicts: Int? = nil) -> SvodEvent {
        var p = EventPayload(vault: vault)
        p.trigger = trigger; p.phase = phase; p.status = status; p.conflicts = conflicts
        return SvodEvent(type: type, ts: 1, data: p)
    }

    func testStartedRunFollowsProgressAndFinishesOnTheEvent() {
        var run = SyncRun(vault: "v", accepted: status(running: true, syncStatus: "syncing"), wasRunning: false)
        XCTAssertFalse(run.joined)
        XCTAssertEqual(run.progressLabel, "Syncing")
        run.apply(event(.syncProgress, phase: "fetch"))
        XCTAssertEqual(run.progressLabel, "Syncing · fetching")
        XCTAssertNil(run.resultText)
        run.apply(event(.syncFinished, status: "inSync", conflicts: 0))
        XCTAssertEqual(run.outcome, .synced)
        XCTAssertEqual(run.resultText, "Synced")
    }

    func testConflictsAndFailuresAreReported() {
        var c = SyncRun(vault: "v", accepted: status(running: true), wasRunning: false)
        c.apply(event(.syncFinished, status: "conflicts", conflicts: 2))
        XCTAssertEqual(c.outcome, .conflicts(2))
        XCTAssertEqual(c.resultText, "Synced · 2 conflicts to resolve")

        for s in ["offline", "error"] {
            var f = SyncRun(vault: "v", accepted: status(running: true), wasRunning: false)
            f.apply(event(.syncFinished, status: s, conflicts: 0))
            guard case .failed = f.outcome else { return XCTFail("\(s): \(String(describing: f.outcome))") }
            XCTAssertTrue(f.resultText?.hasPrefix("Sync failed") == true, s)
        }
    }

    func testJoinedWhenTheRunningCycleHasAnotherTriggerOrWasAlreadyRunning() {
        let byTrigger = SyncRun(vault: "v", accepted: status(running: true, trigger: "on-change", phase: "push"), wasRunning: false)
        XCTAssertTrue(byTrigger.joined)
        XCTAssertEqual(byTrigger.progressLabel, "Joined the running sync · pushing")

        var byStatus = SyncRun(vault: "v", accepted: status(running: true, trigger: "manual"), wasRunning: true)
        XCTAssertTrue(byStatus.joined)
        byStatus.apply(event(.syncFinished, status: "inSync"))
        XCTAssertEqual(byStatus.resultText, "Synced (joined a sync that was already running)")
    }

    func testAnAlreadyFinishedAnswerNeedsNoWaiting() {
        let run = SyncRun(vault: "v", accepted: status(running: false, trigger: nil, syncStatus: "inSync"), wasRunning: false)
        XCTAssertTrue(run.isFinished)
        XCTAssertEqual(run.outcome, .synced)
    }

    func testEventsOfAnotherVaultOrAnotherCycleAreIgnored() {
        var run = SyncRun(vault: "v", accepted: status(running: true), wasRunning: false)
        run.apply(event(.syncFinished, vault: "other", status: "error"))
        run.apply(event(.syncFinished, trigger: "poll", status: "error"))   // an older cycle's late event
        XCTAssertFalse(run.isFinished)
        run.apply(event(.syncFinished, status: "inSync"))
        XCTAssertEqual(run.outcome, .synced)
        // Nothing after the finish changes the result.
        run.apply(event(.syncFinished, status: "error"))
        XCTAssertEqual(run.outcome, .synced)
    }

    /// Without events, the status poll ends the run.
    func testPollingFinishesTheRun() {
        var run = SyncRun(vault: "v", accepted: status(running: true), wasRunning: false)
        run.apply(status(running: true, phase: "merge"))
        XCTAssertEqual(run.progressLabel, "Syncing · merging")
        run.apply(status(running: false, trigger: nil, syncStatus: "offline"))
        XCTAssertEqual(run.outcome, .failed("the remote could not be reached"))
    }
}

private final class RecordingMock: MockSvodClient, @unchecked Sendable {
    var calls: [String] = []
    override func syncNow(vault: String?) async throws -> SyncNowResult {
        calls.append("syncNow@\(vault ?? "nil")")
        return .started(SyncRunStatus(vault: vault ?? "", running: true, trigger: "manual"))
    }
    override func syncStatus(vault: String?) async throws -> SyncRunStatus {
        calls.append("syncStatus@\(vault ?? "nil")")
        return SyncRunStatus(vault: vault ?? "", running: false, syncStatus: "inSync")
    }
}

private final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func respond(_ status: Int, _ json: String) {
        self.status = status; body = Data(json.utf8); lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
