import Combine
import Foundation
import Supabase

/// Drives the chat conversation for the currently-open session. Only one
/// detail view is open at a time, so a single app-level store holding the
/// open meeting's messages is enough — `open(meetingID:)` swaps context and
/// `clear()` resets on sign-out.
///
/// Prompt assembly (profile + recap + transcript) is the caller's job: it
/// passes a ready `systemPrompt` to `send`, keeping this store unaware of how
/// the context is built. RLS scopes every read/write to the owner.
@MainActor
final class ChatStore: ObservableObject {
    enum SendState: Equatable {
        case idle
        case sending
        case failed(String)
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var loadState: MeetingStore.LoadState = .idle
    @Published private(set) var sendState: SendState = .idle

    /// Asking before anything leaves Nod. The same gate the cross-session chat
    /// uses — a session chat reaches the same products, and consent that means
    /// something in one place has to mean the same in the other.
    let toolGate = ChatToolGate()

    private let supabase: SupabaseClient
    private let llm: LLMProxyClient
    private let integrations: IntegrationService
    private static let tableName = "chat_messages"
    /// The tools offered for this question, snapshotted when the question is
    /// asked so the prompt the caller builds, the request, and the match after
    /// a tool call can't be given different catalogues.
    private(set) var availableTools: [ChatTool] = []
    private var gateChanges: AnyCancellable?
    /// Which session's history is loaded. Published so a header rendered beside
    /// the chat can tell "this session's messages" from the previous session's,
    /// still on screen while the swap is in flight.
    @Published private(set) var openMeetingID: UUID?

    init(supabase: SupabaseClient, llm: LLMProxyClient, integrations: IntegrationService) {
        self.supabase = supabase
        self.llm = llm
        self.integrations = integrations
        // The gate holds state this store publishes as its own, and a nested
        // object's changes don't reach a view observing the owner.
        gateChanges = toolGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// What the model wants to use, waiting on the person.
    var pendingApproval: ChatToolGate.Pending? {
        toolGate.pending
    }

    var callingProvider: IntegrationProvider? {
        toolGate.callingProvider
    }

    func approvePendingTools() {
        toolGate.approve()
    }

    func denyPendingTools() {
        toolGate.deny()
    }

    /// Loads the saved conversation for a session. Re-opening the same
    /// meeting keeps the cached messages (no refetch).
    func open(meetingID: UUID) async {
        if openMeetingID == meetingID, case .loaded = loadState { return }
        openMeetingID = meetingID
        messages = []
        sendState = .idle
        loadState = .loading
        #if DEBUG
            if DemoMode.isEnabled {
                messages = DemoData.chat(for: meetingID)
                loadState = .loaded
                return
            }
        #endif
        do {
            let rows: [ChatMessage] = try await supabase
                .from(Self.tableName)
                .select()
                .eq("meeting_id", value: meetingID.uuidString)
                .order("created_at", ascending: true)
                .limit(1000)
                .execute()
                .value
            // Guard against a slow load resolving after the user navigated to
            // a different session.
            guard openMeetingID == meetingID else { return }
            messages = rows
            loadState = .loaded
        } catch {
            Log.ui.error("ChatStore.open failed: \(error.localizedDescription)")
            guard openMeetingID == meetingID else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Optimistically appends + persists the user's turn and enters the
    /// `.sending` state. Call this BEFORE building the (slow) grounding prompt
    /// so the bubble and typing indicator appear instantly; then call `reply`.
    /// Returns false if the turn is empty or a send is already in flight.
    func appendUserTurn(text: String, meetingID: UUID, userID: UUID) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sendState != .sending else { return false }

        let userMessage = ChatMessage.new(meetingID: meetingID, userID: userID, role: .user, content: trimmed)
        messages.append(userMessage)
        sendState = .sending
        await refreshTools()
        await persist(userMessage)
        return true
    }

    /// Enters `.sending` to re-run the model for the last (already-saved) user
    /// turn after a failure. The turn is not re-appended or re-persisted —
    /// doing so would duplicate it in the conversation and `chat_messages`.
    /// Returns false if there's nothing retryable.
    func beginRetry() -> Bool {
        guard sendState != .sending, messages.last?.role == .user else { return false }
        sendState = .sending
        return true
    }

    /// The catalogue for this question. Nothing is offered when nothing is
    /// connected, which keeps the request byte-identical to what it was for
    /// everyone who has linked nothing.
    private func refreshTools() async {
        availableTools = await integrations.chatTools()
    }

    /// Calls the model with the full history and appends + persists the reply.
    /// Pair with `appendUserTurn` / `beginRetry`, which set `.sending` first. On
    /// LLM failure the user turn stays (it's saved) and `sendState` carries the
    /// error so the view can offer a retry.
    ///
    /// `cachePrompt` must be false whenever the caller's `systemPrompt` isn't
    /// the same text turn to turn — see `LLMProxyClient.chat(cachePrompt:)`
    /// for why a varying prefix turns caching into a pure surcharge.
    func reply(systemPrompt: String, meetingID: UUID, userID: UUID, cachePrompt: Bool = true) async {
        guard sendState == .sending else { return }
        toolGate.beginQuestion()
        await requestReply(
            ReplyContext(systemPrompt: systemPrompt, meetingID: meetingID, userID: userID, cachePrompt: cachePrompt),
            round: 0
        )
    }

    /// One question's worth of what a reply needs, so a tool round can ask
    /// again without every caller threading four arguments through.
    private struct ReplyContext {
        let systemPrompt: String
        let meetingID: UUID
        let userID: UUID
        let cachePrompt: Bool
    }

    /// Streamed rather than fetched whole, because tool calls only arrive on the
    /// streaming API. The text is still shown in one piece when it lands: this
    /// chat has never streamed, and starting to is a separate decision from
    /// being able to reach Linear.
    private func requestReply(_ context: ReplyContext, round: Int) async {
        let history = messages.chatTurns + toolGate.turns
        var answer = ""
        var requested: [ChatToolCall] = []
        do {
            // Low temperature: grounded answers about a real recording should
            // stay faithful, not creative.
            for try await event in llm.streamChat(
                system: context.systemPrompt,
                history: history,
                tools: availableTools,
                temperature: 0.2,
                cachePrompt: context.cachePrompt
            ) {
                switch event {
                case let .delta(delta): answer += delta
                case let .toolCalls(calls): requested = calls
                }
            }
        } catch {
            Log.ui.error("ChatStore.send LLM failed: \(error.localizedDescription)")
            guard openMeetingID == context.meetingID else { return }
            sendState = .failed(error.localizedDescription)
            return
        }
        guard openMeetingID == context.meetingID else { return }

        // The model asked for a tool instead of answering. Nothing has gone
        // anywhere yet: the calls go to the user first, and only an approval
        // runs them.
        if !requested.isEmpty, answer.isEmpty, round < ChatToolGate.maxRounds {
            await runTools(requested, context: context, round: round)
            return
        }

        // A model that spent its rounds asking for tools and never wrote a word
        // leaves nothing to show. An empty bubble reads as a broken answer and
        // would be persisted as one, so the turn fails instead and the user can
        // retry it.
        guard !answer.isEmpty else {
            Log.ui.error("ChatStore: reply ended with no text round=\(round) requested=\(requested.count)")
            sendState = .failed("Nod couldn't finish that answer.")
            return
        }

        let assistantMessage = ChatMessage.new(
            meetingID: context.meetingID,
            userID: context.userID,
            role: .assistant,
            content: answer
        )
        messages.append(assistantMessage)
        sendState = .idle
        await persist(assistantMessage)
    }

    private func runTools(_ calls: [ChatToolCall], context: ReplyContext, round: Int) async {
        guard let matched = ChatToolGate.match(calls, in: availableTools) else {
            Log.ui.error("ChatStore: model asked for an unknown tool")
            sendState = .failed(ChatToolGate.unknownToolMessage)
            return
        }
        _ = await toolGate.run(
            calls,
            tools: matched.tools,
            provider: matched.provider,
            using: integrations
        )
        guard openMeetingID == context.meetingID else { return }
        // The history now carries the call and its result, so it no longer
        // matches the prefix the provider has on file.
        await requestReply(
            ReplyContext(
                systemPrompt: context.systemPrompt,
                meetingID: context.meetingID,
                userID: context.userID,
                cachePrompt: false
            ),
            round: round + 1
        )
    }

    func clear() {
        messages = []
        loadState = .idle
        sendState = .idle
        openMeetingID = nil
    }

    /// Permanently deletes the saved conversation for a session. The session
    /// itself (recording, summary, transcript) is untouched.
    func clearHistory(meetingID: UUID) async {
        #if DEBUG
            if DemoMode.isEnabled {
                if openMeetingID == meetingID {
                    messages = []
                    sendState = .idle
                }
                return
            }
        #endif
        do {
            try await supabase
                .from(Self.tableName)
                .delete()
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
            guard openMeetingID == meetingID else { return }
            messages = []
            sendState = .idle
        } catch {
            Log.ui.error("ChatStore.clearHistory failed: \(error.localizedDescription)")
        }
    }

    /// Best-effort persistence — a network blip shouldn't drop the turn from
    /// the on-screen conversation, so a failed insert is logged, not surfaced.
    private func persist(_ message: ChatMessage) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        do {
            try await supabase.from(Self.tableName).insert(message).execute()
        } catch {
            Log.ui.error("ChatStore.persist failed (non-fatal): \(error.localizedDescription)")
        }
    }
}
