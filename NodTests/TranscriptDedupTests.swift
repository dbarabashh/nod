import XCTest
@testable import Nod

final class TranscriptDedupTests: XCTestCase {
    private func bleed(_ a: String, _ b: String) -> Bool {
        TranscriptStore.isAcousticBleed(TranscriptStore.wordSet(a), TranscriptStore.wordSet(b))
    }

    func testIdenticalTextMatches() {
        XCTAssertTrue(bleed(
            "we should ship the onboarding flow",
            "we should ship the onboarding flow"
        ))
    }

    func testHighJaccardOverlapMatches() {
        XCTAssertTrue(bleed(
            "move the meeting to thursday afternoon please",
            "move the meeting to thursday afternoon everyone"
        ))
    }

    func testContainmentMatchesWhenJaccardIsBelowThreshold() {
        // Mic echo tacks on words from the next breath: the short line is a
        // near-subset of the long one (containment 1.0) while Jaccard is
        // 7/12 ≈ 0.58 — below the symmetric threshold.
        XCTAssertTrue(bleed(
            "we should ship the new onboarding flow next week after design review",
            "we should ship the new onboarding flow"
        ))
    }

    func testShortBlipDoesNotLatchOntoLongerTurn() {
        // "yeah okay" is fully contained, but under dedupMinContainmentWords.
        XCTAssertFalse(bleed(
            "yeah we should okay the budget and the hiring plan this week",
            "yeah okay"
        ))
    }

    func testGenuineCrossTalkSurvives() {
        XCTAssertFalse(bleed(
            "the deploy pipeline broke again last night",
            "did you see the design review notes from sarah"
        ))
    }

    func testEmptySideNeverMatches() {
        XCTAssertFalse(bleed("", "anything at all here"))
        XCTAssertFalse(bleed("anything at all here", ""))
    }

    func testWordSetLowercasesAndStripsPunctuation() {
        XCTAssertEqual(
            TranscriptStore.wordSet("Hello, world! HELLO."),
            ["hello", "world"]
        )
    }

    func testWordSetKeepsAlphanumerics() {
        XCTAssertEqual(
            TranscriptStore.wordSet("Q3 numbers: 42%"),
            ["q3", "numbers", "42"]
        )
    }
}
