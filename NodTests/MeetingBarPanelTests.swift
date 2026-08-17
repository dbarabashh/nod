import XCTest
@testable import Nod

/// The Ask box outlives the panel it was typed into. Every assertion here is a
/// report we already had once: a question re-typed because the answer was
/// dropped while the user looked at Notes, or an answer sitting behind a button
/// that gave no sign it was there.
final class MeetingBarPanelTests: XCTestCase {
    func testAnswerLandingBehindNotesIsMarkedUnseen() {
        var panel = MeetingBarPanel()
        panel.expand(.ask)
        panel.startAsking()
        panel.expand(.notes)

        panel.land(.answered(question: "who owns this?", answer: "Naz"))

        XCTAssertTrue(panel.isAnswerUnseen)
    }

    func testAnswerWatchedArrivingIsNotMarkedUnseen() {
        var panel = MeetingBarPanel()
        panel.expand(.ask)
        panel.startAsking()

        panel.land(.answered(question: "who owns this?", answer: "Naz"))

        XCTAssertFalse(panel.isAnswerUnseen)
    }

    func testOpeningTheBoxClearsTheMark() {
        var panel = MeetingBarPanel()
        panel.startAsking()
        panel.land(.answered(question: "who owns this?", answer: "Naz"))
        XCTAssertTrue(panel.isAnswerUnseen)

        panel.expand(.ask)

        XCTAssertFalse(panel.isAnswerUnseen)
    }

    func testAskingAgainDropsTheMarkFromTheLastAnswer() {
        var panel = MeetingBarPanel()
        panel.startAsking()
        panel.land(.answered(question: "who owns this?", answer: "Naz"))

        panel.startAsking()

        XCTAssertFalse(panel.isAnswerUnseen)
    }

    /// Folding Ask away and pressing it again must land on the answer, not on
    /// an empty field — the whole point of keeping `ask` beside `expansion`.
    func testFoldingTheBoxAwayKeepsTheAnswer() {
        var panel = MeetingBarPanel()
        panel.expand(.ask)
        panel.startAsking()
        panel.land(.answered(question: "who owns this?", answer: "Naz"))

        panel.expand(.passive)
        panel.expand(.ask)

        XCTAssertEqual(panel.ask, .answered(question: "who owns this?", answer: "Naz"))
    }

    /// `NotchStateContent` identifies its content by this string, and a new
    /// identity throws the Ask field's own state away — including a follow-up
    /// question typed while the previous answer was still coming.
    func testIdentityDoesNotChangeAsTheAskProgresses() {
        var panel = MeetingBarPanel()
        panel.expand(.ask)
        let composing = panel.contentID

        panel.startAsking()
        XCTAssertEqual(panel.contentID, composing)

        panel.land(.answered(question: "who owns this?", answer: "Naz"))
        XCTAssertEqual(panel.contentID, composing)
    }

    func testIdentityStillSeparatesTheThreePanels() {
        var panel = MeetingBarPanel()
        let passive = panel.contentID
        panel.expand(.notes)
        let notes = panel.contentID
        panel.expand(.ask)

        XCTAssertEqual(Set([passive, notes, panel.contentID]).count, 3)
    }

    /// An answer arriving while the bar is folded away must not drag the surface
    /// back open, and a phase change must not resize it either.
    func testWidthFollowsTheExpandedPanelOnly() {
        var panel = MeetingBarPanel()
        panel.expand(.ask)
        let width = panel.surfaceWidth

        panel.startAsking()
        panel.land(.answered(question: "who owns this?", answer: "Naz"))

        XCTAssertEqual(panel.surfaceWidth, width)
    }
}
