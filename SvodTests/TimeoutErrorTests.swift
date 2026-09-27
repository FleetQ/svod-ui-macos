import XCTest
@testable import Svod

/// A request that timed out against an engine that is up (a long sync of a big vault) used to be
/// reported as "The Svod engine is not reachable." and treated as engine-down.
final class TimeoutErrorTests: XCTestCase {
    func testTimeoutIsNotOffline() {
        let e = LiveSvodClient.clientError(for: URLError(.timedOut))
        XCTAssertTrue(e.isTimedOut)
        XCTAssertFalse(e.isOffline)
        XCTAssertNotEqual(e.errorDescription, SvodClientError.offline.errorDescription)
    }

    func testConnectionFailuresStayOffline() {
        for code in [URLError.Code.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet] {
            let e = LiveSvodClient.clientError(for: URLError(code))
            XCTAssertTrue(e.isOffline, "\(code)")
            XCTAssertFalse(e.isTimedOut, "\(code)")
        }
    }

    /// The whole path: `syncNow` over a session whose request times out.
    func testSyncNowTimeoutSurfacesAsTimedOut() async {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FailingProtocol.self]
        FailingProtocol.code = .timedOut
        let client = LiveSvodClient(baseURL: URL(string: "http://127.0.0.1:7619")!, session: URLSession(configuration: cfg))
        do {
            _ = try await client.syncNow(vault: "personal")
            XCTFail("expected a timeout")
        } catch let e as SvodClientError {
            XCTAssertTrue(e.isTimedOut, "\(e)")
        } catch {
            XCTFail("unexpected \(error)")
        }

        FailingProtocol.code = .cannotConnectToHost
        do {
            _ = try await client.syncNow(vault: "personal")
            XCTFail("expected offline")
        } catch let e as SvodClientError {
            XCTAssertTrue(e.isOffline, "\(e)")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private final class FailingProtocol: URLProtocol {
    nonisolated(unsafe) static var code: URLError.Code = .timedOut
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(Self.code)) }
    override func stopLoading() {}
}
