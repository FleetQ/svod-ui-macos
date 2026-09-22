import XCTest
@testable import Svod

/// `degraded` on a search result (contract 0.34.0): the engine says when it answered without semantic
/// search or without the reranker. The app must still decode results from an older engine, which does
/// not send the field, and must tell the person when a result is keyword-only.
@MainActor
final class SearchDegradedTests: XCTestCase {

    private func decode(_ json: String) throws -> SearchResult {
        try JSONDecoder().decode(SearchResult.self, from: Data(json.utf8))
    }

    private let hit = #"{"path":"a.md","heading":"A","snippet":"x","score":1.0,"matchedKeyword":true,"matchedSemantic":false,"tags":[]}"#

    func testAnEngineThatPredatesTheFieldDecodesAsComplete() throws {
        let r = try decode(#"{"mode":"HYBRID","hits":[\#(hit)]}"#)
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(r.degraded, [])
    }

    func testDegradedIsDecoded() throws {
        let r = try decode(#"{"mode":"HYBRID","hits":[\#(hit)],"degraded":["semantic","rerank"]}"#)
        XCTAssertEqual(r.degraded, ["semantic", "rerank"])
    }

    func testNoticeNamesWhatIsMissingAndIsNilWhenComplete() {
        let m = SearchModel(client: MockSvodClient())
        XCTAssertNil(m.degradedNotice)
        m.degraded = ["semantic"]
        XCTAssertEqual(m.degradedNotice, "Semantic search is unavailable — keyword results only.")
        m.degraded = ["rerank"]
        XCTAssertEqual(m.degradedNotice, "Reranking is unavailable — results are not reranked.")
        m.degraded = ["semantic", "rerank"]
        XCTAssertEqual(m.degradedNotice, "Semantic search and reranking are unavailable — keyword results only.")
        m.mode = .semantic
        m.degraded = ["semantic"]
        XCTAssertEqual(m.degradedNotice,
                       "Semantic search is unavailable — nothing to show in Semantic mode. Switch to Hybrid or Keyword.",
                       "a failed query embed in Semantic mode returns no hits")
        m.results = [SearchHit(path: "a.md", heading: "A", snippet: "x", score: 1, matchedKeyword: true,
                               matchedSemantic: false, tags: [])]
        XCTAssertEqual(m.degradedNotice, "Semantic search is unavailable — keyword results only.",
                       "during a model rebuild Semantic mode shows keyword hits; the notice must not say there are none")
        m.results = []
        m.mode = .hybrid
        m.degraded = ["something-new"]
        XCTAssertNil(m.degradedNotice, "an unknown value from a newer engine shows nothing rather than a wrong claim")
    }
}
