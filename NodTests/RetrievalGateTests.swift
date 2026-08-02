import XCTest
@testable import Nod

@MainActor
final class SourceCitationTests: XCTestCase {
    private func chunk(_ similarity: Double, _ id: UUID = UUID()) -> RetrievedChunk {
        RetrievedChunk(meetingID: id, content: "passage", similarity: similarity)
    }

    func testNothingRetrievedCitesNothing() {
        XCTAssertTrue(KnowledgeChatStore.worthCiting([]).isEmpty)
    }

    /// The reported case: a question the corpus has no answer to, answered from
    /// the screen. Retrieval still returns its top-k, all of it near the floor —
    /// naming any of it as a source is a false claim.
    func testWeakMatchesAreNotCited() {
        let weak = [chunk(0.38), chunk(0.34), chunk(0.31)]

        XCTAssertTrue(KnowledgeChatStore.worthCiting(weak).isEmpty)
    }

    func testStrongMatchesAreCited() {
        let strong = [chunk(0.72), chunk(0.66), chunk(0.58)]

        XCTAssertEqual(KnowledgeChatStore.worthCiting(strong).count, 3)
    }

    /// Clearing the absolute floor isn't enough next to a much better match.
    func testWeakMatchesBesideAStrongOneAreDropped() {
        let mixed = [chunk(0.78), chunk(0.61), chunk(0.47)]

        XCTAssertEqual(KnowledgeChatStore.worthCiting(mixed).map(\.similarity), [0.78, 0.61])
    }

    func testTheBestMatchIsAlwaysCited() {
        let single = [chunk(0.51)]

        XCTAssertEqual(KnowledgeChatStore.worthCiting(single).count, 1)
    }
}
