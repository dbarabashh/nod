import SwiftUI

/// Chat with one recorded session. Self-contained: loads the saved
/// conversation + the session transcript, assembles the grounding system
/// prompt (profile + recap + transcript), and drives `ChatStore`.
struct SessionChatView: View {
    let meeting: Meeting

    @EnvironmentObject private var chatStore: ChatStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @EnvironmentObject private var llm: LLMProxyClient
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var reachability: NetworkReachability

    /// Above this transcript size we retrieve the parts relevant to the
    /// question instead of stuffing the whole thing. Set high (≈ a multi-hour
    /// meeting) so a typical session is answered against its FULL transcript —
    /// the old 8K cap pushed most meetings onto an 8-chunk RAG path that missed
    /// content phrased differently from the question (e.g. "client" vs the
    /// transcript's "audience") and made the model lean on the recap. Only
    /// genuinely long sessions now fall back to retrieval.
    private static let longTranscriptChars = 50_000

    /// Ceiling on the transcript we send when retrieval isn't trustworthy.
    /// ~4 hours of dialogue; beyond it the prompt would cost more than the
    /// answer is worth, so the head is all that goes.
    private static let transcriptHardCap = 200_000

    @State private var draft: String = ""
    /// nil until the transcript load resolves — the composer stays disabled
    /// until then so the first message is always fully grounded.
    @State private var transcriptText: String?
    /// Chunks this transcript *should* have in the index — the yardstick for
    /// whether retrieval can be trusted to stand in for the whole session.
    @State private var expectedChunks = 0
    @State private var didRepairIndex = false
    /// The first time saved history lands we jump to the bottom; every later
    /// update animates. Reset per-meeting because the view is rebuilt with
    /// `.id(meeting.id)`.
    /// The language baked into the last system prompt this session sent —
    /// compared against on the next turn so a language switch (the STYLE
    /// section's `LANGUAGE:` line, ahead of the transcript in the same
    /// string) is caught as a prefix change, not just a change inside the
    /// retrieved excerpts. Nil before the first turn, which nothing is
    /// cached against yet.
    @State private var lastSystemPromptLanguage: AppLanguage?
    @State private var didInitialScroll = false
    /// The scroll content stays hidden until that first jump lands, so the
    /// chat appears already at the bottom instead of visibly scrolling down.
    @State private var positioned = false
    @State private var inputFocused = false
    /// A question typed while the previous one was still answering. This chat
    /// carries no scope or mentions into the store, so the text is the whole
    /// of it.
    @State private var queued: String?

    /// Freshest copy so chat grounds on the latest edited recap/title.
    private var current: Meeting {
        meetingStore.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private var hostName: String? {
        organizations.nameOfOwner(current.userID)
    }

    private var isSending: Bool {
        chatStore.sendState == .sending
    }

    private var isFinalizing: Bool {
        meetingStore.finalizingMeetingIDs.contains(meeting.id)
    }

    private var isReady: Bool {
        !isFinalizing && transcriptText != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await chatStore.open(meetingID: meeting.id)
            if !isFinalizing {
                await loadTranscript()
            }
        }
        .onChange(of: isFinalizing) { finalizing in
            if finalizing {
                transcriptText = nil
            } else {
                Task { await loadTranscript() }
            }
        }
    }

    // MARK: - Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatStore.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chatStore.messages) { message in
                        bubble(message).id(message.id)
                    }
                    // Separate elements with separate identities. Sharing one
                    // anchor between the two lets SwiftUI treat the swap as
                    // "same view, unchanged" and keep the indicator on screen
                    // while an approval is already waiting.
                    if let approval = chatStore.pendingApproval {
                        ToolApprovalCard(
                            approval: approval,
                            onApprove: chatStore.approvePendingTools,
                            onApproveAlways: chatStore.approvePendingToolsAlways,
                            onDeny: chatStore.denyPendingTools
                        )
                        .id(approval.id)
                    }
                    if isSending, chatStore.pendingApproval == nil {
                        typingIndicator.id(ChatTranscriptSupport.Anchor.typing)
                    }
                    if chatStore.turnRanOutOfCredits, chatStore.sendState == .idle {
                        ChatCreditsNotice()
                            .id(ChatTranscriptSupport.Anchor.credits)
                    }
                    switch chatStore.sendState {
                    case let .failed(failure):
                        ChatErrorRow(failure: failure) { send(retryLast: true) }
                            .id(ChatTranscriptSupport.Anchor.failure)
                    case .stopped:
                        ChatNoteRow(
                            icon: "nc-hand",
                            text: "You stopped this answer.",
                            action: ("Ask again", { send(retryLast: true) })
                        )
                        .id(ChatTranscriptSupport.Anchor.failure)
                    case .idle, .sending:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .opacity(positioned ? 1 : 0)
            .onAppear { positionInitially(proxy) }
            .onChange(of: chatStore.messages.count) { _ in
                if didInitialScroll { scrollToEnd(proxy) } else { positionInitially(proxy) }
            }
            .onChange(of: chatStore.loadState) { _ in positionInitially(proxy) }
            .onChange(of: chatStore.sendState) { _ in scrollToEnd(proxy) }
            // The card arrives without a message or a state change to announce
            // it, and a question the user cannot see is one they cannot answer.
            .onChange(of: chatStore.pendingApproval) { _ in scrollToEnd(proxy) }
        }
        // The link coming back is the one thing that fixes an offline turn, and
        // it fixes it without anybody clicking. `NetworkPathMonitor` decides
        // *when to retry what already failed* — never whether to send, which
        // would be the TOCTOU race its own documentation warns about.
        .onChange(of: reachability.isOnline) { online in
            guard online, case let .failed(failure) = chatStore.sendState, failure.isOffline else { return }
            send(retryLast: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this \(kindNoun)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            VStack(alignment: .leading, spacing: 5) {
                suggestion("What were the main takeaways?")
                suggestion("What did I commit to?")
                suggestion("Draft a follow-up message.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    private func suggestion(_ text: String) -> some View {
        ChatSuggestionChip(text: text) {
            draft = text
            inputFocused = true
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            ChatUserTurn(text: message.content, marks: marks(in: message.content)) {
                notes(for: message.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                AssistantTextBubble(content: message.content, onRegenerate: regenerateAction(for: message))
                notes(for: message.id)
            }
            .padding(.trailing, 40)
        }
    }

    private func regenerateAction(for message: ChatMessage) -> (() -> Void)? {
        ChatTranscriptSupport.regenerateAction(
            isNewest: message.id == chatStore.messages.last?.id,
            isBusy: isSending,
            regenerate
        )
    }

    private func notes(for id: UUID) -> some View {
        ChatTurnNotes(isUnsaved: chatStore.unsavedMessageIDs.contains(id), storeNoun: "this session") {
            Task { await chatStore.retrySaving(id) }
        }
    }

    private var typingIndicator: some View {
        ThinkingIndicator(
            script: chatStore.callingProvider.map(ChatThinking.calling) ?? ChatThinking.reviewing,
            icon: chatStore.callingProvider?.iconName
        )
        .padding(.vertical, 4)
    }

    // MARK: - Composer

    private var composer: some View {
        ChatComposer(
            prompt: composerPrompt,
            text: $draft,
            isFocused: $inputFocused,
            isEnabled: isReady,
            canSend: canSend,
            isGenerating: isSending,
            onStop: chatStore.cancel,
            // Sessions and tools. Projects are not on offer: this chat answers
            // from one transcript and has no scope to narrow, and a panel that
            // lists one promises reach the answer has not got.
            sources: ChatMentionSources(sessions: otherSessions, tools: true),
            mentions: marks(in: draft, opens: false),
            onPick: { if case .connectTool = $0 { settingsFocus.open(.integrations) } },
            onSend: { send() }
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    /// Every session but this one — mentioning the transcript you are already
    /// reading adds nothing.
    private var otherSessions: [Meeting] {
        meetingStore.meetings.filter { $0.id != meeting.id }
    }

    /// The sessions a piece of text names, resolved against the store now
    /// rather than tracked as it is typed: deleting the words drops the
    /// mention, which is what deleting them should do.
    ///
    /// The `@` test comes first because it is the cheap one — this runs for the
    /// draft on every keystroke and for every visible turn.
    private func mentionedSessions(in text: String) -> [Meeting] {
        MentionMark.named(in: text, from: otherSessions) { MentionMark(session: $0) }
    }

    /// A sent turn's pills carry their session; the ones in the field do not,
    /// because the question they belong to is still being written.
    ///
    /// Tools are named the same way and drawn the same way. Which one the model
    /// actually calls is its decision — the token says which product the person
    /// meant, and every call still stops at the approval card.
    private func marks(in text: String, opens: Bool = true) -> [MentionMark] {
        mentionedSessions(in: text).map { MentionMark(session: $0, opens: opens) }
            + MentionMark.namedTools(in: text).map(MentionMark.init(tool:))
    }

    /// The send button is swapped for Stop while a turn runs, so this only has
    /// to answer "is there anything to send" — a question written mid-answer is
    /// queued rather than refused.
    private var canSend: Bool {
        isReady && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerPrompt: String {
        guard isReady else { return isFinalizing ? "Finishing session…" : "Loading session…" }
        // The wait is the composer's business too: a field that says nothing
        // while an answer runs looks disabled, and one that says what pressing
        // Return will do turns the wait into somewhere to keep working.
        if queued != nil { return "Queued — sends when this answer finishes" }
        if isSending { return "Ask something else while you wait…" }
        return "Message  (@ for sessions and tools)"
    }

    // MARK: - Actions

    private func send(retryLast: Bool = false) {
        guard !retryLast else {
            // The last user turn is already saved; resend it to get a reply.
            guard let lastUserIndex = chatStore.messages.lastIndex(where: { $0.role == .user }) else { return }
            start(
                question: chatStore.messages[lastUserIndex].content,
                priorTurns: chatStore.messages[..<lastUserIndex],
                resend: true
            )
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        draft = ""
        // One deep. A second question written while one is queued replaces it:
        // a backlog nobody can see or edit is worse than losing the older of
        // two things typed in the same ten seconds.
        guard !isSending else {
            queued = text
            return
        }
        start(question: text, priorTurns: chatStore.messages[...], resend: false)
    }

    /// Re-asks the last question, dropping the answer it produced. The prior
    /// history is read before the answer leaves, so the question is resolved
    /// against exactly the conversation it was first asked in.
    private func regenerate() {
        guard let lastUserIndex = chatStore.messages.lastIndex(where: { $0.role == .user }) else { return }
        let priorHistory = Array(chatStore.messages[..<lastUserIndex]).chatTurns
        Task {
            guard let question = await chatStore.beginRegenerate() else { return }
            await answer(question, priorHistory: priorHistory)
        }
    }

    /// `resend` means the user turn is already in the conversation and in
    /// `chat_messages` — appending it again would duplicate it in both.
    private func start(question: String, priorTurns: ArraySlice<ChatMessage>, resend: Bool) {
        // Conversation before the current question — what query prep resolves
        // follow-up references against.
        let priorHistory = Array(priorTurns).chatTurns
        Task {
            // Show the user's bubble + typing indicator immediately, then build
            // the (slow) grounding prompt while "thinking" is on screen — so the
            // chat never looks empty between pressing send and the reply landing.
            let started = resend
                ? chatStore.beginRetry()
                : await chatStore.appendUserTurn(text: question, meetingID: meeting.id)
            guard started else { return }
            await answer(question, priorHistory: priorHistory)
        }
    }

    private func answer(_ question: String, priorHistory: [LLMProxyClient.ChatTurn]) async {
        let built = await buildSystemPrompt(for: question, history: priorHistory)
        await chatStore.reply(
            systemPrompt: built.system,
            meetingID: meeting.id,
            cachePrompt: built.cacheable
        )
        if chatStore.sendState == .idle {
            analytics.record(
                .aiActionCompleted,
                properties: .init(
                    sessionKind: current.kind.rawValue,
                    entryPoint: .meetingDetail,
                    surface: .ask,
                    contentType: .answer,
                    aiFeature: .meetingAsk,
                    outcome: .success
                )
            )
        }
        if let next = queued {
            queued = nil
            start(question: next, priorTurns: chatStore.messages[...], resend: false)
        }
    }

    /// `cacheable` says whether this turn's `system` is the same text a
    /// caching provider would already have on file from the last turn — see
    /// `LLMProxyClient.chat(cachePrompt:)`. The cache breakpoint covers the
    /// WHOLE system string, so two things can break it: retrieval chunks
    /// (chosen fresh per question) and the detected reply language (the
    /// STYLE section's `LANGUAGE:` line, which sits ahead of the transcript
    /// — see `buildChatSystem`). Either one changing makes the write-only,
    /// never matches the prior turn's prefix.
    private func buildSystemPrompt(
        for query: String,
        history: [LLMProxyClient.ChatTurn]
    ) async -> (system: String, cacheable: Bool) {
        // Match the user's typed language; fall back to the meeting's language.
        let language = AppLanguage.detect(from: query) ?? AppLanguage(rawValue: current.language) ?? .english
        let languageStableSinceLastTurn = lastSystemPromptLanguage == nil || lastSystemPromptLanguage == language
        lastSystemPromptLanguage = language
        let full = transcriptText ?? ""
        var grounding = full
        var isExcerpt = false
        var cacheable = languageStableSinceLastTurn
        if full.count > Self.longTranscriptChars {
            // Retrieval only stands in for the transcript when the index
            // actually covers the session. A run that died part-way leaves the
            // opening minutes indexed and nothing else, and every question then
            // retrieves the same small talk — which the model reports as the
            // whole meeting ("that was never discussed") while the recap, built
            // from the full transcript, says otherwise.
            if await knowledgeStore.coversTranscript(meetingID: meeting.id, expectedChunks: expectedChunks) {
                // HyDE: resolve the question (and any follow-up reference) into a
                // standalone query and embed a hypothetical transcript-style
                // answer.
                let prepared = await llm.prepareSearchQuery(
                    history: history,
                    query: query,
                    language: language,
                    personalContext: profileStore.promptContext
                )
                let chunks = await knowledgeStore.search(
                    query: prepared.standalone,
                    matchCount: 16,
                    meetingID: meeting.id,
                    embedText: prepared.hyde
                )
                if chunks.isEmpty {
                    grounding = String(full.prefix(Self.transcriptHardCap))
                    isExcerpt = grounding.count < full.count
                } else {
                    grounding = chunks.map(\.content).joined(separator: "\n…\n")
                    isExcerpt = true
                    cacheable = false
                }
            } else {
                grounding = String(full.prefix(Self.transcriptHardCap))
                isExcerpt = grounding.count < full.count
                repairIndex(full)
            }
        }
        let mentioned = await mentionedGrounding(for: query, sessions: mentionedSessions(in: query))
        // A mention widens the grounding for this turn only, so the system text
        // differs from the last one and the provider has nothing on file for it.
        if !mentioned.isEmpty { cacheable = false }
        let system = PromptLibrary.buildChatSystem(
            sessionKind: current.kind,
            title: current.title ?? "",
            summary: current.summary,
            transcript: grounding,
            transcriptIsExcerpt: isExcerpt,
            mentionedSessions: mentioned,
            connectedTools: chatStore.availableTools,
            language: language,
            personalContext: profileStore.promptContext,
            meetingDate: PromptLibrary.sessionDateString(current.startedAt),
            host: hostName
        )
        return (system, cacheable)
    }

    /// What an `@session` in the question brings with it: that session's recap,
    /// plus the passages retrieval finds in it for this question.
    ///
    /// This chat answers from one transcript by design. A mention is the one
    /// way to widen that, and it widens it for the turn it was written in —
    /// nothing is carried into the next question.
    private func mentionedGrounding(for query: String, sessions: [Meeting]) async -> String {
        guard !sessions.isEmpty else { return "" }
        let chunks = await knowledgeStore.search(
            query: query,
            matchCount: min(sessions.count * 6, 24),
            meetingIDs: sessions.map(\.id)
        )
        let excerpts = Dictionary(grouping: chunks, by: \.meetingID)
        return sessions.map { session in
            PromptLibrary.sessionGroundingBlock(
                label: "\(session.displayTitle(dateFormatter: Meeting.shortDateFormatter)) — \(PromptLibrary.sessionDateString(session.startedAt))",
                recap: session.summary,
                excerpts: excerpts[session.id]?.map(\.content) ?? []
            )
        }
        .joined(separator: "\n\n")
    }

    /// Rebuilds a short index in the background so the next question on this
    /// session is served by retrieval again instead of the whole transcript.
    private func repairIndex(_ transcript: String) {
        guard !didRepairIndex else { return }
        didRepairIndex = true
        Log.ui.info("SessionChatView repairing short index meeting=\(meeting.id.uuidString)")
        Task { await knowledgeStore.index(meetingID: meeting.id, transcript: transcript) }
    }

    private func loadTranscript() async {
        // Alongside the transcript, but awaited before the text is built: the
        // labels are baked into the cached string once, and a directory that
        // lands a moment later would leave every line of somebody else's
        // session tagged [Me] for the rest of the conversation.
        async let directory: Void = organizations.refreshDirectoryIfNeeded()
        do {
            let records = try await meetingStore.fetchTranscript(meetingID: meeting.id)
            await directory
            let text = records.promptContext(names: meeting.speakerNames, host: hostName)
            expectedChunks = KnowledgeStore.chunk(text).count
            transcriptText = text
        } catch {
            Log.ui.error("SessionChatView transcript load failed: \(error.localizedDescription)")
            // Empty (not nil) so chat still works off the recap alone.
            transcriptText = ""
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollToEnd(scrollTarget)
    }

    /// Place the chat at the bottom before it's first shown. The content is
    /// hidden until this runs, so there's no visible scroll. The jump is
    /// deferred a runloop so the `LazyVStack` rows are laid out first —
    /// scrolling during the same update lands short of the true bottom.
    private func positionInitially(_ proxy: ScrollViewProxy) {
        guard !didInitialScroll else { return }
        guard let target = scrollTarget else {
            // Nothing to scroll to yet. Reveal an empty chat only once the load
            // has settled; keep waiting while it's still idle or loading so we
            // don't mark the initial scroll done before history arrives.
            switch chatStore.loadState {
            case .loaded, .failed:
                didInitialScroll = true
                positioned = true
            case .idle, .loading:
                break
            }
            return
        }
        didInitialScroll = true
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: .bottom)
            positioned = true
        }
    }

    private var scrollTarget: AnyHashable? {
        if let approval = chatStore.pendingApproval { return AnyHashable(approval.id) }
        if isSending { return AnyHashable(ChatTranscriptSupport.Anchor.typing) }
        switch chatStore.sendState {
        // A failure or a stop arrives without a message to announce it, and one
        // the user cannot see is one they cannot act on.
        case .failed, .stopped: return AnyHashable(ChatTranscriptSupport.Anchor.failure)
        case .idle where chatStore.turnRanOutOfCredits: return AnyHashable(ChatTranscriptSupport.Anchor.credits)
        case .idle, .sending: return chatStore.messages.last.map { AnyHashable($0.id) }
        }
    }

    private var kindNoun: String {
        switch current.kind {
        case .meeting: "meeting"
        case .voiceNote: "voice note"
        case .media: "recording"
        }
    }
}
