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

    func testTheRecapRestatingALiveFindingMatches() {
        // The real pair from the 2026-08-07 call, which scored 0.67 and was
        // missed by the old 0.70 threshold — so the recap's action was inserted
        // fresh and the live finding was written off as an over-read.
        XCTAssertTrue(ActionItemDedup.same(
            "Create a comparison table for Blend research (comparing Telnyx and the server) and send it to Mike before making changes.",
            "Start the Blend vs. Telnyx/server comparison table and send it to Mike before making any changes."
        ))
    }

    func testTwoDifferentTasksFromTheSameCallStillDoNotMatch() {
        // The nearest unrelated pair on that same call scored 0.23.
        XCTAssertFalse(ActionItemDedup.same(
            "Fix the issue summary to stop reading and properly label the issue brief.",
            "Investigate Blend (the tool shared during the call) — evaluate latency and voice quality against current requirements."
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
