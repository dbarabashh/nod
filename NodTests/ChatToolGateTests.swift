import XCTest
@testable import Nod

/// Both chats reach the same connected products through one gate. These pin the
/// matching step in front of it: a model that names a tool nobody offered must
/// be refused, not guessed at, because the guess is what would send a request
/// on the user's behalf that they never saw described. And a round that reaches
/// two products must be described as reaching two.
@MainActor
final class ChatToolGateTests: XCTestCase {
    private func call(_ name: String) -> ChatToolCall {
        ChatToolCall(id: name, type: "function", function: .init(name: name, arguments: "{}"))
    }

    private func preference() -> ToolApprovalPreference {
        ToolApprovalPreference(
            defaults: UserDefaults(suiteName: "tools.approval.gate.\(UUID().uuidString)") ?? .standard
        )
    }

    private func catalogue() -> [ChatTool] {
        ChatTools.definitions(for: [.linear, .googleCalendar])
    }

    private func read(_ provider: IntegrationProvider) throws -> String {
        try XCTUnwrap(catalogue().first { $0.provider == provider && !$0.mutating }?.name)
    }

    private func write(_ provider: IntegrationProvider) throws -> String {
        try XCTUnwrap(catalogue().first { $0.provider == provider && $0.mutating }?.name)
    }

    func testMatchesEveryCallToItsToolInOrder() throws {
        let catalogue = ChatTools.definitions(for: [.linear])
        let names = catalogue.prefix(2).map(\.name)
        try XCTSkipIf(names.count < 2, "Linear needs two tools for this to mean anything")

        let round = try XCTUnwrap(ChatToolGate.match(names.map(call), in: catalogue))

        XCTAssertEqual(round.batches.count, 1)
        XCTAssertEqual(round.batches.first?.tools.map(\.name), names)
        XCTAssertEqual(round.batches.first?.provider, .linear)
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

    /// A model asked about two products at once emits both in one message, and
    /// nothing upstream stops it. The round has to say so, or the card names
    /// one product and reaches another.
    func testSplitsAMixedRoundByProduct() throws {
        let calendar = try read(.googleCalendar)
        let linear = try read(.linear)

        let round = try XCTUnwrap(ChatToolGate.match([call(calendar), call(linear)], in: catalogue()))

        XCTAssertEqual(round.batches.map(\.provider), [.googleCalendar, .linear])
        XCTAssertEqual(round.batches.map(\.calls.count), [1, 1])
    }

    /// Grouped by product, not by adjacency: two calendar reads either side of
    /// a Linear one are one calendar decision, not two. The replayed calls stay
    /// in the model's own order, because that is the turn the provider is being
    /// shown.
    func testGroupsCallsToTheSameProductButReplaysThemAsAsked() throws {
        let calendar = catalogue().filter { $0.provider == .googleCalendar }.prefix(2).map(\.name)
        let linear = try read(.linear)
        try XCTSkipIf(calendar.count < 2, "Calendar needs two tools for this to mean anything")
        let asked = [calendar[0], linear, calendar[1]].map(call)

        let round = try XCTUnwrap(ChatToolGate.match(asked, in: catalogue()))

        XCTAssertEqual(round.batches.map(\.provider), [.googleCalendar, .linear])
        XCTAssertEqual(round.batches.first?.calls.map(\.id), [calendar[0], calendar[1]])
        XCTAssertEqual(round.calls.map(\.id), asked.map(\.id))
    }

    /// The card offers to stop asking about a product; a round reaching two
    /// cannot be answered by one such button, so it isn't offered one.
    func testAlwaysAllowIsOfferedOnlyForASingleReadOnlyProduct() throws {
        let calendar = try read(.googleCalendar)
        let linear = try read(.linear)
        let calendarWrite = try write(.googleCalendar)

        let alone = try XCTUnwrap(ChatToolGate.match([call(calendar)], in: catalogue()))
        let mixed = try XCTUnwrap(ChatToolGate.match([call(calendar), call(linear)], in: catalogue()))
        let writes = try XCTUnwrap(ChatToolGate.match([call(calendarWrite)], in: catalogue()))

        XCTAssertEqual(ChatToolGate.Pending(round: alone).alwaysAllowable, .googleCalendar)
        XCTAssertNil(ChatToolGate.Pending(round: mixed).alwaysAllowable)
        XCTAssertNil(ChatToolGate.Pending(round: writes).alwaysAllowable)
    }

    /// The original defect. "Always allow Google Calendar" is a decision about
    /// the calendar; a round that also reads the user's Linear must still be
    /// put to them, and the card must name both products.
    func testAProductAllowedUnaskedDoesNotCarryTheProductBesideIt() async throws {
        let calendar = try read(.googleCalendar)
        let linear = try read(.linear)
        let round = try XCTUnwrap(ChatToolGate.match([call(calendar), call(linear)], in: catalogue()))
        let preference = preference()
        preference.allowReads(from: .googleCalendar)
        let gate = ChatToolGate(approval: preference)

        let task = Task { await gate.run(round, using: IntegrationService(supabase: nil)) }
        await Task.yield()

        let pending = try XCTUnwrap(gate.pending, "a round reaching Linear may not run on the calendar's permission")
        XCTAssertEqual(pending.round.batches.map(\.provider), [.googleCalendar, .linear])
        gate.deny()
        let outcome = await task.value
        XCTAssertEqual(outcome.steps.map(\.outcome), [.declined, .declined])
    }

    /// Nothing goes out while the card is still up — not even the read the
    /// person already allows unasked, when it shares a round with a write they
    /// have not answered yet.
    func testNothingRunsWhileTheCardIsStillUp() async throws {
        let calendar = try read(.googleCalendar)
        let linearWrite = try write(.linear)
        let round = try XCTUnwrap(ChatToolGate.match([call(calendar), call(linearWrite)], in: catalogue()))
        let preference = preference()
        preference.approval = .allowReads
        let gate = ChatToolGate(approval: preference)

        let task = Task { await gate.run(round, using: IntegrationService(supabase: nil)) }
        await Task.yield()

        XCTAssertNotNil(gate.pending, "a round carrying a write asks, whatever the reads beside it are")
        XCTAssertNil(gate.callingProvider, "nothing may be in flight while the question stands")
        gate.deny()
        let outcome = await task.value
        XCTAssertEqual(outcome.steps.map(\.outcome), [.declined, .declined])
    }

    /// Every call gets a result turn, whichever product it reached and whether
    /// or not it ran: the next request is invalid without one, and a mixed
    /// round is where a missing result would first have appeared.
    func testAMixedRoundAnswersEveryCallOnce() async throws {
        let calendar = try read(.googleCalendar)
        let linear = try read(.linear)
        let round = try XCTUnwrap(ChatToolGate.match([call(calendar), call(linear)], in: catalogue()))
        let gate = ChatToolGate(unattended: true)

        let outcome = await gate.run(round, using: IntegrationService(supabase: nil))

        XCTAssertEqual(outcome.turns.first?.role, .assistant)
        XCTAssertEqual(outcome.turns.first?.toolCalls.map(\.name), [calendar, linear])
        XCTAssertEqual(outcome.turns.dropFirst().compactMap(\.toolCallID), [calendar, linear])
        XCTAssertEqual(outcome.steps.map(\.provider), [.googleCalendar, .linear])
    }

    /// Pins the gate's own defence rather than a reachable regression: the
    /// unattended catalogue is filtered to reads before it ever gets here
    /// (`KnowledgeChatStore.offered`), so this state cannot arise in the app.
    /// It is asserted anyway, because a gate that trusts its caller is not a
    /// gate.
    func testUnattendedRefusesARoundThatWouldWrite() async throws {
        let read = try read(.googleCalendar)
        let write = try write(.linear)
        let round = try XCTUnwrap(ChatToolGate.match([call(read), call(write)], in: catalogue()))
        let gate = ChatToolGate(unattended: true)

        let outcome = await gate.run(round, using: IntegrationService(supabase: nil))

        XCTAssertEqual(outcome.steps.map(\.outcome), [.declined, .declined])
    }

    /// Stop means stop, including for a product the person had said may be
    /// read unasked. The preference answers "may this run", never "may this run
    /// after the turn was abandoned".
    func testAStoppedTurnDeclinesEvenReadsAllowedUnasked() async throws {
        let calendar = try read(.googleCalendar)
        let linear = try read(.linear)
        let round = try XCTUnwrap(ChatToolGate.match([call(calendar), call(linear)], in: catalogue()))
        let preference = preference()
        preference.approval = .allowReads
        let gate = ChatToolGate(approval: preference)

        let task = Task { await gate.run(round, using: IntegrationService(supabase: nil)) }
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome.steps.map(\.outcome), [.declined, .declined])
        XCTAssertEqual(outcome.turns.dropFirst().count, 2, "a declined call still owes the model a result")
    }
}
