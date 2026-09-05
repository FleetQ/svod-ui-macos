import XCTest
@testable import Svod

/// A central engine is added over https only; plain http is for a loopback engine.
final class EngineAddressTests: XCTestCase {
    func testHttpsIsAccepted() {
        XCTAssertEqual(EngineAddress.parse("https://svod.example.com")?.absoluteString, "https://svod.example.com")
        XCTAssertEqual(EngineAddress.parse("  https://svod.example.com/svod  ")?.path, "/svod")
    }
    func testPlainHttpOnlyForLoopback() {
        XCTAssertNil(EngineAddress.parse("http://svod.example.com"), "a key over plain HTTP to a remote host")
        XCTAssertNil(EngineAddress.parse("http://10.0.0.5:7517"), "LAN is not loopback")
        XCTAssertNotNil(EngineAddress.parse("http://127.0.0.1:7517"))
        XCTAssertNotNil(EngineAddress.parse("http://localhost:1"))
        XCTAssertNotNil(EngineAddress.parse("http://[::1]:7517"))
    }
    func testGarbageIsRejected() {
        XCTAssertNil(EngineAddress.parse(""))
        XCTAssertNil(EngineAddress.parse("svod.example.com"))
        XCTAssertNil(EngineAddress.parse("ftp://svod.example.com"))
        XCTAssertNil(EngineAddress.parse("https://"))
    }
}
