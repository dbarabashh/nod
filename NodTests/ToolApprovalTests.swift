import XCTest
@testable import Nod

@MainActor
final class ToolApprovalTests: XCTestCase {
    private func preference() -> ToolApprovalPreference {
        let suite = "tools.approval.tests.\(UUID().uuidString)"
        return ToolApprovalPreference(defaults: UserDefaults(suiteName: suite) ?? .standard)
    }

    private func tool(mutating: Bool) -> ChatTool {
        ChatTool(
            provider: .slack,
            name: mutating ? "slack_post_message" : "slack_search_messages",
            description: "",
            parameters: ChatToolSchema(properties: [:], required: []),
            mutating: mutating
        )
    }

    /// Asking every time is what everyone already agreed to, so it stays the
    /// default for anyone upgrading into this setting existing.
    func testAskingEveryTimeIsTheDefault() {
        let preference = preference()

        XCTAssertEqual(preference.approval, .alwaysAsk)
        XCTAssertFalse(preference.runsUnasked([tool(mutating: false)], from: .slack))
    }

    func testAllowingReadsLetsAReadThrough() {
        let preference = preference()
        preference.approval = .allowReads

        XCTAssertTrue(preference.runsUnasked([tool(mutating: false)], from: .slack))
    }

    /// The invariant the whole feature rests on: a write always shows its card,
    /// under every setting and for every product.
    func testAWriteAlwaysAsks() {
        let preference = preference()
        preference.approval = .allowReads
        preference.allowReads(from: .slack)

        XCTAssertFalse(preference.runsUnasked([tool(mutating: true)], from: .slack))
        XCTAssertFalse(
            preference.runsUnasked([tool(mutating: false), tool(mutating: true)], from: .slack),
            "a batch carrying a write is a write"
        )
    }

    /// "Always allow Slack" is about Slack, and says nothing about Linear.
    func testAllowingOneProductDoesNotAllowAnother() {
        let preference = preference()
        preference.allowReads(from: .slack)

        XCTAssertTrue(preference.runsUnasked([tool(mutating: false)], from: .slack))
        XCTAssertFalse(preference.runsUnasked([tool(mutating: false)], from: .linear))
    }

    func testTakingItBackAsksAgain() {
        let preference = preference()
        preference.allowReads(from: .slack)
        preference.stopAllowing(.slack)

        XCTAssertFalse(preference.runsUnasked([tool(mutating: false)], from: .slack))
    }

    func testAnEmptyBatchIsNeverRunUnasked() {
        let preference = preference()
        preference.approval = .allowReads

        XCTAssertFalse(preference.runsUnasked([], from: .slack))
    }
}
