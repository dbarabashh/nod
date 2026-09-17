import XCTest
@testable import Nod

/// An answer is one attributed string so that one selection can cross all of
/// it. These pin that every piece lands in that string, and that copying out of
/// it gives back the words rather than the stand-ins TextKit holds for them.
final class AnswerTextTests: XCTestCase {
    private func text(_ markdown: String) -> NSAttributedString {
        AnswerText.attributed(from: AnswerPiece.pieces(in: markdown))
    }

    private func copied(_ text: NSAttributedString, _ range: NSRange? = nil) -> String {
        text.copyable(in: range ?? NSRange(location: 0, length: text.length)).string
    }

    func testEveryParagraphIsInTheOneString() {
        let answer = text("First paragraph.\n\nSecond paragraph.\n\nThird.")
        XCTAssertEqual(answer.string, "First paragraph.\nSecond paragraph.\nThird.")
    }

    func testParagraphsCopyWithTheBlankLineTheyWereWrittenWith() {
        XCTAssertEqual(copied(text("First paragraph.\n\nSecond paragraph.")), "First paragraph.\n\nSecond paragraph.")
    }

    private func spacing(in answer: NSAttributedString, at index: Int) -> CGFloat {
        (answer.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? 0
    }

    func testTheGapBetweenPiecesSitsUnderTheLastLineOfABlockOnly() {
        let answer = text("Line one\nLine two\n\nNext")
        XCTAssertEqual(spacing(in: answer, at: 0), 0)
        XCTAssertEqual(spacing(in: answer, at: (answer.string as NSString).range(of: "Line two").location), 10)
        XCTAssertEqual(spacing(in: answer, at: answer.length - 1), 0)
    }

    /// An answer streams in as a view per piece and finishes as one document.
    /// Both take their gaps from `spacing(above:in:)`; this pins that the two
    /// come out the same height, so finishing moves nothing.
    @MainActor
    func testTheOneDocumentIsAsTallAsThePiecesItStreamedInAs() {
        let pieces = AnswerPiece.pieces(in: """
        A paragraph long enough to wrap onto a second line at this width, which it does.

        ## Heading

        - One
          - Two with [NOD-57](https://linear.app/nod/issue/NOD-57) inline

        ---

        - [NOD-57 — Provide team access](https://linear.app/nod/issue/NOD-57) — In Progress

        Closing.
        """)
        let height = { (pieces: [AnswerPiece]) in
            MentionMeasurer().usedSize(text: "", marks: [], width: 320) { AnswerText.attributed(from: pieces) }.height
        }
        let streamed = pieces.indices.reduce(CGFloat(0)) {
            $0 + AnswerText.spacing(above: $1, in: pieces) + height([pieces[$1]])
        }
        XCTAssertGreaterThan(pieces.count, 5)
        XCTAssertEqual(height(pieces), streamed)
    }

    func testAHeadingIsDrawnInCapitalsAndCopiedAsWritten() {
        let answer = text("## Next steps")
        XCTAssertEqual(answer.string, "NEXT STEPS")
        XCTAssertEqual(copied(answer), "Next steps")
        XCTAssertEqual(copied(answer, NSRange(location: 5, length: 5)), "steps")
    }

    func testAListCopiesWithItsMarkersAndDepth() {
        let answer = text("- Outer\n  - Inner\n1. First")
        XCTAssertEqual(copied(answer), "• Outer\n  • Inner\n1. First")
    }

    func testAReferenceRowCopiesAsItsTitleAndNote() {
        let answer = text("Filed:\n- [NOD-57 — Provide team access](https://linear.app/nod/issue/NOD-57) — In Progress")
        XCTAssertEqual(copied(answer), "Filed:\n\nNOD-57 — Provide team access — In Progress")
        let title = (answer.string as NSString).range(of: "NOD-57")
        XCTAssertEqual(
            answer.attribute(.link, at: title.location, effectiveRange: nil) as? URL,
            URL(string: "https://linear.app/nod/issue/NOD-57")
        )
    }

    func testAnInlineReferenceCopiesAsItsTitleWithItsLink() {
        let answer = text("See [NOD-57](https://linear.app/nod/issue/NOD-57) for the rest.")
        XCTAssertEqual(copied(answer), "See NOD-57 for the rest.")
        let copy = answer.copyable(in: NSRange(location: 0, length: answer.length))
        XCTAssertEqual(copy.attribute(.link, at: 4, effectiveRange: nil) as? URL, URL(string: "https://linear.app/nod/issue/NOD-57"))
    }

    func testARuleCopiesAsARule() {
        XCTAssertEqual(copied(text("Above\n\n---\n\nBelow")), "Above\n\n---\n\nBelow")
    }

    func testTheScreensColoursStayOffThePasteboard() {
        let answer = text("**Bold** and plain")
        let copy = answer.copyable(in: NSRange(location: 0, length: answer.length))
        XCTAssertNil(copy.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        let font = copy.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
    }

    @MainActor
    func testTheTextViewWritesWhatWasReadNotWhatItHolds() {
        let view = MentionText.makeTextView(TranscriptTextView.self)
        view.isSelectable = true
        view.textStorage?.setAttributedString(text("## Next steps\n\nSee [NOD-57](https://linear.app/nod/issue/NOD-57)."))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AnswerTextTests"))
        defer { pasteboard.releaseGlobally() }

        XCTAssertEqual(view.writablePasteboardTypes, [])
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertTrue(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "Next steps\n\nSee NOD-57.")
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
    }

    @MainActor
    func testMovingOnToAnotherBubbleDropsTheSelection() {
        let view = MentionText.makeTextView(TranscriptTextView.self)
        view.textStorage?.setAttributedString(text("Some text"))
        view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertEqual(view.selectedRange().length, 0)
    }

    func testASentMessageCopiesItsMentionsAsTheyWereTyped() {
        let mark = MentionMark(name: "Linear", glyph: .icon("nc-tasks-2"))
        let message = MentionText.attributed(from: "Ask @Linear about it", marks: [mark])
        let copy = message.copyable(in: NSRange(location: 0, length: message.length))
        XCTAssertEqual(copy.string, "Ask @Linear about it")
    }
}
