import XCTest
@testable import Nod

final class MemoryBriefTests: XCTestCase {
    /// A Wednesday afternoon, so "today" and "this week" are distinguishable.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func meeting(
        title: String?,
        hoursAgo: Double,
        deleted: Bool = false,
        sections: [MeetingRecap.Section] = []
    ) -> Meeting {
        Meeting(
            id: UUID(),
            userID: UUID(),
            createdAt: nil,
            startedAt: now.addingTimeInterval(-hoursAgo * 3600),
            endedAt: now.addingTimeInterval(-hoursAgo * 3600 + 1800),
            title: title,
            kind: .meeting,
            summary: "",
            recap: sections.isEmpty ? nil : MeetingRecap(sections: sections),
            language: "en",
            speakerNames: nil,
            deletedAt: deleted ? now : nil
        )
    }

    func testOpenCommitmentsAreReportedAsGiven() {
        let brief = MemoryBrief.build(
            meetings: [meeting(title: "Standup", hoursAgo: 2)],
            openCommitments: 3,
            now: now
        )

        XCTAssertEqual(brief.openCommitments, 3)
        XCTAssertTrue(brief.summary.contains("3 open commitments"))
    }

    func testFallsBackToTheWeekWhenTodayIsEmpty() {
        let brief = MemoryBrief.build(
            meetings: [meeting(title: "Monday sync", hoursAgo: 48)],
            openCommitments: 0,
            now: now
        )

        XCTAssertEqual(brief.captured, 1)
        XCTAssertTrue(brief.capturedSpansWeek)
        XCTAssertTrue(brief.summary.contains("1 session this week"))
    }

    func testTodayWinsOverTheWeek() {
        let brief = MemoryBrief.build(
            meetings: [meeting(title: "Now", hoursAgo: 1), meeting(title: "Older", hoursAgo: 72)],
            openCommitments: 0,
            now: now
        )

        XCTAssertEqual(brief.captured, 1)
        XCTAssertFalse(brief.capturedSpansWeek)
        XCTAssertTrue(brief.summary.contains("1 session today"))
    }

    func testMostActiveContextIsTheNewestTitledSession() {
        let brief = MemoryBrief.build(
            meetings: [meeting(title: "Older", hoursAgo: 30), meeting(title: "Newest", hoursAgo: 1)],
            openCommitments: 0,
            now: now
        )

        XCTAssertEqual(brief.mostActiveContext, "Newest")
    }

    func testUnresolvedComesFromOpenRecapSections() {
        let planning = meeting(
            title: "Planning",
            hoursAgo: 5,
            sections: [
                MeetingRecap.Section(title: "Open questions", bullets: [
                    MeetingRecap.Bullet(text: "Annual discount?"),
                    MeetingRecap.Bullet(text: "Who owns the migration?")
                ]),
                MeetingRecap.Section(title: "Decisions made", bullets: [MeetingRecap.Bullet(text: "Two tiers")])
            ]
        )
        let brief = MemoryBrief.build(meetings: [planning], openCommitments: 0, now: now)

        XCTAssertEqual(brief.unresolved, 2)
    }

    func testEmptyMemoryProducesNothingToShow() {
        let brief = MemoryBrief.build(meetings: [], openCommitments: 0, now: now)

        XCTAssertTrue(brief.isEmpty)
        XCTAssertTrue(brief.summary.isEmpty)
    }
}
