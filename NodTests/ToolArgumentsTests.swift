import XCTest
@testable import Nod

/// Every adapter's `requireBoolean` accepts "true"/"false" and nothing else, so
/// a boolean flattened to "1" is rejected as `invalid_params` — which is how
/// asking the chat for a private Slack channel quietly made a public one.
final class ToolArgumentsTests: XCTestCase {
    func testABooleanIsTheWordAndNotTheDigit() {
        let decoded = ToolArguments.decode(#"{"is_private": true, "quiet": false}"#)

        XCTAssertEqual(decoded["is_private"], "true")
        XCTAssertEqual(decoded["quiet"], "false")
    }

    /// The trap under the fix: `NSNumber(1) as? Bool` is `true` in Swift, so a
    /// count of one must not be read as a flag.
    func testAOneIsACountAndNotAFlag() {
        let decoded = ToolArguments.decode(#"{"limit": 1, "offset": 0, "size": 50}"#)

        XCTAssertEqual(decoded["limit"], "1")
        XCTAssertEqual(decoded["offset"], "0")
        XCTAssertEqual(decoded["size"], "50")
    }

    func testAFractionKeepsItsPoint() {
        XCTAssertEqual(ToolArguments.decode(#"{"ratio": 1.5}"#)["ratio"], "1.5")
    }

    /// An argument the model left out must not reach a provider as the
    /// four-letter string, and a nested value's description is worse than its
    /// absence.
    func testWhatATooolArgumentCannotCarryIsDropped() {
        let decoded = ToolArguments.decode(#"{"kept":"x","dropped":null,"nested":{"a":1},"objects":[{"a":1}]}"#)

        XCTAssertEqual(decoded["kept"], "x")
        XCTAssertNil(decoded["dropped"])
        XCTAssertNil(decoded["nested"])
        XCTAssertNil(decoded["objects"])
    }

    /// The guests the model sent as a list have to reach the invitation. Every
    /// list argument is declared comma-separated and read either way, but a
    /// model sends an array for `attendees` regardless — and dropped, the event
    /// was created with nobody on it and nothing said so.
    func testAListArgumentArrivesCommaJoined() {
        let decoded = ToolArguments.decode(#"{"attendees":["a@b.com","c@d.com"],"keys":[1,2]}"#)

        XCTAssertEqual(decoded["attendees"], "a@b.com,c@d.com")
        XCTAssertEqual(decoded["keys"], "1,2")
    }

    func testAnEmptyListIsNoArgument() {
        XCTAssertNil(ToolArguments.decode(#"{"attendees":[]}"#)["attendees"])
    }

    func testTheTwoDecodersReadALikeToo() throws {
        let json = #"{"attendees":["a@b.com","c@d.com"],"title":"Sync","empty":[]}"#
        let call = ChatToolCall(
            id: "1",
            type: "function",
            function: ChatToolCall.Function(name: "google-calendar_create_event", arguments: json)
        )
        let routed = try JSONDecoder().decode(PromptLibrary.LookupChoice.self, from: Data(#"{"tool":"t","arguments":\#(json)}"#.utf8))

        XCTAssertEqual(call.arguments["attendees"], "a@b.com,c@d.com")
        XCTAssertEqual(call.arguments, routed.arguments)
    }

    func testUnreadableArgumentsAreNoArguments() {
        XCTAssertTrue(ToolArguments.decode("not json").isEmpty)
        XCTAssertTrue(ToolArguments.decode("[1,2,3]").isEmpty)
        XCTAssertTrue(ToolArguments.decode("").isEmpty)
    }

    /// The chat and the meeting lookup read the same wire format; two answers
    /// for one contract is what this replaced.
    func testTheLookupAndTheChatAgree() throws {
        let json = #"{"channel":"C1","limit":50,"is_private":true}"#
        let call = ChatToolCall(
            id: "1",
            type: "function",
            function: ChatToolCall.Function(name: "slack_read_channel", arguments: json)
        )
        let routed = try JSONDecoder().decode(PromptLibrary.LookupChoice.self, from: Data(#"{"tool":"t","arguments":\#(json)}"#.utf8))

        XCTAssertEqual(call.arguments, routed.arguments)
    }
}
