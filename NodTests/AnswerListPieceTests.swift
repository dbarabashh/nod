import XCTest
@testable import Nod

/// Block markdown the inline parser cannot see: headings at any depth, and
/// lists with their nesting. These pin that a report's `### ` and `- ` reach
/// the screen as a heading and a bullet, not as hashes and a dash.
final class AnswerListPieceTests: XCTestCase {
    private func pieces(_ block: String) -> [AnswerPiece.Content] {
        AnswerPiece.pieces(from: block, at: 0).map(\.content)
    }

    private func items(_ block: String) -> [AnswerPiece.ListItem] {
        for piece in pieces(block) {
            if case let .list(items) = piece { return items }
        }
        return []
    }

    func testEveryHeadingDepthIsAHeading() {
        for line in ["# One", "## Two", "### Three", "#### Four"] {
            guard case let .heading(title) = pieces(line).first else { return XCTFail(line) }
            XCTAssertEqual(title, String(line.split(separator: " ")[1]))
        }
    }

    func testHashesWithoutASpaceStayProse() {
        guard case .prose = pieces("#hashtag").first else { return XCTFail("a bare hashtag is not a heading") }
    }

    func testDashItemsBecomeBulletsWithTheirDepth() {
        let list = items("- Outer\n  - Inner\n    - Deeper\n- Outer again")
        XCTAssertEqual(list.map(\.level), [0, 1, 2, 0])
        XCTAssertEqual(list.map(\.marker), ["•", "•", "•", "•"])
        XCTAssertEqual(String(list[1].text.characters), "Inner")
    }

    func testNumbersKeepTheirNumber() {
        let list = items("1. First\n2. Second\n10) Tenth")
        XCTAssertEqual(list.map(\.marker), ["1.", "2.", "10."].prefix(2) + ["10."])
    }

    func testAWrappedLineStaysWithItsItem() {
        let list = items("- A long item\n  that wraps\n- Next")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(String(list[0].text.characters), "A long item that wraps")
    }

    func testInlineMarkdownInsideAnItemStillRenders() {
        let list = items("- **Bold** lead")
        let bold = list[0].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertTrue(bold)
    }

    func testAHeadingThenAListThenProseAreThreePieces() {
        let kinds = pieces("### What you worked on\n- One\n- Two\nA closing line").map { piece -> String in
            switch piece {
            case .heading: "heading"
            case .list: "list"
            case .prose: "prose"
            case .links: "links"
            case .rule: "rule"
            }
        }
        XCTAssertEqual(kinds, ["heading", "list", "prose"])
    }

    func testADashInsideASentenceIsNotAList() {
        guard case .prose = pieces("Rates - and fees - vary").first else { return XCTFail("mid-sentence dash") }
    }
}
