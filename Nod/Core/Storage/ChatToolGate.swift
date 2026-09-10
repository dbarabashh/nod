import Combine
import Foundation

/// The step between a model asking for a tool and anything leaving Nod.
///
/// Both chats reach the same connected products, and neither may reach them
/// unasked — so the question, the waiting, and the running live here once
/// rather than in each store's copy. A second copy is how the per-session chat
/// would have ended up with a slightly different idea of what counts as
/// consent.
@MainActor
final class ChatToolGate: ObservableObject {
    /// One card per model turn — see `ToolApprovalCard`.
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let round: Round

        /// The product this card may offer to stop asking about, if any. Only
        /// a round that reaches one product and writes nothing: "always allow"
        /// names a product, so a round touching two cannot be answered by one
        /// button, and buying silence for a tool that sends a message is not a
        /// thing to agree to once.
        var alwaysAllowable: IntegrationProvider? {
            guard round.batches.count == 1, let batch = round.batches.first,
                  !batch.tools.isEmpty, batch.tools.allSatisfy({ !$0.mutating })
            else { return nil }
            return batch.provider
        }
    }

    /// One model turn's tool calls, and the same calls split by product.
    ///
    /// A model asked about the calendar and the inbox in the same breath emits
    /// both in one message, and nothing upstream stops it. The card has to
    /// name every product it will reach, and the standing "reads may run
    /// unasked" permission has to be held for every one of them — both used to
    /// be decided from whichever call happened to come first.
    struct Round: Equatable {
        /// In the order the model asked, which is how the assistant turn
        /// replays them.
        let calls: [ChatToolCall]
        /// One per product, in the order the round first reached each.
        let batches: [Batch]

        /// A single call, for the lookup that routes one tool itself rather
        /// than letting a model choose.
        init(_ call: ChatToolCall, tool: ChatTool) {
            self.init(calls: [call], batches: [Batch(call, tool: tool)])
        }

        fileprivate init(calls: [ChatToolCall], batches: [Batch]) {
            self.calls = calls
            self.batches = batches
        }
    }

    /// One product's share of a round.
    struct Batch: Equatable {
        let provider: IntegrationProvider
        let calls: [ChatToolCall]
        let tools: [ChatTool]

        /// The product is read off the tool rather than passed beside it: a
        /// batch whose name and calls disagree is the defect `Round` exists to
        /// prevent, and a memberwise initialiser lets a caller build one.
        init(_ call: ChatToolCall, tool: ChatTool) {
            self.init(provider: tool.provider, calls: [call], tools: [tool])
        }

        fileprivate init(provider: IntegrationProvider, calls: [ChatToolCall], tools: [ChatTool]) {
            self.provider = provider
            self.calls = calls
            self.tools = tools
        }
    }

    /// Three rounds: search-then-answer and search-then-create fit in two, and
    /// the calendar's destructive tools legitimately need a third — they demand
    /// a `list_events` first, and a refused write (wrong occurrence, stale
    /// title) is told to list again. A fourth is a model looping, and every
    /// round re-sends the whole prompt. Both chats spend the same budget: it is
    /// a cost, not a per-surface taste.
    static let maxRounds = 3

    /// Said to the person by whichever chat the model surprised. One sentence,
    /// one place — it is the same refusal wherever it happens.
    static let unknownToolMessage = "That needs a tool Nod doesn't have."

    /// What the model asked for and the person hasn't answered yet.
    @Published private(set) var pending: Pending?
    /// Set only while an approved call is in flight, so the chat can say which
    /// product it is talking to.
    @Published private(set) var callingProvider: IntegrationProvider?

    /// What a finished round hands back: the turns to replay to the model, and
    /// what happened, for a transcript that shows its working.
    struct Outcome {
        var turns: [LLMProxyClient.ChatTurn] = []
        var steps: [ChatTurnStep] = []
    }

    /// The in-flight exchange: what was asked for this question and what came
    /// back. Deliberately neither persisted nor part of either chat's messages —
    /// it is scaffolding for one answer, and replaying it into every later
    /// request would pay for those tokens forever.
    private(set) var turns: [LLMProxyClient.ChatTurn] = []

    private var approval: CheckedContinuation<Bool, Never>?

    /// No person is behind this chat — it is a beat running on a schedule, and
    /// there is nobody to show a card to. Read-only calls go straight through;
    /// what keeps that safe is not this flag but the catalogue the unattended
    /// chat is given, which holds no mutating tool at all. Asserted here too,
    /// because a gate that trusts its caller is not a gate.
    private let unattended: Bool

    /// How much may run without a card, as the person set it in Settings.
    /// Optional so a store built without one keeps the strictest behaviour:
    /// a gate that cannot read the preference asks, it does not assume.
    private let approvalPreference: ToolApprovalPreference?
    /// Where an answered card is counted, when the surface counts them at all.
    /// Optional so the live analyst's gate keeps working without one.
    private let approvalLog: ToolApprovalLog?

    init(unattended: Bool = false, approval: ToolApprovalPreference? = nil, log: ToolApprovalLog? = nil) {
        self.unattended = unattended
        approvalPreference = approval
        approvalLog = log
    }

    /// Called when a new question starts, so the last one's scaffolding doesn't
    /// ride along with it.
    func beginQuestion() {
        turns = []
    }

    /// Runs `round` once the person allows it, and returns what to tell the
    /// model. A denial is an outcome too — the model is told it was declined,
    /// which is what stops it asking again in the same breath.
    ///
    /// One decision for the whole round, however many products it reaches: a
    /// card per product would put the second one under a button the user is
    /// already reaching for, and a search that went out while the write beside
    /// it was still being considered is the same answer, arrived at in an
    /// order nobody was shown. Every call gets a result whichever way it went,
    /// because a missing one makes the next request invalid.
    ///
    /// `onApproved` runs before each product's first call goes out — the
    /// moment a chat stops waiting on a person and starts waiting on a
    /// product, which is the only thing worth saying out loud between the two.
    func run(
        _ round: Round,
        using integrations: IntegrationService,
        onApproved: (IntegrationProvider) -> Void = { _ in }
    ) async -> Outcome {
        var outcome = Outcome()
        // The assistant's request has to be replayed verbatim, or the provider
        // rejects results for calls it can't see in the history.
        outcome.turns.append(LLMProxyClient.ChatTurn(role: .assistant, content: "", toolCalls: round.calls))
        let allowed = await allows(round) && !Task.isCancelled
        var results: [String: LLMProxyClient.ChatTurn] = [:]
        for batch in round.batches {
            let settled = await settle(batch, using: integrations, allowed: allowed, onApproved: onApproved)
            for turn in settled.turns {
                results[turn.toolCallID ?? ""] = turn
            }
            outcome.steps += settled.steps
        }
        callingProvider = nil
        // Grouped by product to run, replayed in the order they were asked:
        // pairing is by `tool_call_id` on every provider we speak to, but a
        // history whose results answer in a different order than the request
        // listed them is a needless bet on that staying true.
        outcome.turns += round.calls.compactMap { results[$0.id] }
        turns += outcome.turns
        return outcome
    }

    /// Whether this round may run: the unattended rule, the person's standing
    /// preference, or the card.
    private func allows(_ round: Round) async -> Bool {
        // Before anything that could answer yes. A standing preference to run
        // reads unasked is not a licence to run them after the person pressed
        // stop.
        if Task.isCancelled { return false }
        // `allSatisfy` is true of nothing, so an empty round would run itself.
        guard !round.batches.isEmpty else { return false }
        let tools = round.batches.flatMap(\.tools)
        let products = round.batches.map(\.provider.rawValue).joined(separator: "+")
        if unattended {
            let mutates = tools.contains { $0.mutating }
            Log.ui.info(
                "unattended \(products) call(s)=\(round.calls.count) \(mutates ? "refused — mutating" : "allowed")"
            )
            return !mutates
        }
        // Reads run unasked when the person said they may — the rule the live
        // lookup has always followed ("a read changes nothing"), now available
        // to the chat as well. Every product in the round, not the first one:
        // a permission granted for the calendar has never been asked about the
        // mail. A round carrying any write is a write, and shows its card.
        if round.batches.allSatisfy({ approvalPreference?.runsUnasked($0.tools, from: $0.provider) == true }) {
            Log.ui.info("\(round.calls.count) \(products) read(s) allowed without asking")
            record(round, allowed: true, unasked: true)
            return true
        }
        Log.ui.info("awaiting approval for \(round.calls.count) \(products) call(s)")
        // A question asked while an older card still stands supersedes it. The
        // slot holds one continuation: overwriting it used to strand the first
        // task suspended for the rest of the meeting, because cancelling that
        // task does not resume a `withCheckedContinuation`.
        cancelPending()
        let mine = Pending(round: round)
        pending = mine
        let allowed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before the continuation was stored — resume it at
                // once rather than leave a task waiting on a card nobody will
                // ever see.
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    approval = continuation
                }
            }
        } onCancel: {
            // Whoever asked has gone. A card with nobody behind it is not a
            // question, and leaving it standing is how a write ends up waiting
            // on an answer that can no longer arrive.
            Task { @MainActor [weak self] in self?.cancelPending() }
        }
        if pending?.id == mine.id { pending = nil }
        record(round, allowed: allowed, unasked: false)
        return allowed
    }

    /// One log entry per product, so a mixed round is counted as the several
    /// decisions the person actually made about their products.
    private func record(_ round: Round, allowed: Bool, unasked: Bool) {
        for batch in round.batches {
            approvalLog?.record(provider: batch.provider, tools: batch.tools, allowed: allowed, unasked: unasked)
        }
    }

    /// Runs what was allowed and writes the turns the model has to see either
    /// way. Shared by the card and the unattended path so a beat's transcript
    /// is assembled by the same code as a person's.
    private func settle(
        _ batch: Batch,
        using integrations: IntegrationService,
        allowed: Bool,
        onApproved: (IntegrationProvider) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        if allowed {
            callingProvider = batch.provider
            onApproved(batch.provider)
        }
        for (call, tool) in zip(batch.calls, batch.tools) {
            let result = allowed
                ? await integrations.run(call, tool: tool, origin: .chat)
                : IntegrationService.declinedResult()
            outcome.turns.append(.init(role: .tool, content: result, toolCallID: call.id))
            outcome.steps.append(ChatTurnStep(
                provider: tool.provider,
                action: tool.action,
                detail: call.recognisableArgument(for: tool),
                outcome: allowed ? Self.outcome(of: result) : .declined
            ))
        }
        return outcome
    }

    static func outcome(of result: String) -> ChatTurnStep.Outcome {
        if IntegrationService.failureCode(in: result) == IntegrationService.creditsExhaustedCode {
            return .outOfCredits
        }
        return IntegrationService.failure(in: result).map(ChatTurnStep.Outcome.failed) ?? .ran
    }

    func approve() {
        approval?.resume(returning: true)
        approval = nil
    }

    /// Approves this card and stops asking about reads from the same product.
    ///
    /// Gated on the continuation, not on the card: a card still on screen for
    /// a round that was already denied or stopped would otherwise write a
    /// standing permission out of a click that approved nothing.
    func approveAlways() {
        guard approval != nil else { return }
        if let provider = pending?.alwaysAllowable {
            approvalPreference?.allowReads(from: provider)
        }
        approve()
    }

    func deny() {
        approval?.resume(returning: false)
        approval = nil
    }

    /// Releases a question that is being cancelled. The continuation has to be
    /// resumed or the task awaiting it never finishes — and it resumes as a
    /// denial, so a turn abandoned mid-approval sends nothing on its way out.
    func cancelPending() {
        guard approval != nil else { return }
        deny()
    }

    /// The round the model asked for, or nil when it named a tool that isn't
    /// on offer — which is the one case a chat must refuse rather than guess
    /// at.
    ///
    /// Grouped by product rather than labelled from the first match: a round
    /// reaching two used to be approved and run as one, under whichever
    /// product happened to come first.
    nonisolated static func match(_ calls: [ChatToolCall], in catalogue: [ChatTool]) -> Round? {
        let matched = calls.compactMap { call in catalogue.first { $0.name == call.name } }
        guard matched.count == calls.count, !matched.isEmpty else { return nil }
        var order: [IntegrationProvider] = []
        var grouped: [IntegrationProvider: [(call: ChatToolCall, tool: ChatTool)]] = [:]
        for (call, tool) in zip(calls, matched) {
            if grouped[tool.provider] == nil { order.append(tool.provider) }
            grouped[tool.provider, default: []].append((call: call, tool: tool))
        }
        let batches = order.map { provider -> Batch in
            let pairs = grouped[provider, default: []]
            return Batch(provider: provider, calls: pairs.map(\.call), tools: pairs.map(\.tool))
        }
        return Round(calls: calls, batches: batches)
    }
}

/// A store that owns a gate and publishes its state as its own.
@MainActor
protocol ChatToolGateHost: AnyObject {
    var toolGate: ChatToolGate { get }
}

extension ChatToolGateHost {
    /// What the model wants to use, waiting on the person. Nothing leaves Nod
    /// while this is set.
    var pendingApproval: ChatToolGate.Pending? {
        toolGate.pending
    }

    /// Which product the chat is talking to right now, so the loader can say so.
    var callingProvider: IntegrationProvider? {
        toolGate.callingProvider
    }

    func approvePendingTools() {
        toolGate.approve()
    }

    func approvePendingToolsAlways() {
        toolGate.approveAlways()
    }

    func denyPendingTools() {
        toolGate.deny()
    }
}
