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

/// "Help me with this" is a question, not an instruction to file something.
/// The prompt the Today card sends, and the rule the model reads, both say so.
final class CommitmentAskTests: XCTestCase {
    func testAskingAboutACommitmentAsksForTheGroundFirst() {
        let item = ActionItem(
            id: UUID(), meetingID: UUID(), userID: UUID(), text: "Fix the todo status",
            deadline: nil, kind: .action, status: .confirmed, source: .recap,
            revisionOf: nil, evidenceIdx: nil, evidenceQuote: nil, position: 0,
            done: false, doneAt: nil, loopState: .open,
            externalProvider: nil, externalKey: nil, externalURL: nil, externalCreatedAt: nil,
            createdAt: nil, updatedAt: nil, deletedAt: nil
        )
        let prompt = ActionDelegation.askPrompt(for: item, source: "Demo session")
        XCTAssertTrue(prompt.contains("what the session actually said"))
        XCTAssertTrue(prompt.contains("don't create or change anything unless I say so"))
        XCTAssertTrue(prompt.contains("from \"Demo session\""))
        XCTAssertFalse(prompt.contains("move this forward"))
    }
}
