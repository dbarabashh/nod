import XCTest
@testable import Nod

final class MeetingRosterTests: XCTestCase {
    func testStripsConferencingAnnotations() {
        XCTAssertEqual(MeetingRosterReader.stripAnnotations("Dima Barabash (Host, me)"), "Dima Barabash")
        XCTAssertEqual(MeetingRosterReader.stripAnnotations("Аліна"), "Аліна")
    }

    func testAcceptsPersonShapedNames() {
        XCTAssertTrue(MeetingRosterReader.isPersonName("Dima Barabash"))
        XCTAssertTrue(MeetingRosterReader.isPersonName("Аліна"))
        XCTAssertTrue(MeetingRosterReader.isPersonName("Jean-Luc Picard"))
        XCTAssertTrue(MeetingRosterReader.isPersonName("J. Smith"))
    }

    func testRejectsInterfaceControls() {
        for label in ["Mute", "Participants", "Share Screen", "Leave Meeting", "Chat"] {
            XCTAssertFalse(MeetingRosterReader.isPersonName(label), "\(label) should not read as a person")
        }
    }

    func testRejectsStringsWithDigitsOrSentenceShape() {
        XCTAssertFalse(MeetingRosterReader.isPersonName("Meeting 4821"))
        XCTAssertFalse(MeetingRosterReader.isPersonName("recording in progress"))
        XCTAssertFalse(MeetingRosterReader.isPersonName("A really long sentence that is clearly not a name"))
        XCTAssertFalse(MeetingRosterReader.isPersonName("x"))
    }

    func testParticipantNamesDeduplicatesKeepingOrder() {
        let texts = [
            "Participants",
            "Dima Barabash (me)",
            "Mute",
            "Аліна",
            "Dima Barabash",
            "Leave"
        ]

        XCTAssertEqual(MeetingRosterReader.participantNames(in: texts), ["Dima Barabash", "Аліна"])
    }

    func testEmptyTreeYieldsNoNames() {
        XCTAssertTrue(MeetingRosterReader.participantNames(in: []).isEmpty)
        XCTAssertTrue(MeetingRosterReader.participantNames(in: ["Mute", "Chat"]).isEmpty)
    }

    func testBrowsersAreReadOnlyThroughAMeetingWindow() {
        for browser in [ConferencingApp.chrome, .safari, .arc, .edge] {
            XCTAssertTrue(browser.isBrowser, "\(browser.displayName) must be window-scoped")
        }
        for native in [ConferencingApp.zoom, .teams, .webex, .slack] {
            XCTAssertFalse(native.isBrowser)
        }
    }

    func testRecognisesMeetingWindowTitles() {
        XCTAssertTrue(MeetingRosterReader.isMeetingWindowTitle("Meet – abc-defg-hij"))
        XCTAssertTrue(MeetingRosterReader.isMeetingWindowTitle("Standup - Google Meet"))
        XCTAssertTrue(MeetingRosterReader.isMeetingWindowTitle("meet.google.com/abc-defg-hij"))
        XCTAssertTrue(MeetingRosterReader.isMeetingWindowTitle("Zoom Meeting"))
        XCTAssertTrue(MeetingRosterReader.isMeetingWindowTitle("Microsoft Teams"))
    }

    func testUnrecognisedWindowTitlesAreNotRead() {
        // The predicate is the only thing keeping the reader out of other tabs,
        // so anything it doesn't recognise must read nothing.
        XCTAssertFalse(MeetingRosterReader.isMeetingWindowTitle("Gmail — Inbox (243)"))
        XCTAssertFalse(MeetingRosterReader.isMeetingWindowTitle("Online Banking"))
        XCTAssertFalse(MeetingRosterReader.isMeetingWindowTitle(""))
        XCTAssertFalse(MeetingRosterReader.isMeetingWindowTitle("meeting notes.md"))
    }

    func testRosterCountsEveryParticipantIncludingTheUser() {
        let roster = MeetingRoster(app: .zoom, participants: ["Dima", "Аліна", "Ярік"])

        XCTAssertEqual(roster.speakerCount, 3)
    }

    /// The case the whole re-sampling loop exists for: the first walk lands
    /// before everyone has joined.
    func testMergingKeepsLateJoiners() {
        let early = MeetingRoster(app: .zoom, participants: ["Dima"])
        let later = MeetingRoster(app: .zoom, participants: ["Dima", "Vlad", "Pasha"])

        XCTAssertEqual(early.merging(later).participants, ["Dima", "Vlad", "Pasha"])
    }

    /// Someone who drops off early is still in the audio, so a later, shorter
    /// sample must not shrink the count the clustering pass is given.
    func testMergingKeepsParticipantsWhoLeft() {
        let full = MeetingRoster(app: .zoom, participants: ["Dima", "Vlad", "Pasha"])
        let afterOneLeft = MeetingRoster(app: .zoom, participants: ["Dima", "Vlad"])

        XCTAssertEqual(full.merging(afterOneLeft).speakerCount, 3)
    }

    func testMergingIsCaseInsensitiveAndKeepsFirstSeenOrder() {
        let first = MeetingRoster(app: .teams, participants: ["Dima", "Vlad"])
        let second = MeetingRoster(app: .teams, participants: ["VLAD", "Pasha", "dima"])

        XCTAssertEqual(first.merging(second).participants, ["Dima", "Vlad", "Pasha"])
    }

    /// A different app is a different call — the earlier names belong to it, not
    /// to this one.
    func testMergingADifferentAppReplacesRatherThanUnions() {
        let zoom = MeetingRoster(app: .zoom, participants: ["Dima", "Vlad"])
        let teams = MeetingRoster(app: .teams, participants: ["Mike"])

        XCTAssertEqual(zoom.merging(teams), teams)
    }
}
