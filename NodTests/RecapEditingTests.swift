import XCTest
@testable import Nod

/// Correcting a recap rewrites the typed one and re-renders the markdown from
/// it. These pin the typed half — the half every other screen reads.
final class RecapEditingTests: XCTestCase {
    private func recap() -> MeetingRecap {
        MeetingRecap(sections: [
            MeetingRecap.Section(title: "Decisions", bullets: [
                MeetingRecap.Bullet(text: "Eric owns the migration", quote: "Eric will take the migration"),
                MeetingRecap.Bullet(text: "Ship on Friday")
            ]),
            MeetingRecap.Section(title: "Open questions", bullets: [
                MeetingRecap.Bullet(text: "Who signs off on pricing?")
            ])
        ])
    }

    private func bullet(_ section: Int, _ bullet: Int) -> MeetingRecap.BulletID {
        MeetingRecap.BulletID(section: section, bullet: bullet)
    }

    func testCorrectingALineKeepsEverythingElse() {
        let edited = recap().replacing(bullet(0, 0), with: "Erik owns the migration")

        XCTAssertEqual(edited.sections[0].bullets[0].text, "Erik owns the migration")
        XCTAssertEqual(edited.sections[0].bullets[1].text, "Ship on Friday")
        XCTAssertEqual(edited.sections[1].bullets[0].text, "Who signs off on pricing?")
    }

    /// The quote is the transcript's own words, kept so a reader can check the
    /// line against them. Once the line is somebody's correction, the quote
    /// stands behind nothing — leaving it would dress an edit up as something
    /// the recording confirms.
    func testCorrectingALineDropsItsQuote() {
        let edited = recap().replacing(bullet(0, 0), with: "Erik owns the migration")

        XCTAssertNil(edited.sections[0].bullets[0].quote)
        XCTAssertEqual(recap().sections[0].bullets[0].quote, "Eric will take the migration")
    }

    func testClearingALineRemovesIt() {
        let edited = recap().replacing(bullet(0, 1), with: "   ")

        XCTAssertEqual(edited.sections[0].bullets.map(\.text), ["Eric owns the migration"])
    }

    /// A heading with nothing under it is not a heading.
    func testEmptyingASectionRemovesTheHeading() {
        let edited = recap().replacing(bullet(1, 0), with: "")

        XCTAssertEqual(edited.sections.map(\.title), ["Decisions"])
    }

    func testAnOutOfRangeEditChangesNothing() {
        let original = recap()

        XCTAssertEqual(original.replacing(bullet(9, 0), with: "nope"), original)
        XCTAssertEqual(original.replacing(bullet(0, 9), with: "nope"), original)
    }

    func testActionItemsSurviveAnEdit() {
        let withActions = MeetingRecap(
            sections: recap().sections,
            actionItems: [MeetingRecap.Action(text: "Send the deck", owner: "Vlad")]
        )

        let edited = withActions.replacing(bullet(0, 0), with: "Erik owns it")

        XCTAssertEqual(edited.actionItems.map(\.text), ["Send the deck"])
    }

    /// The markdown is re-rendered from the typed recap, so the correction
    /// reaches the notch and the share viewer, which read that string.
    func testTheRenderedMarkdownCarriesTheCorrection() {
        let markdown = recap().replacing(bullet(0, 0), with: "Erik owns the migration").toMarkdown()

        XCTAssertTrue(markdown.contains("Erik owns the migration"))
        XCTAssertFalse(markdown.contains("Eric"))
    }
}
