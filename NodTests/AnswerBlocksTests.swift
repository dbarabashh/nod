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

    /// A paragraph used to be held until a *second* one started, which meant a
    /// one-paragraph answer — most of what the launcher gets — showed nothing
    /// at all until the stream ended, with its words already arrived.
    func testAFinishedSentenceIsShownWithoutWaitingForASecondParagraph() {
        XCTAssertTrue(AnswerBlocks.hasComplete(in: "First paragraph."))
        XCTAssertEqual(AnswerBlocks.complete(in: "First paragraph.", isFinished: false), ["First paragraph."])
    }

    /// Showing sooner, not showing something unfinished: a clause still in
    /// flight stays off screen.
    func testAnUnfinishedSentenceIsStillHeldBack() {
        XCTAssertTrue(AnswerBlocks.complete(in: "The answer is", isFinished: false).isEmpty)
        XCTAssertTrue(AnswerBlocks.complete(in: "Halfway through a sen", isFinished: false).isEmpty)
    }

    /// While the rest of the paragraph is still coming, only its finished
    /// sentences are shown — never the half-written one after them.
    func testOnlyTheFinishedSentencesOfALoneParagraphAreShown() {
        let streaming = "It shipped on Tuesday. Leo pushed back on the pric"

        XCTAssertEqual(AnswerBlocks.complete(in: streaming, isFinished: false), ["It shipped on Tuesday."])
    }

    /// Once a second paragraph exists the old rule stands: the trailing one is
    /// the one being written, and it waits.
    func testASecondParagraphRestoresTheParagraphRule() {
        let streamed = "First paragraph.\n\nSecond is still being writ"

        XCTAssertEqual(AnswerBlocks.complete(in: streamed, isFinished: false), ["First paragraph."])
    }

    func testFinishedSentencesHandleTheEndingsPeopleActuallyType() {
        XCTAssertEqual(AnswerBlocks.finishedSentences(in: "Really? Yes, and"), "Really?")
        XCTAssertEqual(AnswerBlocks.finishedSentences(in: "Wait…  more"), "Wait…")
        XCTAssertNil(AnswerBlocks.finishedSentences(in: "no ending yet"))
    }
}

extension AnswerBlocksTests {
    /// A sentence the model abandoned leaves its bracket on a line of its own.
    /// Drawn, it becomes a paragraph, and the answer reads as if the app broke.
    func testStrandedPunctuationLinesAreDropped() {
        let block = "A finished point.\n.\n.\n)\n- **Next point** — with its own text."

        let pieces = AnswerPiece.pieces(from: block, at: 0)

        XCTAssertEqual(pieces.count, 2)
        if case let .prose(text) = pieces[0].content {
            XCTAssertEqual(String(text.characters), "A finished point.")
        } else {
            XCTFail("expected the surviving sentence as prose")
        }
        guard case let .list(items) = pieces[1].content else { return XCTFail("expected a list") }
        XCTAssertEqual(items.count, 1)
    }

    /// The rule case reads `---` before the punctuation drop can swallow it.
    func testHorizontalRuleSurvivesTheDrop() {
        let pieces = AnswerPiece.pieces(from: "Above.\n---\nBelow.", at: 0)

        XCTAssertEqual(pieces.count, 3)
        guard case .rule = pieces[1].content else { return XCTFail("expected a rule") }
    }
}
