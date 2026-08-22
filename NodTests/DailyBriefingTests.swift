import XCTest
@testable import Nod

/// The briefing's rows are assembled here rather than written by the model, so
/// what this pins is the arithmetic the model is never allowed to do: which
/// events are still ahead, and whether there is anything worth a screen at all.
final class DailyBriefingTests: XCTestCase {
    /// A Wednesday afternoon, so "today" has both a morning behind it and an
    /// evening in front of it.
    private let now = Date(timeIntervalSince1970: 1_787_055_600)

    // MARK: - Still ahead

    func testAFinishedMeetingIsNotAhead() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [event(title: "Standup", from: -3 * 3600, to: -2 * 3600)],
            now: now
        )

        XCTAssertTrue(facts.ahead.isEmpty)
    }

    /// A call in progress is still ahead — it has not been had yet, and
    /// dropping it is how a briefing tells somebody they are free during it.
    func testAMeetingInProgressIsStillAhead() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [event(title: "Pricing review", from: -600, to: 1800)],
            now: now
        )

        XCTAssertEqual(facts.ahead.map(\.title), ["Pricing review"])
    }

    func testTomorrowIsNotToday() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [event(title: "Board call", from: 26 * 3600, to: 27 * 3600)],
            now: now
        )

        XCTAssertTrue(facts.ahead.isEmpty)
    }

    func testAheadIsOrderedByStart() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [
                event(title: "Later", from: 3 * 3600, to: 4 * 3600),
                event(title: "Sooner", from: 3600, to: 2 * 3600)
            ],
            now: now
        )

        XCTAssertEqual(facts.ahead.map(\.title), ["Sooner", "Later"])
    }

    /// A block of time with nobody else on it is not a meeting, and saying
    /// "with 0 others" under it would be worse than saying nothing.
    func testAnEventWithNobodyElseSaysNothingAboutWho() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [event(title: "Focus block", from: 3600, to: 7200)],
            now: now
        )

        XCTAssertNil(facts.ahead.first?.subtitle)
    }

    func testAnEventNamesWhoItIsWith() {
        let withTwo = event(
            title: "Design sync",
            from: 3600,
            to: 7200,
            attendees: [
                CalendarAttendee(display: "Me", isSelf: true),
                CalendarAttendee(display: "Anna Lund", isSelf: false),
                CalendarAttendee(display: "Tom Reid", isSelf: false)
            ]
        )
        let facts = DailyBriefing.facts(meetings: [], actionItems: [], events: [withTwo], now: now)

        XCTAssertEqual(facts.ahead.first?.subtitle, "With Anna Lund and Tom Reid")
    }

    /// Past three the sentence stops naming and starts counting — the shared
    /// `CallContext.withLine` rule, not a second one written here.
    func testALargeMeetingCountsTheRest() {
        let crowd = event(
            title: "All hands",
            from: 3600,
            to: 7200,
            attendees: [CalendarAttendee(display: "Me", isSelf: true)]
                + ["Anna Lund", "Tom Reid", "Ines Duarte", "Jonas Hedlund"]
                .map { CalendarAttendee(display: $0, isSelf: false) }
        )
        let facts = DailyBriefing.facts(meetings: [], actionItems: [], events: [crowd], now: now)

        XCTAssertEqual(facts.ahead.first?.subtitle, "With Anna Lund, Tom Reid and 2 others")
    }

    // MARK: - Owed

    func testAnOpenItemIsOwedAndPointsAtItsSession() {
        let meeting = meeting(title: "Weekly planning", daysAgo: 1)
        let facts = DailyBriefing.facts(
            meetings: [meeting],
            actionItems: [item(meetingID: meeting.id, text: "Send the deck", done: false)],
            events: [],
            now: now
        )

        XCTAssertEqual(facts.owed.map(\.title), ["Send the deck"])
        XCTAssertEqual(facts.owed.first?.meetingID, meeting.id)
    }

    func testATickedItemIsNotOwed() {
        let meeting = meeting(title: "Weekly planning", daysAgo: 1)
        let facts = DailyBriefing.facts(
            meetings: [meeting],
            actionItems: [item(meetingID: meeting.id, text: "Send the deck", done: true)],
            events: [],
            now: now
        )

        XCTAssertTrue(facts.owed.isEmpty)
    }

    // MARK: - Emptiness

    /// The one state the whole feature depends on getting right. An empty day
    /// must read as empty, because a briefing generated over nothing is what
    /// teaches somebody to stop opening the screen.
    func testAQuietDayIsEmpty() {
        let facts = DailyBriefing.facts(meetings: [], actionItems: [], events: [], now: now)

        XCTAssertTrue(facts.isEmpty)
        XCTAssertTrue(facts.rows.isEmpty)
    }

    func testAnyOneGroupIsEnoughToBrief() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [event(title: "Retro", from: 3600, to: 7200)],
            now: now
        )

        XCTAssertFalse(facts.isEmpty)
    }

    // MARK: - Greeting

    /// Which half of the day it is never goes to the model: a briefing opened
    /// at six in the evening that says "good morning" is one nobody believes
    /// the rest of.
    func testTheGreetingFollowsTheClock() {
        XCTAssertEqual(DailyBriefing.greeting(name: "Dima", now: at(hour: 8)), "Good morning, Dima")
        XCTAssertEqual(DailyBriefing.greeting(name: "Dima", now: at(hour: 14)), "Good afternoon, Dima")
        XCTAssertEqual(DailyBriefing.greeting(name: "Dima", now: at(hour: 21)), "Good evening, Dima")
        XCTAssertEqual(DailyBriefing.greeting(name: "Dima", now: at(hour: 3)), "Still up, Dima")
    }

    func testTheGreetingWorksWithoutAName() {
        XCTAssertEqual(DailyBriefing.greeting(name: nil, now: at(hour: 8)), "Good morning")
        XCTAssertEqual(DailyBriefing.greeting(name: "", now: at(hour: 8)), "Good morning")
    }

    // MARK: - Lead

    /// The next meeting is the only item on this screen with a time that cannot
    /// be moved, so it leads whenever the day still holds one.
    func testTheNextMeetingLeads() {
        let meeting = meeting(title: "Weekly planning", daysAgo: 1)
        let facts = DailyBriefing.facts(
            meetings: [meeting],
            actionItems: [item(meetingID: meeting.id, text: "Send the deck", done: false)],
            events: [event(title: "Design sync", from: 3600, to: 7200)],
            now: now
        )

        XCTAssertEqual(facts.lead?.title, "Design sync")
    }

    func testACommitmentLeadsOnADayWithNoMeetingsLeft() {
        let meeting = meeting(title: "Weekly planning", daysAgo: 1)
        let facts = DailyBriefing.facts(
            meetings: [meeting],
            actionItems: [item(meetingID: meeting.id, text: "Send the deck", done: false)],
            events: [],
            now: now
        )

        XCTAssertEqual(facts.lead?.title, "Send the deck")
    }

    /// Said once. The lead is drawn above the groups, and leaving it in them
    /// too is the duplication this screen was rebuilt to remove.
    func testTheLeadIsNotRepeatedBelow() {
        let facts = DailyBriefing.facts(
            meetings: [],
            actionItems: [],
            events: [
                event(title: "Design sync", from: 3600, to: 7200),
                event(title: "Retro", from: 4 * 3600, to: 5 * 3600)
            ],
            now: now
        )

        XCTAssertEqual(facts.rest.ahead.map(\.title), ["Retro"])
    }

    func testTheCountdownGivesUpBeyondAWorkingStretch() {
        XCTAssertEqual(DailyBriefing.countdown(to: now.addingTimeInterval(2400), from: now), "In 40 min")
        XCTAssertEqual(DailyBriefing.countdown(to: now.addingTimeInterval(5400), from: now), "In 1h 30m")
        XCTAssertEqual(DailyBriefing.countdown(to: now.addingTimeInterval(-60), from: now), "Now")
        XCTAssertNil(DailyBriefing.countdown(to: now.addingTimeInterval(8 * 3600), from: now))
    }

    // MARK: - Ambient context

    /// Titles only, and read from the plan rather than the digest — the digest
    /// is what costs a second round trip to fetch window *bodies* the briefing
    /// then throws away.
    @MainActor func testScreenLinesCarryTheTitle() {
        let lines = DailyBriefing.screenLines(from: plan(title: "Q3 pricing deck – Figma", captures: 24))

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Q3 pricing deck"))
    }

    /// Captures are one every five seconds, so the count is dwell time.
    @MainActor func testDwellIsReadFromTheCaptureCount() {
        XCTAssertTrue(DailyBriefing.screenLines(from: plan(title: "Notes", captures: 24))[0].contains("about 2m"))
        XCTAssertTrue(DailyBriefing.screenLines(from: plan(title: "Notes", captures: 1440))[0].contains("about 2h"))
    }

    /// A window with no title is nothing a summary can name, and "untitled
    /// window for 2h" is worse than saying nothing about the day at all.
    @MainActor func testAnUntitledWindowIsDropped() {
        XCTAssertTrue(DailyBriefing.screenLines(from: plan(title: "   ", captures: 60)).isEmpty)
    }

    @MainActor func testNothingCapturedIsNoLines() {
        XCTAssertTrue(DailyBriefing.screenLines(from: ScreenActivityPlan(apps: [])).isEmpty)
    }

    // MARK: - Fixtures

    private func at(hour: Int) -> Date {
        guard let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: now) else {
            return now
        }
        return date
    }

    private func plan(title: String, captures: Int) -> ScreenActivityPlan {
        ScreenActivityPlan(apps: [
            ScreenActivityPlan.App(
                bundleID: "com.figma.Desktop",
                windows: [
                    ScreenActivityPlan.Window(
                        title: title,
                        firstSeen: now,
                        lastSeen: now,
                        captures: captures,
                        candidateHashes: []
                    )
                ],
                captures: captures
            )
        ])
    }

    private func event(
        title: String,
        from start: TimeInterval,
        to end: TimeInterval,
        attendees: [CalendarAttendee] = []
    ) -> CalendarOccurrence {
        CalendarOccurrence(
            title: title,
            startsAt: now.addingTimeInterval(start),
            endsAt: now.addingTimeInterval(end),
            host: nil,
            attendees: attendees
        )
    }

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

    private func item(meetingID: UUID, text: String, done: Bool) -> ActionItem {
        ActionItem(
            id: meetingID,
            meetingID: meetingID,
            userID: UUID(),
            text: text,
            deadline: nil,
            position: 0,
            done: done,
            doneAt: done ? now : nil,
            createdAt: now,
            updatedAt: nil,
            deletedAt: nil
        )
    }
}
