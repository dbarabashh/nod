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
final class ChatStore: ObservableObject, ChatToolGateHost {
    enum SendState: Equatable {
        case idle
        case sending
        case failed(ChatFailure)
        /// The person stopped this turn. Not a failure — nothing went wrong,
        /// and the row that says so offers no apology and no retry button.
        case stopped
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var loadState: MeetingStore.LoadState = .idle
    @Published private(set) var sendState: SendState = .idle
    /// Turns that are on screen but not in `chat_messages`. The insert is
    /// best-effort by design, and a turn that will be gone tomorrow has to say
    /// so rather than looking exactly like a saved one.
    @Published private(set) var unsavedMessageIDs: Set<UUID> = []
    /// What this turn did before it answered — kept so a failure can show the
    /// tool calls that ran before it, which is the difference between "nothing
    /// happened" and "the ticket exists, the answer doesn't".
    private(set) var turnSteps: [ChatTurnStep] = []
    /// A read was refused this turn because the integration credits are spent.
    /// Published on its own because the steps are not: the answer still
    /// arrives, and the thread has to say under it why it came from memory.
    @Published private(set) var turnRanOutOfCredits = false

    /// Asking before anything leaves Nod. The same gate the cross-session chat
    /// uses — a session chat reaches the same products, and consent that means
    /// something in one place has to mean the same in the other.
    let toolGate: ChatToolGate

    private let supabase: SupabaseClient
    private let llm: LLMProxyClient
    private let integrations: IntegrationService
    private static let tableName = "chat_messages"
    /// The tools offered for this question, snapshotted when the question is
    /// asked so the prompt the caller builds, the request, and the match after
    /// a tool call can't be given different catalogues.
    private(set) var availableTools: [ChatTool] = []
    private var gateChanges: AnyCancellable?
    /// The turn in flight, so `cancel()` has something to stop. Unstructured
    /// on purpose: it must not inherit cancellation from whatever view task
    /// happened to start it.
    private var inFlight: Task<Void, Never>?
    /// Which session's history is loaded. Published so a header rendered beside
    /// the chat can tell "this session's messages" from the previous session's,
    /// still on screen while the swap is in flight.
    @Published private(set) var openMeetingID: UUID?

    init(
        supabase: SupabaseClient,
        llm: LLMProxyClient,
        integrations: IntegrationService,
        toolApproval: ToolApprovalPreference? = nil,
        toolLog: ToolApprovalLog? = nil
    ) {
        self.supabase = supabase
        self.llm = llm
        self.integrations = integrations
        toolGate = ChatToolGate(approval: toolApproval, log: toolLog)
        // The gate holds state this store publishes as its own, and a nested
        // object's changes don't reach a view observing the owner.
        gateChanges = toolGate.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Loads the saved conversation for a session. Re-opening the same
    /// meeting keeps the cached messages (no refetch).
    func open(meetingID: UUID) async {
        if openMeetingID == meetingID, case .loaded = loadState { return }
        // A turn still running against the session being navigated away from
        // would land its answer in a conversation nobody is looking at.
        cancel()
        openMeetingID = meetingID
        messages = []
        sendState = .idle
        turnRanOutOfCredits = false
        unsavedMessageIDs = []
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
    func appendUserTurn(text: String, meetingID: UUID) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sendState != .sending else { return false }

        guard let userID = authorID else { return false }
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

    /// Re-asks the last question, dropping the answer it produced.
    ///
    /// Scoped to the newest answer: regenerating an older one would orphan
    /// every turn after it, which was written against the answer being
    /// replaced. Returns the question to re-send, or nil when there is none.
    func beginRegenerate() async -> String? {
        guard sendState != .sending, let last = messages.last, last.role == .assistant else { return nil }
        guard let question = messages.last(where: { $0.role == .user })?.content else { return nil }
        messages.removeLast()
        unsavedMessageIDs.remove(last.id)
        // Not awaited: the replaced row and the new turn touch different rows,
        // so making the reply wait on a delete round trip only delays the first
        // token of the answer the user just asked for.
        Task { await delete(last.id) }
        sendState = .sending
        return question
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
    func reply(systemPrompt: String, meetingID: UUID, cachePrompt: Bool = true) async {
        guard let userID = authorID else { return }
        guard sendState == .sending else { return }
        toolGate.beginQuestion()
        turnSteps = []
        turnRanOutOfCredits = false
        let context = ReplyContext(
            systemPrompt: systemPrompt,
            meetingID: meetingID,
            userID: userID,
            cachePrompt: cachePrompt
        )
        // Run in a task this store owns rather than the caller's, so `cancel()`
        // has something to stop. Awaiting it keeps the call site — which reads
        // `sendState` once this returns — working unchanged.
        let task = Task { await requestReply(context, round: 0) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    /// Stops the turn in flight.
    ///
    /// This chat shows its answer whole rather than streaming it, so there is
    /// never half a reply to keep: a stopped turn leaves the question standing
    /// and `.stopped` on screen, and the same question is re-asked with Retry.
    func cancel() {
        guard inFlight != nil else { return }
        Log.ui.info("session chat turn cancelled")
        // Ahead of the cancel: a turn parked on the approval card is suspended
        // on a continuation, and a cancelled task never reaches the resume.
        toolGate.cancelPending()
        inFlight?.cancel()
        inFlight = nil
        sendState = .stopped
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
                if Task.isCancelled { break }
                switch event {
                case let .delta(delta): answer += delta
                case let .toolCalls(calls): requested = calls
                }
            }
        } catch is CancellationError {
            Log.ui.info("ChatStore reply cancelled")
            return
        } catch {
            Log.ui.error("ChatStore.send LLM failed: \(error.localizedDescription)")
            guard openMeetingID == context.meetingID else { return }
            sendState = .failed(ChatFailure(error, steps: turnSteps))
            return
        }
        guard openMeetingID == context.meetingID, !Task.isCancelled else { return }

        // The model asked for a tool instead of answering. Nothing has gone
        // anywhere yet: the calls go to the user first, and only an approval
        // runs them.
        if !requested.isEmpty, answer.isEmpty, !Task.isCancelled, round < ChatToolGate.maxRounds {
            await runTools(requested, context: context, round: round)
            return
        }

        // A model that spent its rounds asking for tools and never wrote a word
        // leaves nothing to show. An empty bubble reads as a broken answer and
        // would be persisted as one, so the turn fails instead and the user can
        // retry it.
        guard !answer.isEmpty else {
            Log.ui.error("ChatStore: reply ended with no text round=\(round) requested=\(requested.count)")
            sendState = .failed(.emptyAnswer(steps: turnSteps))
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
            sendState = .failed(.unknownTool(steps: turnSteps))
            return
        }
        let outcome = await toolGate.run(
            calls,
            tools: matched.tools,
            provider: matched.provider,
            using: integrations
        )
        turnSteps += outcome.steps
        // A stop while the approval card was up resumes the gate as a denial;
        // going back to the model with that spends a round on an answer nobody
        // is waiting for any more.
        guard openMeetingID == context.meetingID, !Task.isCancelled else { return }
        if outcome.steps.ranOutOfCredits { turnRanOutOfCredits = true }
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
        cancel()
        messages = []
        loadState = .idle
        sendState = .idle
        turnRanOutOfCredits = false
        unsavedMessageIDs = []
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
                    turnRanOutOfCredits = false
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
            turnRanOutOfCredits = false
            unsavedMessageIDs = []
        } catch {
            Log.ui.error("ChatStore.clearHistory failed: \(error.localizedDescription)")
        }
    }

    /// Best-effort persistence — a network blip shouldn't drop the turn from
    /// the on-screen conversation, so a failed insert is logged, not surfaced.
    /// Who a row written now belongs to: whoever is signed in, asked rather
    /// than passed.
    ///
    /// The call site used to hand over `meeting.userID`, which is the same
    /// person right up until the session is one somebody shared — and then the
    /// insert carries the owner's id while `chat_messages` checks
    /// `auth.uid() = user_id`, so every turn on a colleague's session came back
    /// "Not saved to this session". The read policy already says a chat belongs
    /// to the person having it; this makes the write agree.
    private var authorID: UUID? {
        supabase.auth.currentSession?.user.id
    }

    private func persist(_ message: ChatMessage) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        do {
            try await supabase.from(Self.tableName).insert(message).execute()
            unsavedMessageIDs.remove(message.id)
        } catch {
            // Still best-effort — a network blip must not drop the turn from
            // the conversation on screen. What changed is that it no longer
            // does so silently: a turn that will be gone tomorrow says so.
            Log.ui.error("ChatStore.persist failed (non-fatal): \(error.localizedDescription)")
            unsavedMessageIDs.insert(message.id)
        }
    }

    /// Re-saves a turn whose insert failed. The row carries its own id, so a
    /// retry landing after a first attempt secretly succeeded is a
    /// duplicate-key error, not a duplicate turn.
    func retrySaving(_ id: UUID) async {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        await persist(message)
    }

    /// Removes one turn from `chat_messages`. Used when an answer is
    /// regenerated — the replaced reply has to leave the table too, or
    /// reopening the session shows the question answered twice.
    private func delete(_ id: UUID) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        do {
            try await supabase.from(Self.tableName).delete().eq("id", value: id.uuidString).execute()
        } catch {
            Log.ui.error("ChatStore.delete failed: \(error.localizedDescription)")
        }
    }
}
