import XCTest
@testable import Nod

/// A correct follow-up read was thrown away and reported as "couldn't reach
/// Slack". The model had found the channel id and asked to read it with
/// `{"channel":"C0BQTBPCHTK","limit":50}` — and `limit` being a number, which
/// the tool's own schema invites ("1-200"), failed to decode into
/// `[String: String]`. These pin every scalar a schema can ask for.
final class LookupArgumentDecodingTests: XCTestCase {
    private func choice(_ json: String) throws -> PromptLibrary.LookupChoice {
        try JSONDecoder().decode(PromptLibrary.LookupChoice.self, from: Data(json.utf8))
    }

    func testTheCallThatWasThrownAwayNowDecodes() throws {
        let decoded = try choice(#"{"tool":"slack_read_channel","arguments":{"channel":"C0BQTBPCHTK","limit":50}}"#)

        XCTAssertEqual(decoded.tool, "slack_read_channel")
        XCTAssertEqual(decoded.arguments?["channel"], "C0BQTBPCHTK")
        XCTAssertEqual(decoded.arguments?["limit"], "50")
    }

    func testEveryScalarASchemaCanAskFor() throws {
        let decoded = try choice(#"{"tool":"t","arguments":{"s":"x","i":7,"b":true,"d":1.5}}"#)

        XCTAssertEqual(decoded.arguments?["s"], "x")
        XCTAssertEqual(decoded.arguments?["i"], "7")
        XCTAssertEqual(decoded.arguments?["b"], "true")
        XCTAssertEqual(decoded.arguments?["d"], "1.5")
    }

    /// An argument the model left out must not arrive at a provider as the
    /// four-letter string "null".
    func testNullIsAnAbsentArgumentRatherThanTheWord() throws {
        let decoded = try choice(#"{"tool":"t","arguments":{"kept":"yes","dropped":null}}"#)

        XCTAssertEqual(decoded.arguments?["kept"], "yes")
        XCTAssertNil(decoded.arguments?["dropped"])
    }

    func testNestedValuesAreDroppedRatherThanStringified() throws {
        let decoded = try choice(#"{"tool":"t","arguments":{"ok":"1","nested":{"a":1},"list":[1,2]}}"#)

        XCTAssertEqual(decoded.arguments?["ok"], "1")
        XCTAssertNil(decoded.arguments?["nested"])
        XCTAssertNil(decoded.arguments?["list"])
    }

    func testChoosingNothingStillDecodes() throws {
        let decoded = try choice(#"{"tool":null,"arguments":null}"#)

        XCTAssertNil(decoded.tool)
        XCTAssertNil(decoded.arguments)
    }

    /// The answering pass carries a choice in `next`, which is where this broke.
    func testAFollowUpInsideAnAnswerDecodes() throws {
        let json = #"{"next":{"tool":"slack_read_channel","arguments":{"channel":"C1","limit":50}},"text":"","subject":"","usedTool":false}"#
        let decoded = try JSONDecoder().decode(PromptLibrary.LookupAnswer.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.next?.tool, "slack_read_channel")
        XCTAssertEqual(decoded.next?.arguments?["limit"], "50")
    }

    func testAProviderFailureStillNamesTheProvider() {
        let theirs = LiveLookup.Failure.provider(.slack, "Reconnect it in Settings.").label

        XCTAssertTrue(theirs.hasPrefix("Slack:"))
    }
}

/// "попереднє?" routed to `linear_search_issues` with no arguments, and Linear's
/// own complaint — "`query` is required" — reached the person as "Couldn't reach
/// Linear". Their Linear was fine; the call was malformed. A call the schema
/// says cannot be made is refused here, and the question falls back to the
/// transcript, which for a follow-up about the conversation is where the answer
/// was all along.
final class LookupRoutingValidationTests: XCTestCase {
    private var linear: [ChatTool] {
        ChatTools.definitions(for: [.linear])
    }

    private var search: ChatTool? {
        linear.first { $0.name == "linear_search_issues" }
    }

    func testTheToolThatBrokeDeclaresTheArgumentItNeeds() throws {
        let tool = try XCTUnwrap(search)

        XCTAssertTrue(tool.parameters.required.contains("query"))
    }

    func testRoutingIsToldToFillEveryRequiredArgumentOrChooseNothing() {
        let prompt = PromptLibrary.buildLookupRouting(request: "попереднє?", tools: linear)

        XCTAssertTrue(prompt.system.contains("Fill every required argument or choose nothing"))
    }

    /// The follow-up that caused it is a question about the conversation, not
    /// about a tracker, and should never have been routed at all.
    func testRoutingIsToldAFollowUpAboutTheChatIsNotAToolCall() {
        let prompt = PromptLibrary.buildLookupRouting(request: "попереднє?", tools: linear)

        XCTAssertTrue(prompt.system.contains("is not a tool call"))
        XCTAssertTrue(prompt.system.contains("[EARLIER IN THIS ASK BOX]"))
    }
}
