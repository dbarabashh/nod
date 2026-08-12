import XCTest
@testable import Nod

/// The prompt tells the model that OPEN ACTION ITEMS is the user's real task
/// list. That is true of what was *said* and false of what is *tracked* — and it
/// is why the chat once answered "yes, you have three tasks" without ever asking
/// Linear. These pin the correction.
final class ConnectedToolsPromptTests: XCTestCase {
    func testNoToolsBlockWhenNothingIsConnected() {
        let prompt = PromptLibrary.buildKnowledgeSystem(excerpts: ["something was said"])

        XCTAssertFalse(prompt.contains("[CONNECTED TOOLS]"))
    }

    func testConnectedProductIsNamedAndSeparatedFromWhatWasSaid() {
        let tools = ChatTools.definitions(for: [.linear])
        XCTAssertFalse(tools.isEmpty)

        let prompt = PromptLibrary.buildKnowledgeSystem(
            excerpts: ["something was said"],
            connectedTools: tools
        )

        XCTAssertTrue(prompt.contains("[CONNECTED TOOLS]"))
        XCTAssertTrue(prompt.contains("Linear"))
        XCTAssertTrue(prompt.contains("not evidence of what is TRACKED"))
    }

    /// The definitions ride in the cached prompt prefix, so the same set of
    /// connections has to produce the same bytes every turn or the cache is
    /// rewritten on each question.
    func testToolOrderIsStable() {
        let first = ChatTools.definitions(for: [.linear]).map(\.name)
        let second = ChatTools.definitions(for: [.linear]).map(\.name)

        XCTAssertEqual(first, second)
    }

    func testToolNameCarriesItsProviderAndAction() {
        let search = ChatTools.definitions(for: [.linear]).first { $0.name == "linear_search_issues" }

        XCTAssertEqual(search?.provider, .linear)
        XCTAssertEqual(search?.action, "search_issues")
        XCTAssertEqual(search?.mutating, false)
    }
}
