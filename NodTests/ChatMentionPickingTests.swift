import XCTest
@testable import Nod

@MainActor
final class ChatMentionPickingTests: XCTestCase {
    /// The complaint: typing part of a name has to narrow to it, so Return can
    /// take it without reaching for the mouse.
    func testAPartialNameNarrowsToTheTool() {
        XCTAssertEqual(ChatMentionPicker.tools(matching: "sla"), [.slack])
        XCTAssertEqual(ChatMentionPicker.tools(matching: "gmai"), [.gmail])
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(ChatMentionPicker.tools(matching: "SLACK"), [.slack])
    }

    /// An empty query is the moment just after `@`: the panel is a menu before
    /// it is a search.
    func testAnEmptyQueryOffersEveryTool() {
        XCTAssertEqual(ChatMentionPicker.tools(matching: "").count, IntegrationProvider.allCases.count)
    }

    func testAQueryThatMatchesNothingOffersNothing() {
        XCTAssertTrue(ChatMentionPicker.tools(matching: "zzzz").isEmpty)
    }

    /// Tools lead, because the trigger is reached for them most.
    func testToolsAreOfferedFirst() {
        let picks = ChatMentionPicker.picks(projects: [], sessions: [], tools: [.slack, .gmail])

        XCTAssertEqual(picks.map(\.id), ["tool:slack", "tool:gmail"])
    }

    /// Return resolves by index into this list, so the identity a row draws
    /// with and the one the composer compares have to be the same string.
    func testEveryPickIdentifiesItself() {
        XCTAssertEqual(ChatMentionPick.tool(.slack).id, "tool:slack")
        XCTAssertNotEqual(ChatMentionPick.tool(.slack).id, ChatMentionPick.tool(.gmail).id)
    }
}
