import XCTest
@testable import Svod

/// The engine-compatibility semantics the Теми pane branches on.
///
/// These are the first automated tests in this repo, and they exist because the logic they cover is
/// invisible: `newSinceBuild` returns **nil, not 0**, when the engine cannot answer, and the pane
/// renders those two cases differently — nil falls back to the old "остаряло" badge, 0 states
/// positively that nothing is missing. Nothing else in the app distinguishes them, and until now the
/// only check was reading the diff.
///
/// They also pin the harder requirement: the app must keep working against an engine older than the
/// contract it was built for. A non-optional field added carelessly to `GraphStatus` makes decoding
/// throw, and the pane silently empties against every older engine — the exact failure this repo has
/// hit before with 404-based feature detection.
final class GraphStatusCompatibilityTests: XCTestCase {

    private func decodeStatus(_ json: String) throws -> GraphStatus {
        try JSONDecoder().decode(GraphStatus.self, from: Data(json.utf8))
    }

    /// Verbatim shape of a contract-0.24.0 engine: no `incremental`, no counts.
    func testDecodesAStatusFromAnEngineThatPredatesTheseFields() throws {
        let status = try decodeStatus("""
        {"state":"READY","enabled":true,"stale":true,"head":"abc","currentHead":"def",
         "builtAt":1760000000000,"noteCount":3096,"edgeCount":8664,"linkEdgeCount":732,
         "simEdgeCount":7932,"communityCount":1921,"levelCount":3,"vectorCoverage":1.0,
         "summaryProvider":"ollama","summarisedCount":38}
        """)
        XCTAssertEqual(status.state, "READY")
        XCTAssertTrue(status.stale)
        XCTAssertNil(status.incremental)
        XCTAssertNil(
            status.newSinceBuild,
            "an engine that cannot count must leave the question unanswered, not answer zero"
        )
    }

    func testIncrementalOffMeansUnknownRatherThanNothingChanged() throws {
        let status = try decodeStatus("""
        {"state":"READY","enabled":true,"stale":true,"noteCount":10,"edgeCount":0,
         "linkEdgeCount":0,"simEdgeCount":0,"communityCount":2,"levelCount":1,
         "vectorCoverage":1.0,"summaryProvider":"none","summarisedCount":0,
         "incremental":false,"attachedCount":0,"pendingCount":0}
        """)
        XCTAssertNil(
            status.newSinceBuild,
            "with attachment switched off the counts are never computed; 0 would be a claim we cannot make"
        )
    }

    func testAReportedZeroIsARealAnswer() throws {
        let status = try decodeStatus("""
        {"state":"READY","enabled":true,"stale":false,"noteCount":10,"edgeCount":0,
         "linkEdgeCount":0,"simEdgeCount":0,"communityCount":2,"levelCount":1,
         "vectorCoverage":1.0,"summaryProvider":"none","summarisedCount":0,
         "incremental":true,"attachedCount":0,"pendingCount":0}
        """)
        XCTAssertEqual(status.newSinceBuild, 0, "nothing is missing from the map — the banner must hide")
    }

    func testCountsAreSummedAndPendingIsKeptSeparate() throws {
        let status = try decodeStatus("""
        {"state":"READY","enabled":true,"stale":true,"noteCount":10,"edgeCount":0,
         "linkEdgeCount":0,"simEdgeCount":0,"communityCount":2,"levelCount":1,
         "vectorCoverage":1.0,"summaryProvider":"none","summarisedCount":0,
         "incremental":true,"attachedCount":2,"pendingCount":1}
        """)
        // The sum is what arrived since the build; `pendingCount` alone is what a rebuild would fix.
        // Collapsing them into one number would overstate the problem in the pane.
        XCTAssertEqual(status.newSinceBuild, 3)
        XCTAssertEqual(status.pendingCount, 1)
        XCTAssertEqual(status.attachedCount, 2)
    }

    func testDriftRatioIsOptionalSoOlderEnginesStillDecode() throws {
        let without = try decodeStatus("""
        {"state":"READY","enabled":true,"stale":false,"noteCount":1,"edgeCount":0,
         "linkEdgeCount":0,"simEdgeCount":0,"communityCount":1,"levelCount":1,
         "vectorCoverage":1.0,"summaryProvider":"none","summarisedCount":0}
        """)
        XCTAssertNil(without.driftRatio)

        let with = try decodeStatus("""
        {"state":"READY","enabled":true,"stale":false,"noteCount":1,"edgeCount":0,
         "linkEdgeCount":0,"simEdgeCount":0,"communityCount":1,"levelCount":1,
         "vectorCoverage":1.0,"summaryProvider":"none","summarisedCount":0,
         "incremental":true,"attachedCount":4,"pendingCount":0,"driftRatio":0.25}
        """)
        XCTAssertEqual(with.driftRatio ?? 0, 0.25, accuracy: 1e-9)
    }

    func testCommunityDecodesWithoutTheGrowthField() throws {
        let community = try JSONDecoder().decode(GraphCommunity.self, from: Data("""
        {"id":"L2-0","level":2,"title":"Тема","summary":"Обобщение.","size":320,
         "members":["a.md","b.md"]}
        """.utf8))
        XCTAssertNil(community.addedSinceSummary, "an older engine omits it; the row simply shows no +N")
        XCTAssertEqual(community.size, 320)
    }

    func testCommunityCarriesTheGrowthFieldWhenPresent() throws {
        let community = try JSONDecoder().decode(GraphCommunity.self, from: Data("""
        {"id":"L2-0","level":2,"title":"Тема","summary":"Обобщение.","size":321,
         "members":["a.md"],"addedSinceSummary":1}
        """.utf8))
        XCTAssertEqual(community.addedSinceSummary, 1)
    }
}
