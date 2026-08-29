import XCTest
@testable import Nod

/// `privacy.md` § 3.11 gives Nod's two calendar sources an off-switch each and
/// says neither implies the other. The code disagreed: the General switch — the
/// one that governs the macOS Calendars permission — also suppressed a calendar
/// account connected through Integrations.
///
/// It was silent, and it cost more than the meeting offer. Without an
/// invitation at recording time, `MeetingParticipants` falls back to the
/// conferencing window, which knows neither how many people are on the call nor
/// which of them is the user — so `SpeakerDiarizer` clusters by distance
/// threshold instead of a pinned count, and `closingTheGap` refuses to name
/// anybody.
@MainActor
final class CalendarSourceTests: XCTestCase {
    private func service(switchedOn: Bool) throws -> CalendarService {
        let suite = "nod.tests.calendar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(switchedOn, forKey: CalendarService.defaultsKey)
        return CalendarService(defaults: defaults)
    }

    private var anEvent: CalendarOccurrence {
        CalendarOccurrence(
            title: "Weekly planning",
            startsAt: Date(),
            endsAt: Date().addingTimeInterval(1800),
            host: .meet,
            attendees: []
        )
    }

    /// The regression. Onboarding asks only for Google, and never shows the
    /// General switch — so this is the state every user who followed it lands in.
    func testAConnectedCalendarIsASourceWithTheMacSwitchOff() throws {
        let calendar = try service(switchedOn: false)
        calendar.remote = .preview([anEvent])
        XCTAssertTrue(calendar.hasAnySource)
    }

    func testNoSourceWhenNothingIsConnectedAndTheSwitchIsOff() throws {
        let calendar = try service(switchedOn: false)
        calendar.remote = .preview([])
        XCTAssertFalse(calendar.hasAnySource)
    }

    /// The switch still governs what it is documented to govern: EventKit needs
    /// both it and the macOS grant, and a service with neither reads nothing.
    func testTheMacSwitchAloneDoesNotMakeTheDeviceCalendarReadable() throws {
        let calendar = try service(switchedOn: true)
        XCTAssertNotEqual(calendar.status, .authorized, "test host must not hold the Calendars grant")
        XCTAssertFalse(calendar.isReadable)
        XCTAssertFalse(calendar.hasAnySource)
    }

    /// The watcher subscribes to this, so it has to move on its own when a
    /// connected calendar loads its first events — not only when the switch does.
    func testTheSourceAnswerMovesWhenAConnectedCalendarLoads() throws {
        let calendar = try service(switchedOn: false)
        let remote = RemoteCalendar.preview([])
        calendar.remote = remote
        XCTAssertFalse(calendar.hasAnySource)

        let loaded = expectation(description: "hasAnySource turns true")
        let observer = calendar.$hasAnySource.dropFirst().sink { if $0 { loaded.fulfill() } }
        remote.adopt([anEvent])
        wait(for: [loaded], timeout: 1)
        observer.cancel()
    }
}
