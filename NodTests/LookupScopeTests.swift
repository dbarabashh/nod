import XCTest
@testable import Nod

/// What "earlier in this project" means when there is no project.
///
/// Filing is something people do afterwards if at all, so the interesting cases
/// here are all the ones where nobody filed anything — and what this pins is
/// that each of them still searches *something*.
final class LookupScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)
    private let live = UUID()
    private let planningProject = UUID()
    private let otherProject = UUID()

    // MARK: - Filed

    func testAFiledMeetingSearchesItsProject() {
        let sibling = meeting(daysAgo: 7)
        let unrelated = meeting(daysAgo: 3)
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: nil,
            assignments: [live: [planningProject], sibling.id: [planningProject], unrelated.id: [otherProject]],
            labelNames: [planningProject: "Onboarding"],
            meetings: [meeting(id: live, daysAgo: 0), sibling, unrelated]
        )

        XCTAssertEqual(scope, .project(name: "Onboarding", meetingIDs: [sibling.id]))
        XCTAssertEqual(scope.meetingIDs, [sibling.id])
        XCTAssertEqual(scope.label, "Onboarding")
    }

    /// The meeting in progress is never one of its own earlier discussions.
    func testTheLiveMeetingIsExcluded() {
        let sibling = meeting(daysAgo: 7)
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: nil,
            assignments: [live: [planningProject], sibling.id: [planningProject]],
            labelNames: [planningProject: "Onboarding"],
            meetings: [meeting(id: live, daysAgo: 0), sibling]
        )

        XCTAssertEqual(scope.meetingIDs, [sibling.id])
    }

    /// Filed into a brand-new project nothing else is in. There is no narrower
    /// search to run, so it falls through rather than searching an empty set.
    func testAProjectWithNoOtherSessionsFallsThrough() {
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: nil,
            assignments: [live: [planningProject]],
            labelNames: [planningProject: "Onboarding"],
            meetings: [meeting(id: live, daysAgo: 0), meeting(daysAgo: 4)]
        )

        XCTAssertEqual(scope, .everything)
        XCTAssertNil(scope.meetingIDs)
    }

    // MARK: - Not filed

    /// The case this whole type exists for. Nobody made a folder, but the
    /// weekly sync carries one calendar uid across every instance — which is
    /// the folder, under another name.
    func testARecurringMeetingSearchesItsOwnSeries() {
        let lastWeek = meeting(daysAgo: 7, icalUID: "weekly-planning", title: "Weekly planning")
        let fortnightAgo = meeting(daysAgo: 14, icalUID: "weekly-planning", title: "Weekly planning")
        let unrelated = meeting(daysAgo: 2, icalUID: "all-hands")
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: "weekly-planning",
            assignments: [:],
            labelNames: [:],
            meetings: [meeting(id: live, daysAgo: 0, icalUID: "weekly-planning"), lastWeek, fortnightAgo, unrelated]
        )

        XCTAssertEqual(scope, .series(title: "Weekly planning", meetingIDs: [lastWeek.id, fortnightAgo.id]))
    }

    /// A one-off with an invitation is not a series. Its uid matches nothing
    /// earlier, so there is nothing narrower to search.
    func testAOneOffCalendarMeetingFallsThrough() {
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: "one-off",
            assignments: [:],
            labelNames: [:],
            meetings: [meeting(id: live, daysAgo: 0, icalUID: "one-off"), meeting(daysAgo: 5, icalUID: "something-else")]
        )

        XCTAssertEqual(scope, .everything)
    }

    /// No folder, no invitation. Not a failure: unscoped is what the recall
    /// pass already does, and every answer names the session it came from.
    func testNothingKnownSearchesEverything() {
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: nil,
            assignments: [:],
            labelNames: [:],
            meetings: [meeting(id: live, daysAgo: 0), meeting(daysAgo: 5)]
        )

        XCTAssertEqual(scope, .everything)
        XCTAssertNil(scope.meetingIDs)
        XCTAssertNil(scope.label)
    }

    /// A project outranks a series: the user said what this belongs to, and a
    /// calendar uid is a guess at the same question.
    func testFilingWinsOverRecurrence() {
        let sibling = meeting(daysAgo: 9)
        let seriesMate = meeting(daysAgo: 7, icalUID: "weekly-planning")
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: "weekly-planning",
            assignments: [live: [planningProject], sibling.id: [planningProject]],
            labelNames: [planningProject: "Onboarding"],
            meetings: [meeting(id: live, daysAgo: 0, icalUID: "weekly-planning"), sibling, seriesMate]
        )

        XCTAssertEqual(scope, .project(name: "Onboarding", meetingIDs: [sibling.id]))
    }

    /// Trashed sessions are not earlier discussions.
    func testDeletedSessionsAreNotSearched() {
        let binned = meeting(daysAgo: 7, deleted: true)
        let scope = LookupScope.of(
            meetingID: live,
            icalUID: "weekly-planning",
            assignments: [:],
            labelNames: [:],
            meetings: [
                meeting(id: live, daysAgo: 0, icalUID: "weekly-planning"),
                Meeting(
                    id: binned.id,
                    userID: binned.userID,
                    createdAt: nil,
                    startedAt: binned.startedAt,
                    endedAt: binned.endedAt,
                    title: binned.title,
                    kind: .meeting,
                    summary: "",
                    recap: nil,
                    language: "en",
                    speakerNames: nil,
                    icalUID: "weekly-planning",
                    deletedAt: now
                )
            ]
        )

        XCTAssertEqual(scope, .everything)
    }

    // MARK: - Fixtures

    private func meeting(
        id: UUID = UUID(),
        daysAgo: Int,
        icalUID: String? = nil,
        title: String? = "Session",
        deleted: Bool = false
    ) -> Meeting {
        let started = now.addingTimeInterval(-Double(daysAgo) * 86400)
        return Meeting(
            id: id,
            userID: UUID(),
            createdAt: nil,
            startedAt: started,
            endedAt: started.addingTimeInterval(1800),
            title: title,
            kind: .meeting,
            summary: "",
            recap: nil,
            language: "en",
            speakerNames: nil,
            icalUID: icalUID,
            deletedAt: deleted ? now : nil
        )
    }
}
