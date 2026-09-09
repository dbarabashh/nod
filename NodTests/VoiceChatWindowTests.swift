import XCTest
@testable import Nod

final class VoiceChatWindowTests: XCTestCase {
    func testKeepsAtMostFiveTurns() {
        XCTAssertEqual(KnowledgeChatStore.turnsToDrop(count: 10, maxTurns: 5), 0)
        XCTAssertEqual(KnowledgeChatStore.turnsToDrop(count: 12, maxTurns: 5), 2)
        XCTAssertEqual(KnowledgeChatStore.turnsToDrop(count: 2, maxTurns: 5), 0)
        XCTAssertEqual(KnowledgeChatStore.turnsToDrop(count: 0, maxTurns: 5), 0)
    }
}
