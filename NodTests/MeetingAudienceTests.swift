import XCTest
@testable import Nod

/// Who can open a session, asserted.
///
/// The chip this feeds answers one question — *is this only mine* — and it was
/// answering it from `meeting_grants` alone while `meetings`' read policy names
/// a second route a person controls: a project the session is filed in that
/// somebody shared. A session inside a shared project read "Only me".
final class MeetingAudienceTests: XCTestCase {
    private let founders = UUID()
    private let design = UUID()
    private let meeting = UUID()

    private var teams: [(id: UUID, name: String)] {
        [(id: founders, name: "Founders"), (id: design, name: "Design")]
    }

    private func grant(team: UUID? = nil, org: UUID? = nil) -> MeetingGrant {
        MeetingGrant(id: UUID(), meetingID: meeting, teamID: team, orgID: org)
    }

    private func share(team: UUID? = nil, org: UUID? = nil) -> FolderShare {
        FolderShare(id: UUID(), labelID: UUID(), teamID: team, orgID: org)
    }

    private func audience(
        grants: [MeetingGrant] = [],
        projects: [(name: String, shares: [FolderShare])] = []
    ) -> MeetingAudience {
        MeetingAudience.of(grants: grants, projects: projects, teams: teams, orgName: "Nod")
    }

    // MARK: - The question the chip exists for

    func testNothingSharedIsOnlyMine() {
        let audience = audience()
        XCTAssertTrue(audience.isPrivate)
        XCTAssertEqual(audience.title, "Only me")
    }

    func testASessionInAnUnsharedProjectIsStillOnlyMine() {
        let audience = audience(projects: [(name: "Nod", shares: [])])
        XCTAssertTrue(audience.isPrivate)
        XCTAssertEqual(audience.title, "Only me")
    }

    func testASessionInASharedProjectIsNotOnlyMine() {
        // The bug this type exists for. Nothing grants the session itself, so
        // the old reading was "Only me" — while everybody on Founders could
        // open it through the project.
        let audience = audience(projects: [(name: "Nod", shares: [share(team: founders)])])
        XCTAssertFalse(audience.isPrivate)
        XCTAssertEqual(audience.title, "Shared with Founders")
    }

    // MARK: - Naming the audience

    func testAnOrgGrantDoesNotHideTheTeamBesideIt() {
        // The wider audience swallowing the narrower one is the wrong direction
        // for a control whose job is saying who can see this.
        let audience = audience(grants: [grant(team: founders), grant(org: UUID())])
        XCTAssertEqual(audience.title, "Shared with Nod +1")
        XCTAssertEqual(audience.everyone, ["Nod", "Founders"])
    }

    func testTheWidestAudienceIsNamedFirst() {
        let audience = audience(grants: [grant(team: design), grant(org: UUID())])
        XCTAssertEqual(audience.everyone.first, "Nod")
    }

    func testAnAudienceReachedTwiceIsNamedOnce() {
        // Granted directly *and* reached through a project. One name, or the
        // chip counts a person twice and says "+1" about nobody.
        let audience = audience(
            grants: [grant(team: founders)],
            projects: [(name: "Nod", shares: [share(team: founders)])]
        )
        XCTAssertEqual(audience.everyone, ["Founders"])
        XCTAssertEqual(audience.title, "Shared with Founders")
    }

    func testATeamNoLongerInTheOrgIsNotNamed() {
        // A grant outliving the team it points at: better to under-report a
        // name than to invent one.
        let audience = audience(grants: [grant(team: UUID())])
        XCTAssertEqual(audience.everyone, [])
        XCTAssertEqual(audience.title, "Only me")
    }

    // MARK: - Telling the two routes apart

    func testAProjectsReachIsKeptSeparateFromADirectGrant() {
        // Revoking them are different acts in different places: one is this
        // session's, the other belongs to the project and every session in it.
        let audience = audience(
            grants: [grant(team: design)],
            projects: [(name: "Nod", shares: [share(team: founders)])]
        )
        XCTAssertEqual(audience.direct, ["Design"])
        XCTAssertEqual(audience.viaProjects, [.init(project: "Nod", audiences: ["Founders"])])
    }

    func testAProjectThatReachesNobodyIsNotListed() {
        let audience = audience(projects: [(name: "Nod", shares: []), (name: "Ops", shares: [share(org: UUID())])])
        XCTAssertEqual(audience.viaProjects, [.init(project: "Ops", audiences: ["Nod"])])
    }
}
