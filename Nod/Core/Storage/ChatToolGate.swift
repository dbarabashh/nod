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
    /// One card per model turn, not per call — see `ToolApprovalCard`.
    struct Pending: Identifiable, Equatable {
        let id = UUID()
        let provider: IntegrationProvider
        let calls: [ChatToolCall]
        let tools: [ChatTool]

        /// Whether this card may offer to stop asking. Only a card with no
        /// write on it: "always allow" on a batch that sends a message would
        /// buy silence for every message after it, which is not a thing to
        /// agree to once.
        var mayAlwaysAllow: Bool {
            !tools.isEmpty && tools.allSatisfy { !$0.mutating }
        }
    }

    /// Two rounds is enough for search-then-answer or search-then-create. A
    /// third is a model looping, and every round re-sends the whole prompt.
    /// Both chats spend the same budget: it is a cost, not a per-surface taste.
    static let maxRounds = 2

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

    init(unattended: Bool = false, approval: ToolApprovalPreference? = nil) {
        self.unattended = unattended
        approvalPreference = approval
    }

    /// Called when a new question starts, so the last one's scaffolding doesn't
    /// ride along with it.
    func beginQuestion() {
        turns = []
    }

    /// Runs `calls` once the person allows them, and returns what to tell the
    /// model. A denial is an outcome too — the model is told it was declined,
    /// which is what stops it asking again in the same breath.
    ///
    /// `tools` are the catalogue entries matched to `calls`, in the same order.
    /// `onApproved` runs after the person allows the calls and before the first
    /// one goes out — the moment a chat stops waiting on a person and starts
    /// waiting on a product, which is the only thing worth saying out loud
    /// between the two.
    func run(
        _ calls: [ChatToolCall],
        tools: [ChatTool],
        provider: IntegrationProvider,
        using integrations: IntegrationService,
        onApproved: () -> Void = {}
    ) async -> Outcome {
        if unattended {
            let mutates = tools.contains { $0.mutating }
            Log.ui.info(
                "unattended \(provider.rawValue) call(s)=\(calls.count) \(mutates ? "refused — mutating" : "allowed")"
            )
            return await settle(calls, tools: tools, provider: provider, using: integrations, allowed: !mutates)
        }
        // Reads run unasked when the person said they may — the rule the live
        // lookup has always followed ("a read changes nothing"), now available
        // to the chat as well. A batch carrying any write is a write, and shows
        // its card exactly as before.
        if approvalPreference?.runsUnasked(tools, from: provider) == true {
            Log.ui.info("\(calls.count) \(provider.rawValue) read(s) allowed without asking")
            return await settle(calls, tools: tools, provider: provider, using: integrations, allowed: true, onApproved: onApproved)
        }
        Log.ui.info("awaiting approval for \(calls.count) \(provider.rawValue) call(s)")
        // A question asked while an older card still stands supersedes it. The
        // slot holds one continuation: overwriting it used to strand the first
        // task suspended for the rest of the meeting, because cancelling that
        // task does not resume a `withCheckedContinuation`.
        cancelPending()
        pending = Pending(provider: provider, calls: calls, tools: tools)
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
        pending = nil
        return await settle(calls, tools: tools, provider: provider, using: integrations, allowed: allowed, onApproved: onApproved)
    }

    /// Runs what was allowed and writes the turns the model has to see either
    /// way. Shared by the card and the unattended path so a beat's transcript
    /// is assembled by the same code as a person's.
    private func settle(
        _ calls: [ChatToolCall],
        tools: [ChatTool],
        provider: IntegrationProvider,
        using integrations: IntegrationService,
        allowed: Bool,
        onApproved: () -> Void = {}
    ) async -> Outcome {
        var outcome = Outcome()
        // The assistant's request has to be replayed verbatim, or the provider
        // rejects results for calls it can't see in the history.
        outcome.turns.append(LLMProxyClient.ChatTurn(role: .assistant, content: "", toolCalls: calls))
        if allowed {
            callingProvider = provider
            onApproved()
        }
        for (call, tool) in zip(calls, tools) {
            let result = allowed
                ? await integrations.run(call, tool: tool)
                : IntegrationService.declinedResult()
            outcome.turns.append(.init(role: .tool, content: result, toolCallID: call.id))
            outcome.steps.append(ChatTurnStep(
                provider: tool.provider,
                action: tool.action,
                detail: call.recognisableArgument(for: tool),
                outcome: allowed
                    ? IntegrationService.failure(in: result).map(ChatTurnStep.Outcome.failed) ?? .ran
                    : .declined
            ))
        }
        callingProvider = nil
        turns += outcome.turns
        return outcome
    }

    func approve() {
        approval?.resume(returning: true)
        approval = nil
    }

    /// Approves this card and stops asking about reads from the same product.
    func approveAlways() {
        if let pending, pending.mayAlwaysAllow {
            approvalPreference?.allowReads(from: pending.provider)
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

    /// The catalogue entries for `calls`, or nil when the model named a tool
    /// that isn't on offer — which is the one case a chat must refuse rather
    /// than guess at.
    nonisolated static func match(_ calls: [ChatToolCall], in catalogue: [ChatTool]) -> (tools: [ChatTool], provider: IntegrationProvider)? {
        let matched = calls.compactMap { call in catalogue.first { $0.name == call.name } }
        guard matched.count == calls.count, let provider = matched.first?.provider else { return nil }
        return (matched, provider)
    }
}
