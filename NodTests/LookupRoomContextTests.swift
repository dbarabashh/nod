import XCTest
@testable import Nod

/// A request typed mid-meeting leaves out what the room has already said. Both
/// lookup calls are given the recent turns so "that ticket" resolves; neither
/// is allowed to answer out of them, because an answer built from the meeting
/// wearing a product's mark is indistinguishable from one the product gave.
final class LookupRoomContextTests: XCTestCase {
    private var linear: [ChatTool] {
        ChatTools.definitions(for: [.linear])
    }

    private let room = "[Me]: what's left on the migration ticket\n[Them]: NOD-14, I think"

    func testRoutingIsGivenTheRoom() {
        let prompt = PromptLibrary.buildLookupRouting(request: "@Linear status?", tools: linear, transcript: room)

        XCTAssertTrue(prompt.user.contains("[IN THE ROOM]"))
        XCTAssertTrue(prompt.user.contains("NOD-14"))
    }

    func testAnsweringIsGivenTheSameRoom() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "status?",
            results: [(tool: "linear_search_issues", body: "NOD-14 — In Progress")],
            memory: [],
            transcript: room
        )

        XCTAssertTrue(prompt.user.contains("[IN THE ROOM]"))
        XCTAssertTrue(prompt.user.contains("NOD-14, I think"))
    }

    /// A meeting with nothing said yet, or a lookup with no window to give,
    /// gets no heading — an empty labelled block reads to a model as a room
    /// that was silent rather than one it was never shown.
    func testNoBlockWhenThereIsNoRoom() {
        let routing = PromptLibrary.buildLookupRouting(request: "status?", tools: linear)
        let answering = PromptLibrary.buildLookupAnswer(request: "status?", results: [], memory: [])

        XCTAssertFalse(routing.user.contains("[IN THE ROOM]"))
        XCTAssertFalse(answering.user.contains("[IN THE ROOM]"))
    }

    /// Kept from the end: "that ticket" refers to something said thirty seconds
    /// ago, never to the top of a two-hour meeting.
    func testALongRoomIsTrimmedFromTheStart() {
        let old = String(repeating: "[Them]: something from the top of the call\n", count: 400)
        let prompt = PromptLibrary.buildLookupRouting(
            request: "status?",
            tools: linear,
            transcript: old + "[Them]: and the ticket is NOD-14"
        )

        XCTAssertTrue(prompt.user.contains("NOD-14"))
        XCTAssertLessThan(prompt.user.count, old.count)
    }

    /// The room is context, not a source. Without this the card could report
    /// what a colleague said as what Linear returned.
    func testAnsweringIsToldTheRoomIsNotASource() {
        let prompt = PromptLibrary.buildLookupAnswer(request: "status?", results: [], memory: [], transcript: room)

        XCTAssertTrue(prompt.system.contains("it is\nnot a source"))
        XCTAssertTrue(prompt.system.contains("Never answer out of the room's own words"))
    }

    /// Naming a product still has to mean what it meant before the room was
    /// added: a question about the conversation is not a tool call.
    func testRoutingStillRefusesConversationQuestions() {
        let prompt = PromptLibrary.buildLookupRouting(request: "what did we decide", tools: linear, transcript: room)

        XCTAssertTrue(prompt.system.contains("A request about the conversation rather than about a product is not a tool call"))
        XCTAssertTrue(prompt.system.contains("It does not turn a request about the conversation into a tool call"))
    }
}
