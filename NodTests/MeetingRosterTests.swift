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

    /// Separator and ellipsis labels are everywhere in a conferencing window's
    /// accessibility tree, and each one that reads as a name inflates the
    /// speaker count clustering is handed.
    func testRejectsPunctuationOnlyCandidates() {
        for label in ["..", "...", "''", "--", ".'-", "-.-"] {
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

    /// The user's own voice arrives on the mic, so the `them` stream holds one
    /// fewer voice than the roster names.
    func testExpectedThemSpeakersExcludesTheUser() {
        let roster = MeetingRoster(app: .zoom, participants: ["Dima", "Vlad", "Pasha", "Sergiy"])

        XCTAssertEqual(MeetingSession.expectedThemSpeakers(in: roster), 3)
    }

    /// Zero means "unknown" and sends clustering to its threshold — a one-person
    /// roster is no more informative than none.
    func testExpectedThemSpeakersIsZeroWhenTheRosterCannotInform() {
        XCTAssertEqual(MeetingSession.expectedThemSpeakers(in: nil), 0)
        XCTAssertEqual(
            MeetingSession.expectedThemSpeakers(in: MeetingRoster(app: .zoom, participants: ["Dima"])),
            0
        )
    }

    /// The bug this ordering exists for: Slack sits open all day and sorts ahead
    /// of every browser, so a Google Meet call in Chrome used to be shadowed by
    /// it — one app was picked, it named nobody, and the search ended there.
    /// Chrome has to stay in the list so the caller can fall through to it.
    func testBrowsersStayInTheListBehindNativeApps() {
        let order = MeetingRosterReader.rosterOrder(
            [(app: .slack, pid: 1), (app: .chrome, pid: 2)],
            inCall: []
        )

        XCTAssertEqual(order.map(\.app), [.slack, .chrome])
    }

    /// A call-only helper process is proof, not a guess, so that app is asked
    /// first even though a browser otherwise sorts last.
    func testAnAppConfirmedInACallLeads() {
        let order = MeetingRosterReader.rosterOrder(
            [(app: .slack, pid: 1), (app: .zoom, pid: 2), (app: .chrome, pid: 3)],
            inCall: [.chrome]
        )

        XCTAssertEqual(order.map(\.app), [.chrome, .slack, .zoom])
    }

    /// Discord's windows are DMs and server channels, not a roster — walking
    /// them harvests person-shaped strings out of private conversation.
    func testAppsThatExposeNoRosterAreNeverAsked() {
        let order = MeetingRosterReader.rosterOrder(
            [(app: .discord, pid: 1), (app: .chrome, pid: 2)],
            inCall: [.discord]
        )

        XCTAssertEqual(order.map(\.app), [.chrome])
    }

    /// A different app is a different call — the earlier names belong to it, not
    /// to this one.
    func testMergingADifferentAppReplacesRatherThanUnions() {
        let zoom = MeetingRoster(app: .zoom, participants: ["Dima", "Vlad"])
        let teams = MeetingRoster(app: .teams, participants: ["Mike"])

        XCTAssertEqual(zoom.merging(teams), teams)
    }
}
