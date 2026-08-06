import XCTest
@testable import Nod

/// The window in which "your meeting starts now" is true. Earlier is a reminder
/// the calendar already sent; later the user is in the room and the call
/// detector has it.
final class ScheduledMeetingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    private func meeting(startsIn minutes: Double) -> ScheduledMeeting {
        ScheduledMeeting(
            title: "Analytics Platform Catch Up",
            startsAt: now.addingTimeInterval(minutes * 60),
            endsAt: now.addingTimeInterval(minutes * 60 + 900),
            host: .meet,
            others: ["Leo Fischer", "Anna Kovalenko"]
        )
    }

    func testFiresOnTheMinuteItStarts() {
        XCTAssertTrue(meeting(startsIn: 0).isStarting(at: now))
    }

    func testFiresShortlyBefore() {
        XCTAssertTrue(meeting(startsIn: 0.5).isStarting(at: now))
    }

    /// A calendar reminder's job, not Nod's.
    func testStaysQuietWellBeforeTheStart() {
        XCTAssertFalse(meeting(startsIn: 10).isStarting(at: now))
    }

    func testStillFiresJustAfterTheStart() {
        XCTAssertTrue(meeting(startsIn: -2).isStarting(at: now))
    }

    /// Past the grace the user either joined — and the call detector answers —
    /// or they are not coming.
    func testStopsOfferingOnceTheMeetingIsUnderWay() {
        XCTAssertFalse(meeting(startsIn: -10).isStarting(at: now))
    }

    /// Two occurrences of a recurring meeting are different meetings; the same
    /// one seen on the next tick is not.
    func testFingerprintSeparatesOccurrencesNotSightings() {
        XCTAssertEqual(meeting(startsIn: 0).fingerprint, meeting(startsIn: 0).fingerprint)
        XCTAssertNotEqual(meeting(startsIn: 0).fingerprint, meeting(startsIn: -10_080).fingerprint)
    }

    func testBuiltFromACalendarEntryDropsTheUser() {
        let occurrence = CalendarOccurrence(
            title: "Analytics Platform Catch Up",
            startsAt: now,
            endsAt: now.addingTimeInterval(900),
            host: .meet,
            attendees: [
                CalendarAttendee(display: "Dmytro", isSelf: true),
                CalendarAttendee(display: "Leo Fischer", isSelf: false)
            ]
        )
        XCTAssertEqual(ScheduledMeeting(occurrence).others, ["Leo Fischer"])
    }
}

/// The rule that stops one meeting being asked about twice. The two sources
/// cannot share an identity — the calendar knows `title@start`, the detector a
/// bundle id — so the memory is a period of quiet, not a key.
final class MeetingOfferTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_754_000_000)

    private func scheduled(endsIn minutes: Double) -> MeetingOffer {
        .scheduled(ScheduledMeeting(
            title: "Analytics Platform Catch Up",
            startsAt: now,
            endsAt: now.addingTimeInterval(minutes * 60),
            host: .meet,
            others: ["Leo Fischer"]
        ))
    }

    /// The calendar is the better answer wherever both have one: an invitation
    /// is a name and a guest list, a window title is a lottery.
    func testTheCalendarOutranksARunningCall() {
        XCTAssertTrue(scheduled(endsIn: 15).isRicher)
        XCTAssertFalse(MeetingOffer.detected(DetectedCall(app: .zoom, title: "Zoom Meeting")).isRicher)
    }

    /// Two occurrences of a recurring meeting are different offers; the same one
    /// seen twice is not.
    func testIdentitySeparatesMeetingsNotSightings() {
        XCTAssertEqual(scheduled(endsIn: 15).identity, scheduled(endsIn: 15).identity)
        XCTAssertNotEqual(
            scheduled(endsIn: 15).identity,
            MeetingOffer.detected(DetectedCall(app: .zoom, title: nil)).identity
        )
    }

    /// A muted app reaches a calendar entry through its link, which is the only
    /// thing an invitation says about which app a call runs in.
    func testAMutedAppIsReachableFromACalendarLink() {
        XCTAssertEqual(ConferencingHost.nativeApp(.zoom), .zoom)
        XCTAssertEqual(ConferencingHost.nativeApp(.teams), .teams)
        // Meet and Whereby live only in a browser — no app to mute, and nothing
        // the offer can honestly suppress.
        XCTAssertNil(ConferencingHost.nativeApp(.meet))
        XCTAssertNil(ConferencingHost.nativeApp(.whereby))
    }
}
