import XCTest
@testable import Svod

/// `<vault>@<profile>` for a central engine's vault; a bare id for the local engine.
final class VaultKeyTests: XCTestCase {

    func testMakeAndParseRoundTrip() {
        XCTAssertEqual(VaultKey.make("socialscore", profileId: "central"), "socialscore@central")
        let (v, p) = VaultKey.parse("socialscore@central")
        XCTAssertEqual(v, "socialscore"); XCTAssertEqual(p, "central")
        XCTAssertTrue(VaultKey.isRemote("socialscore@central"))
    }

    func testBareIdStaysLocal() {
        XCTAssertEqual(VaultKey.make("personal", profileId: nil), "personal")
        let (v, p) = VaultKey.parse("personal")
        XCTAssertEqual(v, "personal"); XCTAssertNil(p)
        XCTAssertFalse(VaultKey.isRemote("personal"))
        XCTAssertNil(VaultKey.parse(nil).vaultId)
    }

    func testLastSeparatorWins() {
        let (v, p) = VaultKey.parse("a@b@c")
        XCTAssertEqual(v, "a@b"); XCTAssertEqual(p, "c")
    }

    func testDoesNotBreakGlobalNoteRefs() {
        // GlobalNoteRef splits on the FIRST ':' — an '@' in the vault part must be left alone.
        let ref = GlobalNoteRef(globalId: "socialscore@central:notes/x.md")
        XCTAssertEqual(ref?.vault, "socialscore@central")
        XCTAssertEqual(ref?.path, "notes/x.md")
    }
}
