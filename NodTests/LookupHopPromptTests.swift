import XCTest
@testable import Nod

/// Slack answers "which channel" and "what was said in it" with two different
/// calls, and the lookup used to make exactly one. So "go and look in Slack"
/// routed to `slack_list_channels`, got a list of channel names back, and that
/// list was the answer. These pin the follow-up read that closes the question,
/// and the bound that stops it becoming a tool loop mid-meeting.
final class LookupHopPromptTests: XCTestCase {
    private var slackReads: [ChatTool] {
        ChatTools.definitions(for: [.slack]).filter { !$0.mutating }
    }

    func testTheCatalogueSaysWhichToolFindsTheIdTheOtherNeeds() {
        let names = slackReads.map(\.name)
        XCTAssertTrue(names.contains("slack_list_channels"))
        XCTAssertTrue(names.contains("slack_read_channel"))

        let read = slackReads.first { $0.name == "slack_read_channel" }
        XCTAssertEqual(read?.description.contains("slack_list_channels"), true)
    }

    func testFurtherReadIsOfferedWithTheToolsItMayChooseFrom() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "what did we discuss in the pricing channel",
            results: [(tool: "slack_list_channels", body: "{\"channels\":[{\"id\":\"C01\",\"name\":\"pricing\"}]}")],
            memory: [],
            hopTools: slackReads
        )

        XCTAssertTrue(prompt.system.contains("[ONE MORE READ]"))
        XCTAssertTrue(prompt.system.contains("slack_read_channel"))
        XCTAssertTrue(prompt.system.contains("\"next\": {\"tool\": \"\", \"arguments\": {}}"))
    }

    /// The hop is a hop, not a loop: the call that reads what the hop returned
    /// is not offered another one, so a lookup can never cost more than two
    /// reads however the model answers.
    func testTheSecondPassIsNotOfferedAnotherRead() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "what did we discuss in the pricing channel",
            results: [
                (tool: "slack_list_channels", body: "{\"channels\":[]}"),
                (tool: "slack_read_channel", body: "{\"messages\":[]}")
            ],
            memory: []
        )

        XCTAssertFalse(prompt.system.contains("[ONE MORE READ]"))
        XCTAssertTrue(prompt.system.contains("{\"next\": null"))
    }

    func testEveryReadIsLabelledWithTheToolItCameFrom() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "what did we discuss in the pricing channel",
            results: [
                (tool: "slack_list_channels", body: "the channel list"),
                (tool: "slack_read_channel", body: "the messages")
            ],
            memory: []
        )

        XCTAssertTrue(prompt.user.contains("[slack_list_channels RESULT]\nthe channel list"))
        XCTAssertTrue(prompt.user.contains("[slack_read_channel RESULT]\nthe messages"))
    }

    /// A channel read comes back with an hour of messages and the card is two
    /// sentences. Two reads must not put twice an unbounded body in the prompt.
    func testEachReadIsBudgeted() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "anything",
            results: [(tool: "slack_read_channel", body: String(repeating: "x", count: 20_000))],
            memory: []
        )

        XCTAssertLessThan(prompt.user.count, 10_000)
    }

    /// Routing has to be willing to pick the finder when the request names a
    /// channel by topic, which is the only way the pair is ever entered.
    func testRoutingIsToldAFinderIsALegitimateFirstChoice() {
        let prompt = PromptLibrary.buildLookupRouting(
            request: "what did we discuss in the pricing channel",
            tools: slackReads
        )

        XCTAssertTrue(prompt.system.contains("read in a second step"))
        XCTAssertTrue(prompt.system.contains("[TOOLS]"))
        XCTAssertTrue(prompt.system.contains("slack_list_channels"))
    }
}
