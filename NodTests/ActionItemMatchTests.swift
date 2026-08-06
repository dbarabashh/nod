import XCTest
@testable import Nod

/// `ActionItemDedup.same` decides whether the recap has just restated something
/// the live pass already wrote down. A false match loses one of the recap's
/// actions silently, so these lean on the side of "not the same".
final class ActionItemMatchTests: XCTestCase {
    func testIdenticalTextMatches() {
        XCTAssertTrue(ActionItemDedup.same("Send Anna the pricing deck", "Send Anna the pricing deck"))
    }

    func testShortIdenticalTextMatchesBelowTheTokenFloor() {
        // One meaningful token survives tokenization ("it" is dropped), so the
        // shared-token floor alone would reject a sentence against itself.
        XCTAssertTrue(ActionItemDedup.same("ship it", "ship it"))
    }

    func testAOneOrTwoCharacterDifferenceIsNotIdenticalText() {
        // The identical-text check runs on the raw words. On token sets these
        // collapse to the same single token, and the recap's action would be
        // silently absorbed into an unrelated live finding.
        XCTAssertFalse(ActionItemDedup.same("ship v2", "ship v3"))
        XCTAssertFalse(ActionItemDedup.same("email Jo", "email Al"))
    }

    func testIdenticalTextMatchesAcrossCaseAndSpacing() {
        XCTAssertTrue(ActionItemDedup.same("Ship  the\nbuild", "ship the build"))
    }

    func testReorderedWordingMatches() {
        XCTAssertTrue(ActionItemDedup.same(
            "Send Anna the pricing deck",
            "Send the pricing deck to Anna"
        ))
    }

    func testDifferentTasksAboutTheSameThingDoNotMatch() {
        XCTAssertFalse(ActionItemDedup.same(
            "Send Anna the pricing deck",
            "Rebuild the pricing deck for the board"
        ))
    }

    func testUnrelatedTasksDoNotMatch() {
        XCTAssertFalse(ActionItemDedup.same(
            "Move the release ticket to next sprint",
            "Mock up the pricing page in Figma"
        ))
    }

    func testOneSharedWordDoesNotMatch() {
        XCTAssertFalse(ActionItemDedup.same("finish login", "design login"))
    }

    func testEmptyTextNeverMatches() {
        XCTAssertFalse(ActionItemDedup.same("", ""))
        XCTAssertFalse(ActionItemDedup.same("Ship the build", ""))
    }
}
