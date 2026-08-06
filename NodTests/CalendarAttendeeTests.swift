import XCTest
@testable import Nod

/// Measured on a real calendar before the thresholds here were chosen: of 67
/// people invited across two months, 22 carried a display name and 45 only an
/// address — 10 of those `first.last`, 34 a single token (all but two between
/// three and eight letters), one with digits, none a role address.
final class CalendarAttendeeTests: XCTestCase {
    private func display(_ name: String) -> String {
        CalendarAttendee.display(from: name)
    }

    // MARK: - A display name is already the answer

    func testADisplayNameIsKept() {
        XCTAssertEqual(display("Dmytro Barabash"), "Dmytro Barabash")
    }

    func testSomethingHoldingAnAddressIsNotTreatedAsOne() {
        XCTAssertEqual(display("Sales <sales@example.com>"), "Sales <sales@example.com>")
    }

    // MARK: - Reading a name out of an address

    func testFirstAndLastAreSeparated() {
        XCTAssertEqual(display("dmytro.barabash@example.com"), "Dmytro Barabash")
        XCTAssertEqual(display("dmytro_barabash@example.com"), "Dmytro Barabash")
        XCTAssertEqual(display("dmytro-barabash@example.com"), "Dmytro Barabash")
    }

    func testASingleTokenIsAGivenName() {
        XCTAssertEqual(display("dmytro@hellonod.app"), "Dmytro")
    }

    func testALoneLetterReadsAsAnInitial() {
        XCTAssertEqual(display("d.barabash@example.com"), "D. Barabash")
    }

    func testAPlusTagIsNotPartOfTheName() {
        XCTAssertEqual(display("dmytro.barabash+work@example.com"), "Dmytro Barabash")
    }

    func testCaseIsNormalised() {
        XCTAssertEqual(display("DMYTRO.BARABASH@example.com"), "Dmytro Barabash")
    }

    // MARK: - When the address holds no name, it stays an address

    /// A run-together first and last cannot be split without guessing where,
    /// and "Dbarabashh" reads as a person Nod is confused about.
    func testARunTogetherNameStaysAnAddress() {
        XCTAssertEqual(display("dbarabashh@gmail.com"), "dbarabashh@gmail.com")
    }

    func testARoleAddressIsNeverAPerson() {
        XCTAssertEqual(display("info@example.com"), "info@example.com")
        XCTAssertEqual(display("no-reply@example.com"), "no-reply@example.com")
    }

    func testDigitsMeanItIsNotAName() {
        XCTAssertEqual(display("dmytro2024@example.com"), "dmytro2024@example.com")
    }

    func testTooShortToBeAGivenName() {
        XCTAssertEqual(display("db@example.com"), "db@example.com")
    }

    func testTooManyPartsToBeAName() {
        XCTAssertEqual(display("a.b.c.d@example.com"), "a.b.c.d@example.com")
    }

    // MARK: - Who the meeting is with

    func testOthersExcludesTheUser() {
        let occurrence = CalendarOccurrence(
            title: "Analytics Platform Catch Up",
            startsAt: Date(),
            endsAt: Date().addingTimeInterval(900),
            host: .meet,
            attendees: [
                CalendarAttendee(display: "Dmytro", isSelf: true),
                CalendarAttendee(display: "Leo Fischer", isSelf: false),
                CalendarAttendee(display: "Anna Kovalenko", isSelf: false),
                CalendarAttendee(display: "sam@example.com", isSelf: false)
            ]
        )
        XCTAssertEqual(occurrence.others.count, 3)
        XCTAssertFalse(occurrence.others.contains { $0.isSelf })
    }
}

/// Who a recording is with, and how many voices other than the user's it holds.
/// The calendar and the conferencing app's window both answer, and they are not
/// equal: the window returned sixteen "participants" for a call with four.
final class MeetingParticipantsTests: XCTestCase {
    private func occurrence(_ people: [(String, Bool)]) -> CalendarOccurrence {
        CalendarOccurrence(
            title: "Analytics Platform Catch Up",
            startsAt: Date(),
            endsAt: Date().addingTimeInterval(900),
            host: .meet,
            attendees: people.map { CalendarAttendee(display: $0.0, isSelf: $0.1) }
        )
    }

    func testTheCalendarWinsAndExcludesTheUser() {
        let people = MeetingParticipants.resolve(
            calendar: occurrence([("Dmytro", true), ("Leo Fischer", false), ("Anna Kovalenko", false)]),
            roster: MeetingRoster(app: .chrome, participants: ["Back", "Forward", "Reload"])
        )
        XCTAssertEqual(people.source, .calendar)
        XCTAssertEqual(people.names, ["Leo Fischer", "Anna Kovalenko"])
        XCTAssertEqual(people.expectedOtherVoices, 2)
    }

    /// A blocked-out hour with nobody invited says nothing about the room, so it
    /// does not get to overrule a window that does.
    func testAnEmptyEntryDoesNotOverruleTheWindow() {
        let people = MeetingParticipants.resolve(
            calendar: occurrence([("Dmytro", true)]),
            roster: MeetingRoster(app: .zoom, participants: ["Dima", "Leo", "Anna"])
        )
        XCTAssertEqual(people.source, .conferencingApp)
        XCTAssertEqual(people.expectedOtherVoices, 2)
    }

    func testNoCalendarFallsBackToTheWindow() {
        let people = MeetingParticipants.resolve(
            calendar: nil,
            roster: MeetingRoster(app: .zoom, participants: ["Dima", "Leo"])
        )
        XCTAssertEqual(people.source, .conferencingApp)
        XCTAssertEqual(people.expectedOtherVoices, 1)
    }

    /// Zero means *unknown*, so clustering picks its own threshold rather than
    /// being pinned to a number nothing supports.
    func testNeitherSourceLeavesTheCountUnknown() {
        XCTAssertEqual(MeetingParticipants.resolve(calendar: nil, roster: nil), .unknown)
        XCTAssertEqual(MeetingParticipants.unknown.expectedOtherVoices, 0)
    }
}

final class CallContextTests: XCTestCase {
    func testNamesAreListedInProse() {
        XCTAssertEqual(CallContext(brief: nil, attendees: ["Leo"]).withLine, "With Leo")
        XCTAssertEqual(CallContext(brief: nil, attendees: ["Leo", "Anna"]).withLine, "With Leo and Anna")
        XCTAssertEqual(
            CallContext(brief: nil, attendees: ["Leo", "Anna", "Sam"]).withLine,
            "With Leo, Anna and Sam"
        )
    }

    /// Past three, the count carries the rest — knowing there are six people is
    /// what changes how you walk in.
    func testALongListBecomesACount() {
        let many = ["Leo", "Anna", "Sam", "Kate", "Ivan", "Olha"]
        XCTAssertEqual(CallContext(brief: nil, attendees: many).withLine, "With Leo, Anna and 4 others")
    }

    func testNothingToSayIsEmpty() {
        XCTAssertTrue(CallContext.none.isEmpty)
        XCTAssertNil(CallContext.none.withLine)
    }
}
