import XCTest
@testable import Nod

/// A reference to a connected product is drawn as a row — the product's mark,
/// the title as text, an arrow that says it opens somewhere. These pin the
/// question of *when* that happens, because the answer used to be "only when a
/// paragraph is nothing but references", and the model almost never writes one.
final class AnswerLinkPieceTests: XCTestCase {
    private let link = "[NOD-93 — Retire communications-v1 consent branches](https://linear.app/nod/issue/NOD-93)"

    private func kinds(_ block: String) -> [String] {
        AnswerPiece.pieces(from: block, at: 0).map { piece in
            switch piece.content {
            case .prose: "prose"
            case .links: "links"
            case .heading: "heading"
            case .rule: "rule"
            case .list: "list"
            }
        }
    }

    func testAReferenceOnItsOwnLineIsDrawnAsARow() {
        XCTAssertEqual(kinds(link), ["links"])
    }

    /// The case from the screenshot: a sentence, then the ticket it names, in
    /// one paragraph. This used to render the ticket as blue markdown text.
    func testASentenceFollowedByItsReferenceSplitsInTwo() {
        XCTAssertEqual(kinds("- **Consent:** уже є відкрита задача\n\(link)"), ["list", "links"])
    }

    func testSeveralReferencesUnderOneSentenceStayOneRow() {
        let second = "[NOD-71 — Review product analytics rollout](https://linear.app/nod/issue/NOD-71)"

        XCTAssertEqual(kinds("Here is what I found:\n\(link)\n\(second)"), ["prose", "links"])
        XCTAssertEqual(AnswerPiece.pieces(from: "Here:\n\(link)\n\(second)", at: 0).count, 2)
    }

    func testProseAfterAReferenceIsItsOwnPiece() {
        XCTAssertEqual(kinds("Found it:\n\(link)\nWant me to close it?"), ["prose", "links", "prose"])
    }

    func testPlainProseStaysOnePiece() {
        XCTAssertEqual(kinds("Nothing was filed for this one.\nIt is still open."), ["prose"])
    }

    /// The case from the Linear screenshot: the model puts the issue's state
    /// after the link. That is a reference with a note, not markdown prose.
    func testAReferenceWithAStatusAfterItIsARowWithANote() {
        let pieces = AnswerPiece.pieces(from: "- \(link) — In Progress", at: 0)
        guard case let .links(items) = pieces.first?.content else { return XCTFail("expected a links piece") }
        XCTAssertEqual(items.map(\.note), ["In Progress"])
        XCTAssertEqual(items.map(\.title), ["NOD-93 — Retire communications-v1 consent branches"])
    }

    func testANoteInBracketsLosesItsBrackets() {
        XCTAssertEqual(ProviderLinkItem.item(in: "\(link) (Todo)")?.note, "Todo")
        XCTAssertEqual(ProviderLinkItem.item(in: "\(link): assigned to Vlad")?.note, "assigned to Vlad")
    }

    /// A reference inside a sentence stays in the sentence: the paragraph is
    /// one prose piece, and the link is drawn inline by `ReferenceText`.
    func testAReferenceInsideASentenceStaysProse() {
        XCTAssertEqual(kinds("Ще є \(link), але вона на Владі, не на тобі."), ["prose"])
        XCTAssertEqual(kinds("\(link) is the one that blocks the release."), ["prose"])
    }

    /// A link to somewhere Nod has no integration for is not a reference — it
    /// stays markdown, where a normal link belongs.
    func testAnUnknownHostIsNotAReference() {
        XCTAssertEqual(kinds("[Some article](https://example.com/post)"), ["prose"])
    }

    /// Identity is the piece's address, so a streaming answer can append without
    /// re-diffing what is already on screen.
    func testPiecesFromOneBlockGetDistinctIds() {
        let pieces = AnswerPiece.pieces(from: "Found it:\n\(link)\nAnything else?", at: 3)

        XCTAssertEqual(pieces.map(\.id), ["3.0", "3.1", "3.2"])
    }
}
