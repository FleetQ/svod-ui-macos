import XCTest
@testable import Svod

/// The two pieces of pane logic that are not just rendering: which themes are worth listing, and
/// what switching hierarchy level does to the current selection.
///
/// Both were shipped untested in the first pass and flagged for it. `visibleCommunities` in
/// particular is load-bearing: a Louvain level partitions the WHOLE corpus, so most communities at
/// any level are single notes, and without the filter the pane's list is mostly rows with a filename
/// for a title.
@MainActor
final class GraphModelPaneTests: XCTestCase {

    private func community(_ id: String, size: Int) -> GraphCommunity {
        GraphCommunity(
            id: id, level: 2, title: "Тема \(id)", summary: nil, size: size,
            members: (0..<size).map { "n\($0).md" }
        )
    }

    private func model() -> GraphModel {
        GraphModel(client: MockSvodClient())
    }

    func testSingletonAndPairCommunitiesAreNotListed() {
        let m = model()
        m.communities = [
            community("big", size: 320),
            community("small", size: 3),
            community("pair", size: 2),
            community("single", size: 1),
        ]
        // 3 is the engine's own `minCommunitySize` — the size below which it will not even summarise.
        XCTAssertEqual(m.visibleCommunities.map(\.id), ["big", "small"])
    }

    func testAnAllSingletonLevelListsNothingRatherThanNoise() {
        let m = model()
        m.communities = (0..<40).map { community("s\($0)", size: 1) }
        XCTAssertTrue(
            m.visibleCommunities.isEmpty,
            "the pane shows its empty state instead of 40 unusable rows"
        )
    }

    func testClearGraphResetsEverythingThePaneBranchesOn() {
        let m = model()
        m.communities = [community("big", size: 10)]
        m.newSinceBuild = 5
        m.pendingNotes = 2
        m.driftRatio = 0.4
        m.level = 0
        m.levelCount = 3
        m.selectedCommunityID = "big"

        m.clearGraph()

        // A stale value surviving a vault switch would describe the PREVIOUS vault — the banner would
        // report another vault's drift against this one's themes.
        XCTAssertTrue(m.communities.isEmpty)
        XCTAssertNil(m.newSinceBuild)
        XCTAssertEqual(m.pendingNotes, 0)
        XCTAssertNil(m.driftRatio)
        XCTAssertNil(m.level)
        XCTAssertEqual(m.levelCount, 0)
        XCTAssertNil(m.selectedCommunityID)
    }

    func testSwitchingLevelDropsTheSelection() async {
        let m = model()
        m.levelCount = 3
        m.selectedCommunityID = "L2-0"

        await m.showLevel(0)

        // Community ids are per-level, so carrying a selection across a level switch would leave the
        // notes tree filtered to a theme that is no longer on screen.
        XCTAssertEqual(m.level, 0)
        XCTAssertNil(m.selectedCommunityID)
    }

    func testSwitchingToTheSameLevelIsANoOp() async {
        let m = model()
        m.level = 1
        m.selectedCommunityID = "L1-0"

        await m.showLevel(1)

        XCTAssertEqual(m.selectedCommunityID, "L1-0", "a redundant switch must not clear the selection")
    }
}
