import XCTest
@testable import Nod

/// The calendar block opens at the start of today so "what was my day" can be
/// answered from it — which means it routinely holds events that are already
/// over. Asked "any meetings this week?" at nine on a Wednesday evening, the
/// answer came back "you have one meeting this week" and named a sync that had
/// finished four hours earlier.
///
/// Comparing a timestamp to the clock is the one thing a model should never be
/// asked to do, so the status is computed here and the prompt only has to read
/// the marker.
final class CalendarRecencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func event(from start: TimeInterval, to end: TimeInterval) -> CalendarOccurrence {
        CalendarOccurrence(
            title: "GHW Claim Automation Weekly Sync",
            startsAt: now.addingTimeInterval(start),
            endsAt: now.addingTimeInterval(end),
            host: nil,
            attendees: []
        )
    }

    func testAFinishedEventIsMarkedEnded() {
        let fourHoursAgo = event(from: -5 * 3600, to: -4 * 3600)

        XCTAssertEqual(KnowledgeChatStore.calendarStatus(of: fourHoursAgo, now: now), " [ended]")
    }

    func testAnEventInProgressSaysSo() {
        let running = event(from: -600, to: 3000)

        XCTAssertEqual(KnowledgeChatStore.calendarStatus(of: running, now: now), " [happening now]")
    }

    /// The common case carries no marker at all — most of the window is ahead,
    /// and annotating every line would bury the two that matter.
    func testAnUpcomingEventIsUnmarked() {
        XCTAssertEqual(KnowledgeChatStore.calendarStatus(of: event(from: 3600, to: 7200), now: now), "")
    }

    /// The boundary belongs to the past: an event that ends exactly now is over,
    /// and one that starts exactly now has started.
    func testTheBoundariesResolveTowardsThePast() {
        XCTAssertEqual(KnowledgeChatStore.calendarStatus(of: event(from: -3600, to: 0), now: now), " [ended]")
        XCTAssertEqual(KnowledgeChatStore.calendarStatus(of: event(from: 0, to: 3600), now: now), " [happening now]")
    }

    /// The marker is only worth anything if the prompt tells the model what it
    /// means. Written in two places, a reword on either side would leave a
    /// label nothing explains.
    func testThePromptExplainsBothMarkers() {
        let text = PromptLibrary.buildKnowledgeSystem(excerpts: ["[YOUR CALENDAR — the user's own events]"])

        XCTAssertTrue(text.contains("[ended]"))
        XCTAssertTrue(text.contains("[happening now]"))
    }

    /// And it is the rule that says what to answer from, so the calendar block
    /// does not have to carry a second copy of the same instruction.
    func testTheRuleOwnsWhichLinesAnswerTheQuestion() {
        XCTAssertTrue(PromptLibrary.pastEventsRule.contains("unmarked lines only"))
        XCTAssertTrue(PromptLibrary.pastEventsRule.contains("rest of the period is clear"))
    }

    /// The rule that stops a finished meeting being offered back as upcoming.
    func testTheRuleBindsUpcomingToTheClock() {
        XCTAssertTrue(PromptLibrary.pastEventsRule.contains("The current time in [TODAY]"))
        XCTAssertTrue(PromptLibrary.pastEventsRule.contains("past tense"))
        // A calendar tool can be asked for a window that opens before now, so
        // the rule has to cover its results too, not just the prompt block.
        XCTAssertTrue(PromptLibrary.pastEventsRule.contains("calendar tool returns"))
    }
}
