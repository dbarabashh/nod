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
        Log.ui.info("awaiting approval for \(calls.count) \(provider.rawValue) call(s)")
        pending = Pending(provider: provider, calls: calls, tools: tools)
        let allowed = await withCheckedContinuation { continuation in
            approval = continuation
        }
        pending = nil

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

    func deny() {
        approval?.resume(returning: false)
        approval = nil
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
