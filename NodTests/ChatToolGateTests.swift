import XCTest
@testable import Nod

/// Both chats reach the same connected products through one gate. These pin the
/// matching step in front of it: a model that names a tool nobody offered must
/// be refused, not guessed at, because the guess is what would send a request
/// on the user's behalf that they never saw described.
final class ChatToolGateTests: XCTestCase {
    private func call(_ name: String) -> ChatToolCall {
        ChatToolCall(id: name, type: "function", function: .init(name: name, arguments: "{}"))
    }

    func testMatchesEveryCallToItsToolInOrder() throws {
        let catalogue = ChatTools.definitions(for: [.linear])
        let names = catalogue.prefix(2).map(\.name)
        try XCTSkipIf(names.count < 2, "Linear needs two tools for this to mean anything")

        let matched = try XCTUnwrap(ChatToolGate.match(names.map(call), in: catalogue))

        XCTAssertEqual(matched.tools.map(\.name), names)
        XCTAssertEqual(matched.provider, .linear)
    }

    func testRefusesACallForAToolThatWasNeverOffered() {
        let catalogue = ChatTools.definitions(for: [.linear])

        XCTAssertNil(ChatToolGate.match([call("linear_invented_action")], in: catalogue))
    }

    /// One unknown call poisons the round rather than being quietly dropped —
    /// running the two the model got right would answer a question it didn't
    /// ask, with an approval card that didn't list the third.
    func testRefusesTheWholeRoundWhenOneCallIsUnknown() throws {
        let catalogue = ChatTools.definitions(for: [.linear])
        let known = try XCTUnwrap(catalogue.first?.name)

        XCTAssertNil(ChatToolGate.match([call(known), call("linear_invented_action")], in: catalogue))
    }

    func testNothingConnectedOffersNothing() {
        XCTAssertTrue(ChatTools.definitions(for: []).isEmpty)
        XCTAssertNil(ChatToolGate.match([call("linear_search_issues")], in: []))
    }
}
