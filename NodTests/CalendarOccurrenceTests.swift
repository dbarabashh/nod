import XCTest
@testable import Nod

final class CalendarOccurrenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    // MARK: - Which event the call belongs to

    func testPicksTheEventThatIsRunningNow() {
        let running = occurrence("Weekly planning", startsIn: -5, lasts: 30)
        let next = occurrence("Pricing workshop", startsIn: 25, lasts: 30)
        XCTAssertEqual(best(of: [next, running])?.title, "Weekly planning")
    }

    func testPicksAnEventAboutToStart() {
        let upcoming = occurrence("Weekly planning", startsIn: 4, lasts: 30)
        XCTAssertEqual(best(of: [upcoming])?.title, "Weekly planning")
    }

    func testIgnoresAnEventThatHasNotComeCloseYet() {
        XCTAssertNil(best(of: [occurrence("Weekly planning", startsIn: 45, lasts: 30)]))
    }

    func testIgnoresAnEventThatIsOver() {
        XCTAssertNil(best(of: [occurrence("Weekly planning", startsIn: -60, lasts: 30)]))
    }

    /// A fenced-off afternoon is working time, not the call that just started.
    func testIgnoresABlockLongerThanAnAfternoon() {
        XCTAssertNil(best(of: [occurrence("Focus time", startsIn: -30, lasts: 5 * 60)]))
    }

    // MARK: - Telling two candidates apart

    func testTheAppTheCallIsInBreaksATie() {
        let zoom = occurrence("Board review", startsIn: -2, lasts: 60, host: .zoom)
        let meet = occurrence("Design sync", startsIn: -2, lasts: 60, host: .meet)
        XCTAssertEqual(best(of: [meet, zoom], app: .zoom)?.title, "Board review")
    }

    /// A native app names its product. A browser hosts all of them, so it must
    /// not be read as a constraint — doing so ruled out the right event rather
    /// than narrowing to it.
    func testABrowserDoesNotConstrainTheChoice() {
        let running = occurrence("Design sync", startsIn: -2, lasts: 60, host: .meet)
        let upcoming = occurrence("Board review", startsIn: 5, lasts: 60, host: .zoom)
        XCTAssertEqual(best(of: [upcoming, running], app: .chrome)?.title, "Design sync")
    }

    /// The invite with a call link beats the bare "hold" block sitting on top
    /// of it — the ordinary shape of a busy calendar.
    func testAnEventWithACallLinkBeatsOneWithout() {
        let hold = occurrence("Hold", startsIn: -3, lasts: 60)
        let real = occurrence("Board review", startsIn: -3, lasts: 60, host: .zoom)
        XCTAssertEqual(best(of: [hold, real])?.title, "Board review")
    }

    func testEquallyLikelyEventsResolveToTheNearestStart() {
        let earlier = occurrence("Board review", startsIn: -20, lasts: 60)
        let nearer = occurrence("Design sync", startsIn: -2, lasts: 60)
        XCTAssertEqual(best(of: [earlier, nearer])?.title, "Design sync")
    }

    /// At the moment a call is noticed nothing has been recorded, so every
    /// candidate overlaps by zero and `hasStarted` is what decides. Without it
    /// the nearer *upcoming* entry wins over the one already under way.
    func testAnEntryAlreadyUnderWayBeatsANearerOneStillToStart() {
        let running = occurrence("Board review", startsIn: -8, lasts: 60)
        let upcoming = occurrence("Design sync", startsIn: 5, lasts: 60)
        XCTAssertEqual(best(of: [upcoming, running])?.title, "Board review")
    }

    func testAnEmptyCalendarSaysNothing() {
        XCTAssertNil(best(of: []))
    }

    // MARK: - Reading a link out of an invite

    func testFindsTheProductNamedInAnInvite() {
        XCTAssertEqual(ConferencingHost.named(in: "Join: https://acme.zoom.us/j/12345"), .zoom)
        XCTAssertEqual(ConferencingHost.named(in: "https://meet.google.com/abc-defg-hij"), .meet)
        XCTAssertEqual(ConferencingHost.named(in: "https://teams.microsoft.com/l/meetup-join/x"), .teams)
        XCTAssertNil(ConferencingHost.named(in: "Room 4, second floor"))
    }

    func testOnlyANativeAppImpliesAProduct() {
        XCTAssertEqual(ConferencingHost.implied(by: .zoom), .zoom)
        XCTAssertEqual(ConferencingHost.implied(by: .teamsClassic), .teams)
        XCTAssertNil(ConferencingHost.implied(by: .chrome))
        XCTAssertNil(ConferencingHost.implied(by: .slack))
    }

    // MARK: - Fixtures

    private func best(of occurrences: [CalendarOccurrence], app: ConferencingApp = .chrome) -> CalendarOccurrence? {
        CalendarOccurrence.ranked(occurrences, overlapping: DateInterval(start: now, duration: 0), app: app).first
    }

    private func occurrence(
        _ title: String,
        startsIn minutes: Double,
        lasts duration: Double,
        host: ConferencingHost? = nil
    ) -> CalendarOccurrence {
        let startsAt = now.addingTimeInterval(minutes * 60)
        return CalendarOccurrence(
            title: title,
            startsAt: startsAt,
            endsAt: startsAt.addingTimeInterval(duration * 60),
            host: host,
            attendees: []
        )
    }
}

/// The calendar entry is not settled when a recording starts — people create the
/// invite minutes before, halfway through, or once everyone has hung up. So the
/// match is made against the span captured, and asked again as that span grows.
final class CalendarSpanMatchingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    private func occurrence(_ title: String, from: Double, lasts: Double, host: ConferencingHost? = nil) -> CalendarOccurrence {
        let startsAt = now.addingTimeInterval(from * 60)
        return CalendarOccurrence(
            title: title,
            startsAt: startsAt,
            endsAt: startsAt.addingTimeInterval(lasts * 60),
            host: host,
            attendees: []
        )
    }

    private func span(from: Double, to: Double) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(from * 60), end: now.addingTimeInterval(to * 60))
    }

    /// The recording covers 14:00–14:16. One entry covers almost all of it, the
    /// other clipped the very start.
    func testTheEntryCoveringMostOfTheRecordingWins() {
        let real = occurrence("Analytics Platform Catch Up", from: 0, lasts: 15)
        let brushed = occurrence("Earlier call", from: -55, lasts: 56)
        let ranked = CalendarOccurrence.ranked([brushed, real], overlapping: span(from: 0, to: 16), app: nil)
        XCTAssertEqual(ranked.first?.title, "Analytics Platform Catch Up")
    }

    /// Created halfway through: the entry starts after the recording did, and
    /// still belongs to it.
    func testAnEntryCreatedMidRecordingStillMatches() {
        let late = occurrence("Analytics Platform Catch Up", from: 6, lasts: 20)
        let ranked = CalendarOccurrence.ranked([late], overlapping: span(from: 0, to: 16), app: nil)
        XCTAssertEqual(ranked.first?.title, "Analytics Platform Catch Up")
    }

    /// An entry that ran an hour earlier is not this recording, however tempting.
    func testAnUnrelatedEntryIsNotOffered() {
        let unrelated = occurrence("Morning standup", from: -120, lasts: 30)
        XCTAssertTrue(CalendarOccurrence.ranked([unrelated], overlapping: span(from: 0, to: 16), app: nil).isEmpty)
    }

    /// The case the user has six times a fortnight: two entries genuinely
    /// competing. Both are returned so the choice can be put to them.
    func testCompetingEntriesAreAllReturnedBestFirst() {
        let hold = occurrence("Doctor", from: 0, lasts: 60)
        let real = occurrence("GHW Claim Automation Weekly Sync", from: 0, lasts: 60, host: .meet)
        let ranked = CalendarOccurrence.ranked([hold, real], overlapping: span(from: 0, to: 30), app: nil)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.title, "GHW Claim Automation Weekly Sync")
    }
}
