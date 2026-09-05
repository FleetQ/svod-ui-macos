import XCTest
@testable import Svod

/// The review inbox: which events count as an agent change, that the list survives a
/// relaunch, and that Revert refuses to clobber edits made after the agent's commit.
@MainActor
final class ActivityReviewTests: XCTestCase {

    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "svod.tests.activity.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func agentWrite(_ commit: String, path: String = "vault/a.md", tool: String? = "write",
                            type: EventType = .agentActivity) -> SvodEvent {
        SvodEvent(type: type, ts: 1_749_700_000_000,
                  data: .init(path: path, commit: commit, agentId: "friday", tool: tool))
    }

    private func model(_ client: MockSvodClient = MockSvodClient()) -> ActivityModel {
        ActivityModel(client: client, defaults: defaults)
    }

    // MARK: what lands in the inbox

    func testAgentWriteIsPendingOnceAcrossBothEventsOfTheSameCommit() {
        let m = model()
        m.ingest(agentWrite("c1"))
        // An MCP write surfaces as agent.activity AND commit.created for one commit.
        m.ingest(SvodEvent(type: .commitCreated, ts: 1, data: .init(path: "vault/a.md", commit: "c1",
                                                                     agentId: "friday", author: "friday")))
        XCTAssertEqual(m.pending.map(\.data.commit), ["c1"])
    }

    func testTheUsersOwnWriteIsNotPending() {
        let m = model()
        // App-API writes carry the UI author and no agentId.
        m.ingest(SvodEvent(type: .commitCreated, ts: 1, data: .init(path: "vault/a.md", commit: "c1",
                                                                     author: "Nikola", tool: "write")))
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testAWatcherCommitIsNotPending() {
        let m = model()
        m.ingest(SvodEvent(type: .commitCreated, ts: 1, data: .init(commit: "c1", author: "external")))
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testReviewIgnoresTheFeedTypeFilters() {
        let app = AppModel(client: MockSvodClient())
        let original = app.settings.showAgentActivity
        defer { app.settings.showAgentActivity = original }
        app.settings.showAgentActivity = false

        let m = model()
        m.app = app
        m.ingest(agentWrite("c1"))

        // Hiding a type from the live feed must not also hide the commit from review.
        XCTAssertTrue(m.feed.isEmpty)
        XCTAssertEqual(m.pending.count, 1)
    }

    // MARK: persistence

    func testPendingSurvivesARelaunch() {
        model().ingest(agentWrite("c1"))
        XCTAssertEqual(model().pending.map(\.data.commit), ["c1"])
    }

    func testMarkReviewedRemovesAndPersists() {
        let m = model()
        m.ingest(agentWrite("c1"))
        m.ingest(agentWrite("c2"))
        m.markReviewed(agentWrite("c1"))
        XCTAssertEqual(m.pending.map(\.data.commit), ["c2"])
        XCTAssertEqual(model().pending.map(\.data.commit), ["c2"])
        m.markAllReviewed()
        XCTAssertTrue(model().pending.isEmpty)
    }

    func testCapKeepsTheNewestTwoHundred() {
        let m = model()
        for i in 0..<201 { m.ingest(agentWrite("c\(i)")) }
        XCTAssertEqual(m.pending.count, 200)
        XCTAssertEqual(m.pending.first?.data.commit, "c200")
        XCTAssertEqual(m.pending.last?.data.commit, "c1")
        // The dropped commit can come back — its dedupe entry went with it.
        m.ingest(agentWrite("c0"))
        XCTAssertEqual(m.pending.first?.data.commit, "c0")
    }

    func testOnlySinglePathContentWritesAreRevertible() {
        XCTAssertTrue(ActivityModel.canRevert(agentWrite("c1", tool: "write")))
        XCTAssertTrue(ActivityModel.canRevert(agentWrite("c1", tool: "edit")))
        XCTAssertTrue(ActivityModel.canRevert(agentWrite("c1", tool: nil)))
        // Reviewable, but a single write-back cannot undo them: delete already trashed the
        // note; move/promote carry the DESTINATION path, whose parent copy is absent, so a
        // revert would trash the moved note; remember may write two files in one commit.
        for tool in ["delete", "move", "promote", "remember"] {
            XCTAssertTrue(ActivityModel.isReviewable(agentWrite("c1", tool: tool)), tool)
            XCTAssertFalse(ActivityModel.canRevert(agentWrite("c1", tool: tool)), tool)
        }
    }

    // MARK: revert

    func testRevertRefusesWhenTheFileMovedOn() async {
        let client = RecordingClient()
        client.head = "c9"   // someone (or another agent) wrote after c1
        let m = model(client)
        m.ingest(agentWrite("c1"))

        let outcome = await m.revert(agentWrite("c1"))

        XCTAssertEqual(outcome, .changedSince)
        XCTAssertTrue(client.writes.isEmpty, "a blind revert would drop the later edit too")
        XCTAssertEqual(m.pending.count, 1, "stays in the inbox for the user to look at in History")
    }

    func testRevertWritesTheParentContentAgainstTheCurrentRevision() async {
        let client = RecordingClient()
        let m = model(client)
        m.ingest(agentWrite("c1"))

        let outcome = await m.revert(agentWrite("c1"))

        XCTAssertEqual(outcome, .reverted)
        XCTAssertEqual(client.revisionsAsked, ["c1~1"])
        XCTAssertEqual(client.writes.count, 1)
        XCTAssertEqual(client.writes.first?.content, "before")
        XCTAssertEqual(client.writes.first?.expectedRevision, "r1")
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testRevertOfANoteTheAgentCreatedTrashesIt() async {
        let client = RecordingClient()
        client.parentError = .badRequest(nil)   // `<commit>~1` has no copy of the file
        let m = model(client)
        m.ingest(agentWrite("c1"))

        let outcome = await m.revert(agentWrite("c1"))

        XCTAssertEqual(outcome, .trashed)
        XCTAssertTrue(client.writes.isEmpty)
        XCTAssertEqual(client.deletes.map(\.expectedRevision), ["r1"])
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testRevertConflictSurfacesTheMergeSheetAndKeepsTheItem() async {
        let client = RecordingClient()
        client.writeError = .conflict(ConflictBody(path: "vault/a.md", expected: "r1", current: "r5",
                                                   currentContent: "theirs"))
        let app = AppModel(client: client)
        let m = model(client)
        m.app = app
        m.ingest(agentWrite("c1"))

        let outcome = await m.revert(agentWrite("c1"))

        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(app.activeConflict?.currentContent, "theirs")
        XCTAssertEqual(m.pending.count, 1)
    }
}

/// Scripts the five calls Revert makes and records the writes it issues.
private final class RecordingClient: MockSvodClient {
    var head = "c1"
    var parent = FileContent(path: "vault/a.md", revision: "r0", content: "before")
    var parentError: SvodClientError?
    var current = FileContent(path: "vault/a.md", revision: "r1", content: "after")
    var writeError: SvodClientError?

    var revisionsAsked: [String] = []
    var writes: [(path: String, content: String, expectedRevision: String?)] = []
    var deletes: [(path: String, expectedRevision: String?)] = []

    override func history(path: String, max: Int?) async throws -> [CommitInfo] {
        [CommitInfo(commit: head, author: "friday", email: "", epochSeconds: 0, message: "m")]
    }

    override func revision(path: String, revision: String) async throws -> FileContent {
        revisionsAsked.append(revision)
        if let parentError { throw parentError }
        return parent
    }

    override func readFile(path: String) async throws -> FileContent { current }

    @discardableResult
    override func writeFile(path: String, content: String, expectedRevision: String?) async throws -> WriteResult {
        writes.append((path, content, expectedRevision))
        if let writeError { throw writeError }
        return WriteResult(path: path, revision: "r2", commit: "c2")
    }

    @discardableResult
    override func deleteFile(path: String, expectedRevision: String?) async throws -> WriteResult {
        deletes.append((path, expectedRevision))
        return WriteResult(path: ".trash/\(path)", revision: "del", commit: "c3")
    }
}
