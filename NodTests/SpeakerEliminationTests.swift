import XCTest
@testable import Nod

/// Naming the last voice by arithmetic. The equality between cluster count and
/// attendee count is the whole safety argument, so most of these are about it
/// refusing to answer.
final class SpeakerEliminationTests: XCTestCase {
    private func calendar(_ names: [String]) -> MeetingParticipants {
        MeetingParticipants(names: names, expectedOtherVoices: names.count, source: .calendar)
    }

    func testNamesTheOnlyVoiceOnAOneToOne() {
        // The case this exists for: two people who know each other never say
        // each other's names, so the naming pass has nothing to work from.
        let closed = MeetingParticipants.closingTheGap([:], clusters: [1], people: calendar(["Anna"]))
        XCTAssertEqual(closed, ["1": "Anna"])
    }

    func testNamesTheLastVoiceWhenTheRestWereNamed() {
        let closed = MeetingParticipants.closingTheGap(
            ["1": "Anna"],
            clusters: [1, 2],
            people: calendar(["Anna", "Leo"])
        )
        XCTAssertEqual(closed, ["1": "Anna", "2": "Leo"])
    }

    func testDeclinesWhenAnInviteeNeverJoined() {
        // Three invited, two voices heard — the spare attendee is the one who
        // did not come, not the unnamed cluster.
        let named = ["1": "Anna"]
        XCTAssertEqual(
            MeetingParticipants.closingTheGap(named, clusters: [1, 2], people: calendar(["Anna", "Leo", "Mira"])),
            named
        )
    }

    func testDeclinesWhenSomebodyUninvitedSpoke() {
        let named = ["1": "Anna"]
        XCTAssertEqual(
            MeetingParticipants.closingTheGap(named, clusters: [1, 2, 3], people: calendar(["Anna", "Leo"])),
            named
        )
    }

    func testDeclinesWhenTwoVoicesAreStillUnnamed() {
        let named = ["1": "Anna"]
        XCTAssertEqual(
            MeetingParticipants.closingTheGap(named, clusters: [1, 2, 3], people: calendar(["Anna", "Leo", "Mira"])),
            named
        )
    }

    func testDeclinesWhenANameCameFromTheRoomRatherThanTheInvitation() {
        // The pass named a cluster after somebody being discussed. The counts
        // still line up, and pairing the leftovers would be wrong.
        let named = ["1": "Priya"]
        XCTAssertEqual(
            MeetingParticipants.closingTheGap(named, clusters: [1, 2], people: calendar(["Anna", "Leo"])),
            named
        )
    }

    func testLeavesAFullyNamedMeetingAlone() {
        let named = ["1": "Anna", "2": "Leo"]
        XCTAssertEqual(
            MeetingParticipants.closingTheGap(named, clusters: [1, 2], people: calendar(["Anna", "Leo"])),
            named
        )
    }

    func testDeclinesForAConferencingAppRoster() {
        // The window lists everyone including the user and cannot say which
        // entry is them, while the clusters are the `them` stream only. Left to
        // arithmetic, an over-split would stamp the user's own name onto
        // somebody else's voice.
        let roster = MeetingParticipants(
            names: ["Anna", "Dima"],
            expectedOtherVoices: 1,
            source: .conferencingApp
        )
        XCTAssertEqual(MeetingParticipants.closingTheGap(["1": "Anna"], clusters: [1, 2], people: roster), ["1": "Anna"])
    }

    func testDeclinesWithoutAnInvitation() {
        XCTAssertEqual(MeetingParticipants.closingTheGap([:], clusters: [1], people: calendar([])), [:])
    }

    func testMatchesNamesRegardlessOfCase() {
        let closed = MeetingParticipants.closingTheGap(
            ["1": "anna"],
            clusters: [1, 2],
            people: calendar(["Anna", "Leo"])
        )
        XCTAssertEqual(closed["2"], "Leo")
    }
}
