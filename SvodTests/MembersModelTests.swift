import XCTest
@testable import Svod

/// The key is surfaced exactly once (create / rotate) and never sits in the member list.
@MainActor
final class MembersModelTests: XCTestCase {

    final class AdminMock: MockSvodClient, @unchecked Sendable {
        override func me() async throws -> Me { Me(userId: "boss", name: "Boss", admin: true, local: false) }
    }

    func testCreateRevealsTheKeyOnceAndListsWithoutIt() async {
        let m = MembersModel(client: AdminMock())
        await m.load()
        XCTAssertTrue(m.isAdmin)
        let id = "t-\(UUID().uuidString.prefix(6).lowercased())"
        await m.create(CreateUserRequest(userId: id, name: "Temp", grants: [VaultGrant(vault: "notes", role: "reader")]))
        let reveal = m.revealedKey
        XCTAssertNotNil(reveal)
        XCTAssertTrue(reveal?.key.hasPrefix("svk_") == true)
        XCTAssertFalse(reveal?.rotated ?? true)
        XCTAssertTrue(m.users.contains { $0.userId == id })
        XCTAssertFalse(m.users.description.contains(reveal!.key), "the list must not carry the key")
        m.revealedKey = nil
        XCTAssertNil(m.revealedKey)
        await m.revoke(m.users.first { $0.userId == id }!)
        XCTAssertFalse(m.users.contains { $0.userId == id })
    }

    func testRotateRevealsANewKey() async {
        let m = MembersModel(client: AdminMock())
        await m.load()
        guard let u = m.users.first else { return XCTFail("mock has no users") }
        await m.rotate(u)
        XCTAssertEqual(m.revealedKey?.userId, u.userId)
        XCTAssertTrue(m.revealedKey?.rotated == true)
    }

    /// A member on a central engine who is not an admin: /users is never even asked for.
    final class ReaderMock: MockSvodClient, @unchecked Sendable {
        override func me() async throws -> Me { Me(userId: "ivan", name: "Иван", admin: false, local: false, grants: []) }
        override func users() async throws -> UsersInfo { XCTFail("a non-admin must not call /users"); throw SvodClientError.http(status: 403, message: "forbidden") }
    }

    func testNonAdminSeesOnlyThemselves() async {
        let m = MembersModel(client: ReaderMock())
        await m.load()
        XCTAssertEqual(m.me?.userId, "ivan")
        XCTAssertFalse(m.isAdmin)
        XCTAssertTrue(m.users.isEmpty)
        XCTAssertFalse(m.unavailable)
        XCTAssertNil(m.statusMsg)
    }

    func testLocalAdminLoadsTheList() async {
        let m = MembersModel(client: MockSvodClient())   // local admin ⇒ loads users
        await m.load()
        XCTAssertTrue(m.me?.local == true)
        XCTAssertTrue(m.isAdmin)
        XCTAssertFalse(m.users.isEmpty)
        XCTAssertFalse(m.unavailable)
    }

    func testTwoMocksDoNotShareMembers() async throws {
        let a = MockSvodClient(), b = MockSvodClient()
        _ = try await a.createUser(CreateUserRequest(userId: "only-in-a", name: "A"))
        let inA = try await a.users().users.contains { $0.userId == "only-in-a" }
        let inB = try await b.users().users.contains { $0.userId == "only-in-a" }
        XCTAssertTrue(inA)
        XCTAssertFalse(inB, "mock state must be per instance, or tests depend on order")
    }

    func testLastSeenHandlesMissingAndPresentValues() {
        XCTAssertEqual(MembersModel.lastSeen(nil), "never used")
        XCTAssertNil(UserInfo(userId: "x", name: "x", lastUsedAt: "not a date").lastUsedDate)
        let now = Date(timeIntervalSince1970: 1_757_070_000)
        let twoHoursAgo = UserInfo(userId: "x", name: "x", lastUsedAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200))).lastUsedDate
        XCTAssertTrue(MembersModel.lastSeen(twoHoursAgo, now: now).hasPrefix("last seen "), MembersModel.lastSeen(twoHoursAgo, now: now))
        let engineFormat = UserInfo(userId: "x", name: "x", lastUsedAt: "2026-09-05T14:33:06.166Z").lastUsedDate
        XCTAssertNotNil(engineFormat, "fractional seconds (the engine's format)")
        XCTAssertTrue(MembersModel.lastSeen(engineFormat, now: now).hasPrefix("last seen "))
    }

    func testLastSeenIsHiddenUntilTheEngineReportsIt() async {
        let m = MembersModel(client: MockSvodClient())   // the mock's users carry no lastUsedAt (a 0.30 engine)
        await m.load()
        XCTAssertFalse(m.reportsLastUsed, "'never used' for everyone would be a lie on an engine that does not report it")
    }

    func testSlugFoldsCyrillicNames() {
        XCTAssertEqual(MemberDraft.slug("Мария Петрова"), "maria-petrova")
        XCTAssertEqual(MemberDraft.slug("  Ivan  "), "ivan")
        XCTAssertEqual(MemberDraft.slug("!!!"), "member")
    }
}
