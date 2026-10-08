import XCTest
@testable import Svod

/// Contract 0.36.0: a sync conflict can be settled without content — keep mine, or accept the
/// incoming version (a quarantined one only with the explicit secrets acknowledgement).
final class SettleConflictTests: XCTestCase {

    private func client() -> LiveSvodClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [SettleStub.self]
        return LiveSvodClient(baseURL: URL(string: "http://127.0.0.1:7619")!, session: URLSession(configuration: cfg))
    }

    private func sentJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(SettleStub.lastBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAcceptIncomingSendsResolutionAndAcknowledgement() async throws {
        SettleStub.respond(200, #"{"path":"leak.md","resolution":"acceptIncoming","remainingConflicts":0}"#)
        let r = try await client().settleConflict(path: "leak.md", resolution: .acceptIncoming, acknowledgeSecrets: true)

        let req = try XCTUnwrap(SettleStub.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/api/v1/conflicts/resolve")
        let body = try sentJSON()
        XCTAssertEqual(body["path"] as? String, "leak.md")
        XCTAssertEqual(body["resolution"] as? String, "acceptIncoming")
        XCTAssertEqual(body["acknowledgeSecrets"] as? Bool, true)
        XCTAssertNil(body["content"], "no content travels with keepMine/acceptIncoming")
        XCTAssertEqual(r, SettleConflictResult(path: "leak.md", resolution: "acceptIncoming", remainingConflicts: 0))
    }

    func testKeepMineSendsNoAcknowledgement() async throws {
        SettleStub.respond(200, #"{"path":"a.md","resolution":"keepMine","remainingConflicts":2}"#)
        _ = try await client().settleConflict(path: "a.md", resolution: .keepMine, acknowledgeSecrets: false)
        let body = try sentJSON()
        XCTAssertEqual(body["resolution"] as? String, "keepMine")
        XCTAssertEqual(body["acknowledgeSecrets"] as? Bool, false)
    }

    func testQuarantinedFlagDecodesAndIsOptional() throws {
        let json = #"{"conflicts":[{"path":"leak.md","reasons":["incoming file quarantined"],"theirs":"x","ts":1,"quarantined":true},{"path":"b.md"}]}"#
        let c = try JSONDecoder().decode(Conflicts.self, from: Data(json.utf8))
        XCTAssertEqual(c.conflicts[0].quarantined, true)
        XCTAssertNil(c.conflicts[1].quarantined, "an engine older than 0.36.0 does not send it")
    }

    @MainActor
    func testListModelSurfacesARefusedAcceptAndKeepsTheItem() async throws {
        SettleStub.respond(422, #"{"error":"secrets_detected","message":"the incoming version contains secret(s): private-key (line 4)"}"#)
        let model = ConflictsListModel(client: client())
        model.items = [Conflicts.Item(path: "leak.md", quarantined: true)]
        let ok = await model.settle(path: "leak.md", resolution: .acceptIncoming, acknowledgeSecrets: false)
        XCTAssertFalse(ok)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.items.map(\.path), ["leak.md"])
    }
}

private final class SettleStub: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    static func respond(_ status: Int, _ json: String) {
        self.status = status; body = Data(json.utf8); lastRequest = nil; lastBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        // URLSession hands the body to a URLProtocol as a stream, not httpBody.
        if let data = request.httpBody {
            Self.lastBody = data
        } else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            Self.lastBody = data
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
