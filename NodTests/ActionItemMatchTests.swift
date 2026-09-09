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

/// A live finding the recap does not restate is retired — but only when the
/// recap actually worked. One real 25-minute meeting came back with a single
/// action (someone else's) and silently dropped the three the live pass had
/// caught, leaving the meeting with no action items at all.
final class RecapStandingTests: XCTestCase {
    func testAWorkingRecapStillRetiresWhatItDidNotRestate() {
        XCTAssertTrue(ActionItemStore.recapOverrulesLive(recapCount: 2))
        XCTAssertTrue(ActionItemStore.recapOverrulesLive(recapCount: 10))
    }

    func testAThinRecapRetiresNothing() {
        XCTAssertFalse(ActionItemStore.recapOverrulesLive(recapCount: 0))
        XCTAssertFalse(ActionItemStore.recapOverrulesLive(recapCount: 1))
    }
}

/// GitHub's mark is a single near-black silhouette (`#161614`), so drawn as-is
/// it disappeared into the notch. A one-colour dark mark has to take the
/// interface's ink the way Linear's does.
final class ProviderMarkContrastTests: XCTestCase {
    func testTheGithubMarkIsATemplate() {
        XCTAssertEqual(NSImage(named: IntegrationProvider.github.iconName)?.isTemplate, true)
    }

    /// The brand colours must not be flattened into one ink.
    func testColouredMarksAreNotTemplates() {
        for provider in [IntegrationProvider.slack, .googleCalendar, .gmail] {
            XCTAssertEqual(NSImage(named: provider.iconName)?.isTemplate, false, "\(provider)")
        }
    }
}
