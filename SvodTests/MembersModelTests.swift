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

    func testSlugFoldsCyrillicNames() {
        XCTAssertEqual(MemberDraft.slug("Мария Петрова"), "maria-petrova")
        XCTAssertEqual(MemberDraft.slug("  Ivan  "), "ivan")
        XCTAssertEqual(MemberDraft.slug("!!!"), "member")
    }
}
