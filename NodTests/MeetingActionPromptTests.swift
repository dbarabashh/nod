import XCTest
@testable import Nod

/// The Ask box could read a connected product and never act in one, because
/// nothing on that surface could ask permission. It can now, through the same
/// `ChatToolGate` both chats use — so what these pin is the boundary: which
/// tools may be chosen without a card, and which may never be.
final class MeetingActionPromptTests: XCTestCase {
    private var slack: [ChatTool] {
        ChatTools.definitions(for: [.slack])
    }

    func testTheCatalogueStillSeparatesReadsFromWrites() {
        let writes = slack.filter(\.mutating).map(\.name)
        let reads = slack.filter { !$0.mutating }.map(\.name)

        XCTAssertTrue(writes.contains("slack_create_channel"))
        XCTAssertTrue(reads.contains("slack_read_channel"))
        XCTAssertTrue(reads.contains("slack_search_messages"))
        XCTAssertFalse(reads.contains { $0.contains("create") || $0.contains("invite") })
    }

    /// "Invite Vlad to that channel" spends its one routing choice finding the
    /// channel's id. With the follow-up restricted to reads it could then never
    /// invite anybody, and answered with the channel's contents instead.
    func testTheFollowUpMayActOnWhatTheFirstCallFound() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "invite Vlad to that channel",
            results: [(tool: "slack_list_channels", body: "{\"channels\":[{\"id\":\"C1\"}]}")],
            memory: [],
            hopTools: slack
        )

        XCTAssertTrue(prompt.system.contains("[ONE MORE READ]"))
        XCTAssertTrue(prompt.system.contains("slack_invite_users"))
        XCTAssertTrue(prompt.system.contains("has to allow it"))
    }

    func testRoutingIsToldAnInstructionIsNotAQuestion() {
        let prompt = PromptLibrary.buildLookupRouting(request: "open a channel for the migration", tools: slack)

        XCTAssertTrue(prompt.system.contains("instruction to do something"))
        XCTAssertTrue(prompt.system.contains("A question about what exists is never served by a tool that creates something."))
        XCTAssertTrue(prompt.system.contains("slack_create_channel"))
    }

    /// The card is shown before the call, so by the time anything is phrased it
    /// has already happened. An answer offering to do it reads as if it hadn't.
    func testACompletedWriteIsPhrasedAsDone() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "open a channel for the migration",
            results: [(tool: "slack_create_channel", body: "{\"key\":\"#auth-migration\"}")],
            memory: []
        )

        XCTAssertTrue(prompt.system.contains("past tense"))
        XCTAssertTrue(prompt.system.contains("never offer to do it"))
    }

    /// A refusal is not silence and not an error. Both of those invite a retry;
    /// this one has to say a person declined.
    func testDecliningSaysSoRatherThanFailing() {
        XCTAssertEqual(LiveLookup.Refusal.declined.label, "Not done — you didn't allow it")
        XCTAssertNotEqual(LiveLookup.Refusal.declined.label, LiveLookup.Refusal.outsidersPresent.label)
    }

    /// Naming a product Nod cannot reach is a refusal, and the two reasons read
    /// as opposite advice: somebody sent to reconnect a product their company
    /// switched off walks through an authorization that changes nothing.
    func testAnUnreachableProductSaysWhichKindOfUnreachable() {
        let unlinked = LiveLookup.Refusal.unreachable(.linear, blockedByOrganization: false)
        let blocked = LiveLookup.Refusal.unreachable(.linear, blockedByOrganization: true)

        XCTAssertTrue(unlinked.label.contains("Linear"))
        XCTAssertTrue(blocked.label.contains("Linear"))
        XCTAssertNotEqual(unlinked.label, blocked.label)
        XCTAssertFalse(blocked.label.contains("connect"))
    }

    func testAPendingApprovalIsSomethingTheBarCanSee() {
        var panel = MeetingBarPanel()
        XCTAssertFalse(panel.isAwaitingApproval)

        let create = slack.first { $0.name == "slack_create_channel" }
        let tool = try? XCTUnwrap(create)
        guard let tool else { return }
        let call = ChatToolCall(
            id: "1",
            type: "function",
            function: ChatToolCall.Function(name: tool.name, arguments: "{}")
        )
        panel.approval = ChatToolGate.Pending(round: ChatToolGate.Round(call, tool: tool))

        XCTAssertTrue(panel.isAwaitingApproval)
        XCTAssertFalse(panel.isAnswering)
    }
}

/// "Checked Slack, nothing there answers that" was shown for a call that had
/// failed with `missing_scope` — the product never answered at all. A failure
/// reported as an empty result is a claim about the user's Slack made out of a
/// fault in ours.
final class LookupFailurePromptTests: XCTestCase {
    func testAFailedCallIsShownToTheModelRatherThanOmitted() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "what happened in Slack today",
            results: [],
            failures: [(tool: "slack_search_messages", message: "Reconnect Slack in Settings → Integrations.")],
            memory: ["something was said in an earlier session"]
        )

        XCTAssertTrue(prompt.user.contains("[slack_search_messages COULD NOT RUN]"))
        XCTAssertTrue(prompt.user.contains("Reconnect Slack in Settings → Integrations."))
    }

    func testTheModelIsToldNotToReportAFailureAsAnEmptyProduct() {
        let prompt = PromptLibrary.buildLookupAnswer(request: "anything", results: [], memory: [])

        XCTAssertTrue(prompt.system.contains("Never report it as the product having nothing"))
        XCTAssertTrue(prompt.system.contains("never ask for it again"))
    }

    /// It asked for the identical call twice in one lookup, because a failure it
    /// could not see looked like a call it had not made.
    func testTheHopIsToldNotToRepeatACallAlreadyMade() {
        let prompt = PromptLibrary.buildLookupAnswer(
            request: "anything",
            results: [(tool: "slack_search_messages", body: "{}")],
            memory: [],
            hopTools: ChatTools.definitions(for: [.slack]).filter { !$0.mutating }
        )

        XCTAssertTrue(prompt.system.contains("Never ask for a call that already appears above"))
    }

    func testTheReasonReachesThePersonWhoCanActOnIt() {
        let said = LiveLookup.Failure.provider(.slack, "Reconnect Slack in Settings → Integrations.").label

        XCTAssertTrue(said.contains("Slack"))
        XCTAssertTrue(said.contains("Reconnect Slack in Settings → Integrations."))
        XCTAssertNotEqual(said, LiveLookup.nothingFound(in: .slack))
    }

    func testAFailureWithNothingToSayStillSaysItFailed() {
        XCTAssertEqual(LiveLookup.Failure.provider(.slack, nil).label, "Couldn't reach Slack")
        XCTAssertEqual(LiveLookup.Failure.provider(.slack, "   ").label, "Couldn't reach Slack")
    }

    /// The message that mattered most: a Slack app missing a permission, on a
    /// connection that is healthy. Announced as "couldn't reach Slack" it sends
    /// somebody to reconnect a working integration, which is what the old
    /// string-sniffing formatter did with this exact sentence.
    func testAMissingPermissionIsNotAnUnreachableProduct() {
        let scopes = "Nod's Slack app has no permission for this. Reconnecting won't add it."
        let said = LiveLookup.Failure.provider(.slack, scopes).label

        XCTAssertFalse(said.contains("Couldn't reach"))
        XCTAssertTrue(said.hasSuffix(scopes))
    }

    /// A phrasing pass that fails after the products answered is ours, and
    /// naming one of them would point at an integration that works.
    func testOurOwnFailureNamesNobodyElse() {
        let ours = LiveLookup.Failure.nod(MeetingLookup.couldNotPhrase).label

        XCTAssertEqual(ours, MeetingLookup.couldNotPhrase)
        XCTAssertFalse(ours.contains("Slack"))
    }
}

/// "запроси Влада в цей канал" reached no tool at all and the transcript
/// invented a reason about a missing Slack id. The adapter could invite all
/// along; the catalogue simply never offered it. And `slack_create_channel`
/// advertised `invite_emails` while the handler read only member ids, so the
/// promise was never kept either.
final class SlackInvitePromptTests: XCTestCase {
    private var slack: [ChatTool] {
        ChatTools.definitions(for: [.slack])
    }

    func testInvitingIsSomethingTheModelCanChoose() throws {
        let invite = try XCTUnwrap(slack.first { $0.name == "slack_invite_users" })

        XCTAssertTrue(invite.mutating)
        XCTAssertEqual(invite.parameters.required.sorted(), ["channel_id", "invite_people"])
    }

    /// Addresses, not member ids: nobody says a Slack id out loud, and the box
    /// has the organization directory rather than the workspace's.
    func testInvitingTakesTheThingAPersonActuallyKnows() throws {
        let invite = try XCTUnwrap(slack.first { $0.name == "slack_invite_users" })

        XCTAssertNotNil(invite.parameters.properties["invite_people"])
        XCTAssertNil(invite.parameters.properties["invite_member_ids"])
    }

    /// Nobody says a Slack member id out loud, and the box holds the
    /// organization's directory rather than the workspace's — so the schema
    /// asks for the thing the asker actually has and the adapter matches it.
    func testInvitingTakesAPersonHoweverTheyWereNamed() throws {
        let invite = try XCTUnwrap(slack.first { $0.name == "slack_invite_users" })
        let people = try XCTUnwrap(invite.parameters.properties["invite_people"])

        XCTAssertTrue(people.description.contains("first name"))
        XCTAssertTrue(people.description.contains("email"))
    }

    /// `is:open is:pr` searched the whole of GitHub and came back with
    /// strangers' pull requests, which the answer then reported as nothing
    /// found.
    func testGitHubSearchIsToldToScopeAQuestionAboutYourOwnWork() throws {
        let search = try XCTUnwrap(ChatTools.definitions(for: [.github]).first { $0.name == "github_search_issues" })

        XCTAssertTrue(search.description.contains("author:@me"))
        XCTAssertTrue(search.description.contains("searches all of GitHub"))
    }
}
