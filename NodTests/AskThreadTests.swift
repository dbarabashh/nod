import XCTest
@testable import Nod

final class AskThreadTests: XCTestCase {
    func testEmptyThreadContributesNothingToAPrompt() {
        XCTAssertTrue(AskThread().isEmpty)
        XCTAssertEqual(AskThread().block, "")
    }

    func testTurnsRenderOldestFirst() {
        var thread = AskThread()
        thread.append(question: "Do you have Slack?", answer: "Yes.")
        thread.append(question: "Which channels?", answer: "features, bugs-and-alerts.")

        XCTAssertEqual(thread.block, """
        [EARLIER IN THIS ASK BOX]
        Q: Do you have Slack?
        A: Yes.
        Q: Which channels?
        A: features, bugs-and-alerts.


        """)
    }

    /// A blank answer is what a failed round trip leaves behind. Recording it
    /// would teach the next question that this one went unanswered.
    func testBlankTurnsAreNotRecorded() {
        var thread = AskThread()
        thread.append(question: "Anything?", answer: "   ")
        thread.append(question: "  ", answer: "Something")

        XCTAssertTrue(thread.isEmpty)
    }

    func testOnlyTheLastTurnsAreKept() {
        var thread = AskThread()
        for turn in 1 ... (AskThread.maxTurns + 3) {
            thread.append(question: "Q\(turn)", answer: "A\(turn)")
        }

        XCTAssertEqual(thread.turns.count, AskThread.maxTurns)
        XCTAssertEqual(thread.turns.first?.question, "Q4")
        XCTAssertEqual(thread.turns.last?.question, "Q\(AskThread.maxTurns + 3)")
    }

    /// A "Summarize" answer runs to a paragraph; a follow-up needs to know what
    /// was said, not to re-read all of it in every later prompt.
    func testLongAnswersAreTrimmedInTheBlock() {
        var thread = AskThread()
        thread.append(question: "Summarize", answer: String(repeating: "x", count: 900))

        XCTAssertTrue(thread.block.contains(String(repeating: "x", count: 500)))
        XCTAssertFalse(thread.block.contains(String(repeating: "x", count: 501)))
    }

    func testWhitespaceIsTrimmedOffEachTurn() {
        var thread = AskThread()
        thread.append(question: "  Which channel?\n", answer: "\n features \n")

        XCTAssertEqual(thread.turns.first?.question, "Which channel?")
        XCTAssertEqual(thread.turns.first?.answer, "features")
    }
}
