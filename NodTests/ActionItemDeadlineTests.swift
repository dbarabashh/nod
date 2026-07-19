import XCTest
@testable import Nod

final class ActionItemDeadlineTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    /// Noon on the given day of July 2026 unless stated otherwise — meetings
    /// happen mid-day, resolved deadlines land on the day's start.
    private func date(_ day: Int, _ month: Int = 7, _ year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    private func startOfDay(_ day: Int, _ month: Int = 7, _ year: Int = 2026) -> Date {
        calendar.startOfDay(for: date(day, month, year))
    }

    private func display(_ phrase: String, spokenAt: Date, now: Date) -> ActionItemDeadline.Display {
        ActionItemDeadline.display(phrase: phrase, spokenAt: spokenAt, now: now, calendar: calendar)
    }

    func testEndOfWeekGoesOverdueOnceThatWeekPassed() {
        let spoken = date(1) // Wednesday
        let onTime = display("end of week", spokenAt: spoken, now: date(1))
        XCTAssertEqual(onTime.text, "Due Friday")
        XCTAssertEqual(onTime.urgency, .upcoming)

        let late = display("end of week", spokenAt: spoken, now: date(17))
        XCTAssertEqual(late.urgency, .overdue)
        XCTAssertEqual(late.text, "Overdue by 2 weeks")
    }

    func testNextWeekdayResolvesAgainstTheMeetingDay() {
        // Said Wednesday 1 July: "next Tuesday" is 7 July, not 30 June.
        let resolved = ActionItemDeadline.resolve(phrase: "next Tuesday", spokenAt: date(1), calendar: calendar)
        XCTAssertEqual(resolved?.date, startOfDay(7))
        XCTAssertEqual(resolved?.isApproximate, false)
    }

    func testTodayAndTomorrowAreRelativeToTheMeeting() {
        XCTAssertEqual(ActionItemDeadline.resolve(phrase: "by tomorrow", spokenAt: date(1), calendar: calendar)?.date, startOfDay(2))
        XCTAssertEqual(ActionItemDeadline.resolve(phrase: "EOD today", spokenAt: date(1), calendar: calendar)?.date, startOfDay(1))
    }

    func testDueTodayAndTomorrowReadAsImminent() {
        let spoken = date(1)
        XCTAssertEqual(display("tomorrow", spokenAt: spoken, now: date(2)).text, "Due today")
        XCTAssertEqual(display("tomorrow", spokenAt: spoken, now: date(1)).text, "Due tomorrow")
        XCTAssertEqual(display("tomorrow", spokenAt: spoken, now: date(1)).urgency, .imminent)
    }

    func testFuzzyWindowNeverClaimsOverdue() {
        let late = display("next few weeks", spokenAt: date(1), now: date(1, 9))
        XCTAssertEqual(late.urgency, .vague)
        XCTAssertTrue(late.text.hasPrefix("next few weeks · said "), late.text)
    }

    func testUnparseablePhraseStaysVerbatimWhileTheMeetingIsFresh() {
        let fresh = display("when Leo is back", spokenAt: date(1), now: date(4))
        XCTAssertEqual(fresh.text, "when Leo is back")
        XCTAssertEqual(fresh.urgency, .upcoming)
    }

    func testUnparseablePhraseGetsDatedOnceTheMeetingIsOld() {
        let stale = display("when Leo is back", spokenAt: date(1), now: date(20))
        XCTAssertEqual(stale.urgency, .vague)
        XCTAssertEqual(stale.text, "when Leo is back · said 2 weeks ago")
    }

    func testTooltipKeepsTheOriginalWordingAndNamesTheRealDate() {
        let shown = display("end of week", spokenAt: date(1), now: date(30))
        XCTAssertEqual(shown.quote, "Said “end of week”")
        XCTAssertEqual(shown.headline, "Was due Friday, Jul 3")
    }

    func testHeadlineHedgesOnAFuzzyPhrase() {
        XCTAssertEqual(display("next few weeks", spokenAt: date(1), now: date(2)).headline, "Around Wednesday, Jul 22")
    }

    func testSourceLineCarriesMeetingAndTime() {
        let line = ActionItemDeadline.sourceLine(
            quote: "Said “end of week”",
            spokenAt: date(1),
            meetingTitle: "Release Planning"
        )
        // The clock part renders in the viewer's own zone, so assert the shape
        // rather than an hour that moves with the test machine.
        XCTAssertTrue(line.hasPrefix("Said “end of week” · Release Planning · "), line)
        XCTAssertTrue(line.contains(" at "), line)
    }

    func testRelativeOffsets() {
        XCTAssertEqual(ActionItemDeadline.resolve(phrase: "in 3 days", spokenAt: date(1), calendar: calendar)?.date, startOfDay(4))
        XCTAssertEqual(ActionItemDeadline.resolve(phrase: "within 2 weeks", spokenAt: date(1), calendar: calendar)?.date, startOfDay(15))
        XCTAssertEqual(ActionItemDeadline.resolve(phrase: "end of month", spokenAt: date(1), calendar: calendar)?.date, startOfDay(31))
    }

    func testExplicitDateRollsToNextYearWhenAlreadyPast() {
        let resolved = ActionItemDeadline.resolve(phrase: "by January 8", spokenAt: date(1), calendar: calendar)
        XCTAssertEqual(resolved?.date, startOfDay(8, 1, 2027))
    }
}
