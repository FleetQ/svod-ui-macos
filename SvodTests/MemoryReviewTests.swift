import XCTest
@testable import Svod

/// The memory review queue (contract 0.33.0): what the model does with the rows it acts on,
/// how it recovers when the engine refuses, and that older engines neither break decoding nor
/// show the section. No model here touches UserDefaults.
@MainActor
final class MemoryReviewTests: XCTestCase {

    /// Records every review call and can fail the next one.
    final class ReviewMock: MockSvodClient, @unchecked Sendable {
        var calls: [String] = []
        var failNext: SvodClientError?
        var listCalls = 0

        override func memoryReview(limit: Int?) async throws -> MemoryReviewList {
            listCalls += 1
            return try await super.memoryReview(limit: limit)
        }
        override func reviewMemory(path: String, action: MemoryReviewVerb, expectedRevision: String?) async throws -> MemoryReviewResult {
            calls.append("\(action.rawValue):\(path)@\(expectedRevision ?? "nil")")
            if let e = failNext { failNext = nil; throw e }
            return try await super.reviewMemory(path: path, action: action, expectedRevision: expectedRevision)
        }
    }

    // MARK: U1

    func testLoadApproveAndUndo() async throws {
        let mock = ReviewMock()
        let model = MemoryReviewModel(client: mock)
        var changes = 0
        model.onChange = { changes += 1 }

        await model.load()
        XCTAssertEqual(model.total, 2)
        XCTAssertEqual(model.items.map(\.path), ["memory/policies/no-session-links.md", "memory/facts/engine-port.md"],
                       "needs-review / contradicting memories come first")

        let item = model.items[1]
        await model.approve(item)
        XCTAssertEqual(mock.calls, ["approve:memory/facts/engine-port.md@m1"])
        XCTAssertFalse(model.items.contains { $0.path == item.path })
        XCTAssertEqual(model.total, 1)
        XCTAssertEqual(model.acted.map(\.item.path), [item.path])
        XCTAssertEqual(model.acted.first?.previousStatus, "provisional")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(changes, 1)

        let entry = try XCTUnwrap(model.acted.first)
        await model.undo(entry)
        XCTAssertEqual(mock.calls.last, "reopen:memory/facts/engine-port.md@\(entry.revision)",
                       "undo must reopen against the revision the approval wrote")
        XCTAssertTrue(model.acted.isEmpty)
        XCTAssertEqual(model.total, 2)
        let restored = try XCTUnwrap(model.items.first { $0.path == item.path })
        XCTAssertEqual(restored.status, "provisional")
        XCTAssertNotEqual(restored.revision, item.revision, "a second action needs the reopened revision")
        XCTAssertEqual(changes, 2)
    }

    func testDeclineRecordsTheAction() async throws {
        let mock = ReviewMock()
        let model = MemoryReviewModel(client: mock)
        await model.load()
        await model.decline(model.items[0])
        XCTAssertEqual(model.acted.first?.action, .decline)
        await model.load()
        XCTAssertEqual(model.total, 1, "a declined memory must not come back on reload")
    }

    // MARK: U2

    func testFailedApproveRestoresTheRowAndReportsIt() async throws {
        let mock = ReviewMock()
        let model = MemoryReviewModel(client: mock)
        await model.load()
        let before = model.items
        mock.failNext = .http(status: 500, message: "boom")

        await model.approve(before[0])

        XCTAssertEqual(model.items, before, "the row goes back where it was")
        XCTAssertEqual(model.total, 2)
        XCTAssertTrue(model.acted.isEmpty)
        XCTAssertEqual(model.errorMessage, "boom")
        XCTAssertEqual(mock.listCalls, 1, "an ordinary failure does not reload")
    }

    func testConflictReloadsTheQueue() async throws {
        let mock = ReviewMock()
        let model = MemoryReviewModel(client: mock)
        await model.load()
        mock.failNext = .conflict(ConflictBody(path: model.items[0].path, expected: "m2", current: "m9"))

        await model.approve(model.items[0])

        XCTAssertEqual(mock.listCalls, 2, "409 must reload")
        XCTAssertEqual(model.total, 2)
        XCTAssertNotNil(model.errorMessage)
    }

    func testSupersededCarriesTheEnginesMessage() async throws {
        let mock = ReviewMock()
        let model = MemoryReviewModel(client: mock)
        await model.load()
        mock.failNext = .http(status: 409, message: "This memory was superseded.")

        await model.approve(model.items[0])

        XCTAssertEqual(mock.listCalls, 2)
        XCTAssertEqual(model.errorMessage, "This memory was superseded. The list was reloaded.")
    }

    // MARK: U3

    func testDashboardDecodesWithAndWithoutAwaitingReview() throws {
        let old = try JSONDecoder().decode(MemoryDashboard.self, from: Data("""
        {"sessionsCaptured":3,"sessionsDistilled":1,"notesWritten":2,"capturedBytes":10,
         "distilledBytes":1,"compressionRatio":10.0,"openProposals":0}
        """.utf8))
        XCTAssertNil(old.awaitingReview, "an older engine cannot count; nil, not 0")
        XCTAssertEqual(old.sessionsCaptured, 3)

        let new = try JSONDecoder().decode(MemoryDashboard.self, from: Data("""
        {"sessionsCaptured":3,"sessionsDistilled":1,"notesWritten":2,"capturedBytes":10,
         "distilledBytes":1,"compressionRatio":10.0,"openProposals":0,"awaitingReview":98}
        """.utf8))
        XCTAssertEqual(new.awaitingReview, 98)
    }

    func testReviewListDecodesTheWireShape() throws {
        let list = try JSONDecoder().decode(MemoryReviewList.self, from: Data("""
        {"total":7,"items":[{"path":"memory/факти/порт.md","title":"Порт","excerpt":"…","type":"fact",
          "status":"provisional","confidence":0.7,"created":"2026-09-17T08:00:00Z",
          "contradicts":"memory/a.md","needsReview":true,"revision":"abc"},
          {"path":"memory/b.md","title":"B","excerpt":"","needsReview":false,"revision":"def"}]}
        """.utf8))
        XCTAssertEqual(list.total, 7)
        XCTAssertEqual(list.items.first?.path, "memory/факти/порт.md")
        XCTAssertEqual(list.items.first?.contradicts, "memory/a.md")
        XCTAssertTrue(list.items[0].needsReview)
        XCTAssertNil(list.items[1].type)
        XCTAssertNil(list.items[1].supersedes)
    }

    func testReviewRequestEncodesTheAgreedKeys() throws {
        let data = try JSONEncoder().encode(MemoryReviewRequest(path: "memory/a.md", action: .decline, expectedRevision: "r1"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json, ["path": "memory/a.md", "action": "decline", "expectedRevision": "r1"])
    }

    // MARK: U4

    func testRouterSendsReviewToTheActiveVaultsEngine() async throws {
        let local = ReviewMock()
        let remote = ReviewMock()
        let router = MultiEngineClient(local: local, remotes: [.init(id: "central", name: "Company", client: remote)])

        router.setActiveVault("team@central")
        _ = try await router.memoryReview(limit: 5)
        try await router.reviewMemory(path: "memory/facts/engine-port.md", action: .approve, expectedRevision: nil)
        XCTAssertEqual(remote.listCalls, 1)
        XCTAssertEqual(remote.calls, ["approve:memory/facts/engine-port.md@nil"])
        XCTAssertEqual(remote.activeVault, "team", "the remote engine is addressed with the bare vault id")
        XCTAssertEqual(local.listCalls, 0)
        XCTAssertTrue(local.calls.isEmpty)

        router.setActiveVault("personal")
        _ = try await router.memoryReview(limit: nil)
        XCTAssertEqual(local.listCalls, 1)
        XCTAssertEqual(local.activeVault, "personal")
    }

    // MARK: U5

    func testReviewIsGatedOnContract0_33() {
        let engine = EngineModel(client: MockSvodClient())
        XCTAssertFalse(engine.supportsMemoryReview, "unknown engine ⇒ hidden")
        engine.settings = Self.settings("0.32.0")
        XCTAssertFalse(engine.supportsMemoryReview)
        engine.settings = Self.settings("0.33.0")
        XCTAssertTrue(engine.supportsMemoryReview)
        engine.settings = Self.settings("1.0.0")
        XCTAssertTrue(engine.supportsMemoryReview)
    }

    private static func settings(_ apiVersion: String) -> Settings {
        Settings(vaultPath: "/tmp/v", apiVersion: apiVersion, embedderProvider: "none", embedderModel: nil,
                 embedderDim: nil, host: "127.0.0.1")
    }
}
