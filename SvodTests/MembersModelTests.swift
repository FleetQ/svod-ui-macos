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

    func testNonAdminSeesOnlyThemselves() async {
        let m = MembersModel(client: MockSvodClient())   // local admin ⇒ loads users
        await m.load()
        XCTAssertTrue(m.me?.local == true)
        XCTAssertFalse(m.unavailable)
    }

    func testSlugFoldsCyrillicNames() {
        XCTAssertEqual(MemberDraft.slug("Мария Петрова"), "maria-petrova")
        XCTAssertEqual(MemberDraft.slug("  Ivan  "), "ivan")
        XCTAssertEqual(MemberDraft.slug("!!!"), "member")
    }
}
