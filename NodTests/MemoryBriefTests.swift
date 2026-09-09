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

    func testFallsBackToTheWeekWhenTodayIsEmpty() {
        let brief = MemoryBrief.build(meetings: [meeting(title: "Monday sync", hoursAgo: 48)], now: now)

        XCTAssertEqual(brief.captured, 1)
        XCTAssertTrue(brief.capturedSpansWeek)
        XCTAssertEqual(brief.contextSummary, "1 session this week")
    }

    func testTodayWinsOverTheWeek() {
        let brief = MemoryBrief.build(
            meetings: [meeting(title: "Now", hoursAgo: 1), meeting(title: "Older", hoursAgo: 72)],
            now: now
        )

        XCTAssertEqual(brief.captured, 1)
        XCTAssertFalse(brief.capturedSpansWeek)
        XCTAssertEqual(brief.contextSummary, "1 session today")
    }

    func testMostActiveContextIsTheNewestTitledSession() {
        let brief = MemoryBrief.build(
            meetings: [meeting(title: "Older", hoursAgo: 30), meeting(title: "Newest", hoursAgo: 1)],
            now: now
        )

        XCTAssertEqual(brief.mostActiveContext, "Newest")
    }

    func testDecisionsThisWeekAreCounted() {
        let planning = meeting(
            title: "Planning",
            hoursAgo: 5,
            sections: [
                MeetingRecap.Section(title: "Decisions made", bullets: [
                    MeetingRecap.Bullet(text: "Two tiers"),
                    MeetingRecap.Bullet(text: "Ship on the 14th")
                ])
            ]
        )
        let brief = MemoryBrief.build(meetings: [planning], now: now)

        XCTAssertEqual(brief.decisions, 2)
    }

    /// Nothing captured is nothing to say — the card renders no line at all
    /// rather than an empty one.
    func testEmptyMemoryProducesNothingToShow() {
        XCTAssertNil(MemoryBrief.build(meetings: [], now: now).contextSummary)
    }
}
