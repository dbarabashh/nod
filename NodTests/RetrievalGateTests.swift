import XCTest
@testable import Nod

@MainActor
final class RetrievalGateTests: XCTestCase {
    private func chunk(_ similarity: Double, _ id: UUID = UUID()) -> RetrievedChunk {
        RetrievedChunk(meetingID: id, content: "passage", similarity: similarity)
    }

    func testNothingRetrievedGroundsNothing() {
        XCTAssertTrue(KnowledgeChatStore.worthGrounding([]).isEmpty)
    }

    /// The reported case: a question the corpus has no answer to, answered from
    /// the screen. Retrieval still returns its top-k, all of it near the floor —
    /// neither the prompt nor the chips may take it.
    func testWeakMatchesNeverReachTheAnswer() {
        let weak = [chunk(0.38), chunk(0.34), chunk(0.31)]

        XCTAssertTrue(KnowledgeChatStore.worthGrounding(weak).isEmpty)
    }

    func testStrongMatchesReachTheAnswer() {
        let strong = [chunk(0.72), chunk(0.66), chunk(0.58)]

        XCTAssertEqual(KnowledgeChatStore.worthGrounding(strong).count, 3)
    }

    /// Clearing the absolute floor isn't enough next to a much better match.
    func testWeakMatchesBesideAStrongOneAreDropped() {
        let mixed = [chunk(0.78), chunk(0.61), chunk(0.47)]

        XCTAssertEqual(KnowledgeChatStore.worthGrounding(mixed).map(\.similarity), [0.78, 0.61])
    }

    func testTheBestMatchIsAlwaysKept() {
        let single = [chunk(0.51)]

        XCTAssertEqual(KnowledgeChatStore.worthGrounding(single).count, 1)
    }
}
