import XCTest
@testable import Nod

final class AnswerBlocksTests: XCTestCase {
    /// The paragraph still being written is never shown — that's the whole
    /// point of splitting on blank lines rather than on characters.
    func testTheTrailingBlockIsHeldBackWhileStreaming() {
        let partial = "First paragraph, finished.\n\nSecond one is still bei"

        XCTAssertEqual(
            AnswerBlocks.complete(in: partial, isFinished: false),
            ["First paragraph, finished."]
        )
    }

    func testNothingIsShownUntilTheFirstParagraphCloses() {
        XCTAssertTrue(AnswerBlocks.complete(in: "Halfway through a sen", isFinished: false).isEmpty)
        XCTAssertTrue(AnswerBlocks.complete(in: "", isFinished: false).isEmpty)
    }

    func testFinishingReleasesEveryBlock() {
        let whole = "One.\n\nTwo.\n\nThree."

        XCTAssertEqual(AnswerBlocks.complete(in: whole, isFinished: true), ["One.", "Two.", "Three."])
    }

    /// A list is single newlines, so it survives as one block and lands whole —
    /// items appearing one at a time would be the typewriter effect again.
    func testAListStaysOneBlock() {
        let streamed = "**Стан дашборду**\n- перше\n- друге\n\n**Наступне**\n- поки пишет"

        XCTAssertEqual(
            AnswerBlocks.complete(in: streamed, isFinished: false),
            ["**Стан дашборду**\n- перше\n- друге"]
        )
    }

    /// Markdown must never be revealed with its closing marks missing.
    func testUnclosedEmphasisIsNeverRevealed() {
        let streamed = "Done paragraph.\n\nThis one has **bold that is not yet"
        let shown = AnswerBlocks.complete(in: streamed, isFinished: false)

        XCTAssertEqual(shown, ["Done paragraph."])
        XCTAssertFalse(shown.contains { $0.contains("**bold") })
    }

    func testBlankRunsAndTrailingNewlinesDoNotProduceEmptyBlocks() {
        let messy = "One.\n\n\n\nTwo.\n\n"

        XCTAssertEqual(AnswerBlocks.complete(in: messy, isFinished: true), ["One.", "Two."])
    }

    /// The bubble decides whether to appear from `hasComplete` and then renders
    /// from `complete`. A blank line with nothing after it used to satisfy the
    /// first and not the second, so the bubble drew its chrome around nothing.
    func testHasCompleteAgreesWithWhatTheRendererWouldShow() {
        for text in ["First paragraph.\n\n", "Still one paragraph.", "", "Trailing blanks.\n\n\n\n"] {
            XCTAssertEqual(
                AnswerBlocks.hasComplete(in: text),
                !AnswerBlocks.complete(in: text, isFinished: false).isEmpty,
                "disagreed on \(text.debugDescription)"
            )
        }
    }

    func testHasCompleteWaitsForASecondParagraphToStart() {
        XCTAssertFalse(AnswerBlocks.hasComplete(in: "First paragraph.\n\n"))
        XCTAssertTrue(AnswerBlocks.hasComplete(in: "First paragraph.\n\nSecond starts"))
    }
}
