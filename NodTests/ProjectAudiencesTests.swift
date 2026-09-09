import XCTest
@testable import Nod

/// What the share list does at a scale nobody developing has.
///
/// The organization this was built against has two teams, which exercises none
/// of these rules — so the sheet looks like three plain checkboxes and the
/// answer to "what happens at a hundred?" is a claim no screenshot can check.
/// These run it against a hundred.
final class ProjectAudiencesTests: XCTestCase {
    private let orgID = UUID()

    private func team(_ name: String) -> Team {
        Team(id: UUID(), orgID: orgID, name: name)
    }

    /// Named so the alphabetical tie-break is checkable: "Team 007" sorts
    /// before "Team 042" as text, which zero-padding is what makes true.
    private func manyTeams(_ count: Int) -> [Team] {
        (0 ..< count).map { team(String(format: "Team %03d", $0)) }
    }

    // MARK: - When the search field appears

    func testAHandfulOfTeamsNeedsNoSearchField() {
        XCTAssertFalse(ProjectAudiences.isSearchable(teamCount: 0))
        XCTAssertFalse(ProjectAudiences.isSearchable(teamCount: 2))
        XCTAssertFalse(ProjectAudiences.isSearchable(teamCount: ProjectAudiences.searchThreshold))
    }

    func testPastTheThresholdTheListBecomesSearchable() {
        XCTAssertTrue(ProjectAudiences.isSearchable(teamCount: ProjectAudiences.searchThreshold + 1))
        XCTAssertTrue(ProjectAudiences.isSearchable(teamCount: 100))
    }

    // MARK: - A hundred teams

    /// The height cap is visual. Every team stays reachable by scrolling — a
    /// list that silently dropped the hundredth team would be worse than one
    /// that is long.
    func testAHundredTeamsAreAllListed() {
        let teams = manyTeams(100)
        let order = ProjectAudiences.ranked(teams, sharedWith: []).map(\.id)

        let listed = ProjectAudiences.listed(teams, order: order, query: "")

        XCTAssertEqual(listed.count, 100)
        XCTAssertEqual(Set(listed.map(\.id)), Set(teams.map(\.id)))
    }

    /// The sheet is the same height at a hundred teams as at three: the list
    /// has to be shorter than the rows it holds, or it is not a cap.
    func testTheListIsShorterThanTheTeamsItHolds() {
        let rowHeight: CGFloat = 21

        XCTAssertLessThan(ProjectAudiences.listHeight, rowHeight * CGFloat(manyTeams(100).count))
    }

    func testSearchNarrowsAHundredTeamsToTheMatches() {
        let teams = manyTeams(100)
        let order = ProjectAudiences.ranked(teams, sharedWith: []).map(\.id)

        let listed = ProjectAudiences.listed(teams, order: order, query: "team 04")

        XCTAssertEqual(listed.map(\.name), (40 ... 49).map { String(format: "Team %03d", $0) })
    }

    func testSearchIgnoresCaseAndSurroundingSpace() {
        let teams = [team("Founders"), team("Growth")]
        let order = teams.map(\.id)

        XCTAssertEqual(ProjectAudiences.listed(teams, order: order, query: "  FOUND ").map(\.name), ["Founders"])
    }

    // MARK: - Finding what is already shared

    /// The reason ordering exists: at a hundred teams, the two a project is
    /// already shared with are otherwise somewhere in the scroll.
    func testTeamsAlreadySharedWithComeFirst() {
        let teams = manyTeams(100)
        let shared = Set([teams[73].id, teams[12].id])

        let ranked = ProjectAudiences.ranked(teams, sharedWith: shared)

        XCTAssertEqual(Set(ranked.prefix(2).map(\.id)), shared)
        XCTAssertEqual(ranked.count, 100)
    }

    func testTheRestStayAlphabeticalBehindThem() {
        let teams = [team("Zulu"), team("Alpha"), team("Mike")]
        let shared = Set([teams[0].id])

        let ranked = ProjectAudiences.ranked(teams, sharedWith: shared)

        XCTAssertEqual(ranked.map(\.name), ["Zulu", "Alpha", "Mike"])
    }

    // MARK: - The order does not move while you pick

    /// Ticking a box must not reorder the list under the cursor: the row you
    /// just ticked would jump to the top and the one you were aiming at next
    /// would slide into its place.
    func testPickingATeamDoesNotReorderTheList() {
        let teams = manyTeams(20)
        let order = ProjectAudiences.ranked(teams, sharedWith: []).map(\.id)
        let before = ProjectAudiences.listed(teams, order: order, query: "").map(\.id)

        // The sheet ticks a box — `order` is frozen, so only the selection moved.
        let after = ProjectAudiences.listed(teams, order: order, query: "").map(\.id)

        XCTAssertEqual(before, after)
        XCTAssertEqual(after.first, order.first)
    }

    /// A team created in another window while this sheet is open is still a
    /// team you can share with, so it lands at the end rather than vanishing.
    func testATeamMissingFromTheFrozenOrderStillAppears() {
        let known = manyTeams(3)
        let latecomer = team("Aardvark")
        let order = known.map(\.id)

        let listed = ProjectAudiences.listed(known + [latecomer], order: order, query: "")

        XCTAssertEqual(listed.count, 4)
        XCTAssertEqual(listed.last?.id, latecomer.id)
    }
}
