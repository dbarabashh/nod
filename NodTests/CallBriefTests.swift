import XCTest
@testable import Nod

final class CallBriefTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    // MARK: - Matching

    func testMatchesAWindowTitleAgainstAFiledSession() {
        let brief = CallBrief.build(
            named: "Meet – Weekly planning - Google Chrome",
            meetings: [meeting(title: "Weekly planning sync", daysAgo: 7)],
            actionItems: []
        )
        XCTAssertEqual(brief?.title, "Weekly planning sync")
    }

    func testMatchesWhenTheWindowTitleIsTheLongerOfTheTwo() {
        let brief = CallBrief.build(
            named: "Zoom Meeting — Onboarding funnel review",
            meetings: [meeting(title: "Onboarding funnel", daysAgo: 3)],
            actionItems: []
        )
        XCTAssertNotNil(brief)
    }

    func testIgnoresUnrelatedSessions() {
        let brief = CallBrief.build(
            named: "Meet – Pricing workshop",
            meetings: [meeting(title: "Weekly planning sync", daysAgo: 2)],
            actionItems: []
        )
        XCTAssertNil(brief)
    }

    /// The whole title is the product's own name — there is nothing in it to
    /// recognise a conversation by.
    func testSaysNothingWhenTheTitleIsOnlyProductChrome() {
        let brief = CallBrief.build(
            named: "Zoom Meeting",
            meetings: [meeting(title: "Zoom migration plan", daysAgo: 1)],
            actionItems: []
        )
        XCTAssertNil(brief)
    }

    func testSaysNothingWithoutATitle() {
        XCTAssertNil(
            CallBrief.build(named: nil, meetings: [meeting(title: "Weekly planning", daysAgo: 1)], actionItems: [])
        )
    }

    /// A Google Meet code is not a subject: it survives tokenising, matches
    /// nothing, and must not drag an unrelated session in behind it.
    func testAMeetingCodeMatchesNothing() {
        let brief = CallBrief.build(
            named: "Meet – abc-defg-hij",
            meetings: [meeting(title: "Weekly planning sync", daysAgo: 1)],
            actionItems: []
        )
        XCTAssertNil(brief)
    }

    // MARK: - Two words at minimum

    /// One shared word is never enough, however distinctive it looks — the rule
    /// that decides "distinctive" is always a rule about one language.
    func testOneSharedWordIsNeverEnough() {
        let brief = CallBrief.build(
            named: "Meeting in Onboarding | Microsoft Teams",
            meetings: [meeting(title: "Onboarding drop-off", daysAgo: 4)],
            actionItems: []
        )
        XCTAssertNil(brief)
    }

    func testTwoSharedWordsMatch() {
        let brief = CallBrief.build(
            named: "Meeting in Onboarding drop-off | Microsoft Teams",
            meetings: [meeting(title: "Onboarding drop-off review", daysAgo: 4)],
            actionItems: []
        )
        XCTAssertEqual(brief?.title, "Onboarding drop-off review")
    }

    /// Nothing in the rule is written in English. A Ukrainian user's titles are
    /// Ukrainian, and the same two-word floor has to hold there — an English
    /// stopword list would veto nothing and match on "зустріч" alone.
    func testMatchingIsLanguageIndependent() {
        let matched = CallBrief.build(
            named: "Планування релізу",
            meetings: [meeting(title: "Планування релізу v12", daysAgo: 6)],
            actionItems: []
        )
        XCTAssertEqual(matched?.title, "Планування релізу v12")

        let onOneWord = CallBrief.build(
            named: "Зустріч",
            meetings: [meeting(title: "Зустріч про ціни", daysAgo: 6)],
            actionItems: []
        )
        XCTAssertNil(onOneWord)
    }

    // MARK: - The calendar

    /// The whole point of reading the calendar: Zoom's window title is only the
    /// product's own name and matches nothing, where the event names the meeting.
    func testACalendarNameMatchesWhereAWindowTitleCannot() {
        let meetings = [meeting(title: "Onboarding drop-off review", daysAgo: 7)]
        XCTAssertNil(CallBrief.build(named: "Zoom Meeting", meetings: meetings, actionItems: []))
        XCTAssertEqual(
            CallBrief.build(named: "Onboarding drop-off", meetings: meetings, actionItems: [])?.title,
            "Onboarding drop-off review"
        )
    }

    // MARK: - What it reports

    func testReportsTheNewestMatchAndCountsOpenItemsAcrossAllOfThem() {
        let older = meeting(title: "Weekly planning sync", daysAgo: 14)
        let newer = meeting(title: "Weekly planning", daysAgo: 7)
        let brief = CallBrief.build(
            named: "Meet – Weekly planning",
            meetings: [older, newer],
            actionItems: [
                item(meetingID: older.id, done: false),
                item(meetingID: newer.id, done: false),
                item(meetingID: newer.id, done: true),
                item(meetingID: UUID(), done: false)
            ]
        )
        XCTAssertEqual(brief?.title, "Weekly planning")
        XCTAssertEqual(brief?.lastMet, newer.startedAt)
        XCTAssertEqual(brief?.openCommitments, 2)
    }

    func testSkipsDeletedItemsAndTrashedSessions() {
        let live = meeting(title: "Weekly planning", daysAgo: 7)
        var trashed = meeting(title: "Weekly planning", daysAgo: 2)
        trashed.deletedAt = now

        let brief = CallBrief.build(
            named: "Meet – Weekly planning",
            meetings: [trashed, live],
            actionItems: [
                item(meetingID: live.id, done: false),
                item(meetingID: live.id, done: false, deleted: true),
                item(meetingID: trashed.id, done: false)
            ]
        )
        XCTAssertEqual(brief?.lastMet, live.startedAt)
        XCTAssertEqual(brief?.openCommitments, 1)
    }

    func testLineNamesTheOpenItemsWhenThereAreAny() {
        let brief = CallBrief(title: "Weekly planning", lastMet: now.addingTimeInterval(-3 * 86400), openCommitments: 2)
        let line = brief.line(relativeTo: now)
        XCTAssertTrue(line.hasPrefix("Continues Weekly planning · "))
        XCTAssertTrue(line.hasSuffix("· 2 items still open"))
    }

    func testLineDropsTheCountWhenNothingIsOpen() {
        let brief = CallBrief(title: "Weekly planning", lastMet: now.addingTimeInterval(-3 * 86400), openCommitments: 0)
        XCTAssertFalse(brief.line(relativeTo: now).contains("open"))
    }

    func testLineSpeaksOfOneItemInTheSingular() {
        let brief = CallBrief(title: "Weekly planning", lastMet: now.addingTimeInterval(-86400), openCommitments: 1)
        XCTAssertTrue(brief.line(relativeTo: now).hasSuffix("· 1 item still open"))
    }

    // MARK: - Fixtures

    private func meeting(title: String, daysAgo: Int) -> Meeting {
        let started = now.addingTimeInterval(-Double(daysAgo) * 86400)
        return Meeting(
            id: UUID(),
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
            deletedAt: nil
        )
    }

    private func item(meetingID: UUID, done: Bool, deleted: Bool = false) -> ActionItem {
        ActionItem(
            id: UUID(),
            meetingID: meetingID,
            userID: UUID(),
            text: "Follow up",
            deadline: nil,
            position: 0,
            done: done,
            doneAt: nil,
            createdAt: now,
            updatedAt: nil,
            deletedAt: deleted ? now : nil
        )
    }
}
