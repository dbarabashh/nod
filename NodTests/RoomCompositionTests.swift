import XCTest
@testable import Nod

/// The gate that decides whether a connected tool may be read onto the screen.
/// Every case here is about the same question: does *not knowing* open the gate
/// or close it. It closes it.
final class RoomCompositionTests: XCTestCase {
    private let colleagues = RoomComposition.colleagueAddresses(["anna@acme.com", "Tom@Acme.com"])

    private func attendee(_ email: String?, isSelf: Bool = false) -> CalendarAttendee {
        CalendarAttendee(display: email ?? "Someone", isSelf: isSelf, email: email)
    }

    func testEveryoneIsAColleague() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true), attendee("anna@acme.com"), attendee("tom@acme.com")],
            colleagues: colleagues,
            anyRemoteSpeech: true, callInProgress: true
        )

        XCTAssertEqual(room, .colleaguesOnly)
        XCTAssertTrue(room.mayReadFreely)
    }

    /// The case the whole gate exists for: a customer on the call while a
    /// tracker would be read onto a shared screen.
    func testOneOutsiderClosesIt() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true), attendee("anna@acme.com"), attendee("buyer@other.com")],
            colleagues: colleagues,
            anyRemoteSpeech: true, callInProgress: true
        )

        XCTAssertEqual(room, .outsidersPresent)
        XCTAssertFalse(room.mayReadFreely)
    }

    /// A calendar server and a directory disagree about case constantly, and a
    /// match that fails on capitalisation would close the gate on a colleague.
    func testAddressesMatchRegardlessOfCase() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true), attendee("ANNA@acme.com")],
            colleagues: colleagues,
            anyRemoteSpeech: true, callInProgress: true
        )

        XCTAssertEqual(room, .colleaguesOnly)
    }

    /// An attendee a local calendar names without an address cannot be checked
    /// against anything, so they are an outsider — not a colleague by default.
    func testAnAttendeeWithNoAddressIsAnOutsider() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true), attendee(nil)],
            colleagues: colleagues,
            anyRemoteSpeech: true, callInProgress: true
        )

        XCTAssertEqual(room, .outsidersPresent)
    }

    /// Nobody invited, but voices are coming out of the speakers — a call Nod
    /// was never invited to. Somebody is there; the invitation just cannot name
    /// them, which is the one thing that could have made this safe.
    func testAnUninvitedCallIsExternal() {
        XCTAssertEqual(
            RoomComposition.of(attendees: [], colleagues: colleagues, anyRemoteSpeech: true, callInProgress: true),
            .outsidersPresent
        )
        XCTAssertEqual(
            RoomComposition.of(
                attendees: [attendee("me@acme.com", isSelf: true)],
                colleagues: colleagues,
                anyRemoteSpeech: true, callInProgress: true
            ),
            .outsidersPresent
        )
    }

    /// Nobody invited and nothing on the speakers: one person at their own Mac.
    /// There is no audience, so there is nothing to disclose to — and this is
    /// most recordings, which is why the first cut refusing here made the whole
    /// feature look broken to the person testing it alone.
    func testRecordingAloneReadsFreely() {
        let room = RoomComposition.of(attendees: [], colleagues: colleagues, anyRemoteSpeech: false, callInProgress: nil)

        XCTAssertEqual(room, .solo)
        XCTAssertTrue(room.mayReadFreely)
    }

    /// Same, for a calendar entry that only ever had the user on it.
    func testAnEntryWithOnlyYouIsStillSolo() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true)],
            colleagues: colleagues,
            anyRemoteSpeech: false, callInProgress: nil
        )

        XCTAssertEqual(room, .solo)
    }

    /// The invitation still decides once anybody else is on it. A customer
    /// invited to a call that has not started talking yet is not solo.
    func testAnInvitedOutsiderOutranksSilence() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true), attendee("buyer@other.com")],
            colleagues: colleagues,
            anyRemoteSpeech: false, callInProgress: nil
        )

        XCTAssertEqual(room, .outsidersPresent)
    }

    /// A directory that has not loaded yet must not read as "nobody works here".
    func testAnEmptyDirectoryClosesIt() {
        let room = RoomComposition.of(
            attendees: [attendee("me@acme.com", isSelf: true), attendee("anna@acme.com")],
            colleagues: [],
            anyRemoteSpeech: true, callInProgress: true
        )

        XCTAssertEqual(room, .outsidersPresent)
    }

    func testAddressesAreNormalisedAndBlanksDropped() {
        XCTAssertEqual(
            RoomComposition.colleagueAddresses([" Anna@Acme.com ", nil, "", "  "]),
            ["anna@acme.com"]
        )
    }

    /// The reported bug: a YouTube video playing during a recording made every
    /// integration in the notch answer "Not everyone here is from your team".
    func testMediaPlayingIsNotAnAudience() {
        XCTAssertEqual(
            RoomComposition.of(attendees: [], colleagues: [], anyRemoteSpeech: true, callInProgress: false),
            .solo
        )
    }

    func testAVoiceDuringACallIsStillAnAudience() {
        XCTAssertEqual(
            RoomComposition.of(attendees: [], colleagues: [], anyRemoteSpeech: true, callInProgress: true),
            .outsidersPresent
        )
    }

    /// The gate has to shut on every way of not knowing — a detector that has
    /// not looked yet, or that lost the Screen Recording grant, reports nil.
    func testADetectorThatCannotTellKeepsTheGateShut() {
        XCTAssertEqual(
            RoomComposition.of(attendees: [], colleagues: [], anyRemoteSpeech: true, callInProgress: nil),
            .outsidersPresent
        )
    }

    func testSilenceIsNeverAnAudienceWhateverTheDetectorSays() {
        for verdict in [true, false, nil] {
            XCTAssertEqual(
                RoomComposition.of(attendees: [], colleagues: [], anyRemoteSpeech: false, callInProgress: verdict),
                .solo
            )
        }
    }
}
