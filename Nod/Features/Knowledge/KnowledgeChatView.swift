import SwiftUI

/// "Ask Nod" — chat across everything the user has recorded. Each question
/// runs a semantic search over all their sessions, feeds the closest excerpts
/// to the model as grounding, and answers with light citations. The
/// conversation is ephemeral (in-memory) for now; the value is the synthesis,
/// not the transcript of the asking.
struct KnowledgeChatView: View {
    /// Navigate the host (the Meetings window's left column) to a session —
    /// used when a mention or source is clicked.
    let onOpenMeeting: (UUID) -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @EnvironmentObject private var entitlements: EntitlementService
    /// The thread itself — shared with any other surface onto the same
    /// conversation, so a question asked in the launcher can be continued here.
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var analytics: ProductAnalytics
    @EnvironmentObject private var reachability: NetworkReachability

    private typealias SessionRef = KnowledgeChatStore.SessionRef

    /// A question written while the previous one was still answering. Held in
    /// the view because a queued question is a draft with its mentions and its
    /// scope resolved — exactly what the composer owns — and not yet anything
    /// the thread knows about.
    private struct QueuedQuestion {
        let text: String
        let pinned: [SessionRef]
        let scope: [SessionLabel]
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: String = ""
    @State private var inputFocused = false
    @State private var queued: QueuedQuestion?

    /// Sessions the user pinned with @ — when non-empty the question is scoped
    /// to exactly these (the router is skipped; the user said what they want).
    @State private var mentions: [SessionRef] = []

    /// Resolved against the store rather than held as models, so a renamed or
    /// deleted folder can't leave a stale name in the composer.
    private var scopeLabels: [SessionLabel] {
        labelStore.labels.filter { chat.scopeLabelIDs.contains($0.id) }
    }

    var body: some View {
        Group {
            // Cross-session "Ask Nod" is a Pro feature (`ask_across_meetings`).
            // The server enforces it too; this gate is the UX side — show an
            // upsell instead of a composer that would only 403.
            if canAskAcross {
                VStack(spacing: 0) {
                    if chat.messages.isEmpty {
                        chatHome
                    } else {
                        messageList
                    }
                    composer
                }
            } else {
                upsell
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await meetingStore.refresh() }
        // Scope follows the sentence, however the sentence got there — picking
        // a project from the panel and typing its name by hand are the same
        // act, and deleting the words unscopes the question again.
        .onChange(of: draft) { _ in syncScope() }
        .onChange(of: chat.pendingDraft) { _ in adoptPendingDraft() }
        // Also on appear: a draft handed over from another surface (Today's
        // composer, "Ask about this project") is set while this view is not
        // mounted, and `onChange` never fires for a value that was already
        // there when the view arrived — the question typed elsewhere vanished.
        .onAppear(perform: adoptPendingDraft)
        // The link coming back is the one thing that fixes an offline turn, and
        // it fixes it without anybody clicking. `NetworkPathMonitor` exists to
        // decide *when to retry what already failed* — never to gate a send,
        // which would be the TOCTOU race its own documentation warns about.
        .onChange(of: reachability.isOnline) { online in
            guard online, chat.failure?.isOffline == true else { return }
            Task { await chat.regenerateLast() }
        }
        .onChange(of: labelStore.labels) { labels in
            let live = Set(labels.map(\.id))
            guard !chat.scopeLabelIDs.isSubset(of: live) else { return }
            chat.scopeLabelIDs.formIntersection(live)
        }
        // Intercept taps on inline mention links (nod-meeting://m/<uuid>).
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "nod-meeting", let id = UUID(uuidString: url.lastPathComponent) else {
                return .systemAction
            }
            onOpenMeeting(id)
            return .handled
        })
    }

    /// Fail OPEN on an unresolved entitlement (nil / load failure): the proxy is
    /// the real gate and also fails open, so a Pro user whose entitlement fetch
    /// transiently failed isn't wrongly shown the upsell for a feature they own.
    private var canAskAcross: Bool {
        entitlements.entitlement == nil || entitlements.can(.askAcrossMeetings)
    }

    private var upsell: some View {
        VStack(spacing: 12) {
            Image("nc-sparkle-3")
                .icon(30)
                .foregroundStyle(Theme.Palette.violet)
            Text("Ask across everything you've captured")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text(
                "One memory instead of a pile of notes: ask across every session you've kept, and get the answer with the session it came from. Available on Pro."
            )
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.Palette.graphite)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
            } label: {
                Text("Upgrade to Pro")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 28)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chat.messages) { message in
                        bubble(message)
                            .id(message.id)
                            .transition(.answerArrival(reduceMotion: reduceMotion))
                    }
                    // Stays below the paragraphs already written, for as long as
                    // more are coming: it is the only thing on screen that says
                    // the answer isn't finished, and losing it at the first
                    // paragraph would read as a truncated reply.
                    // Separate elements with separate identities. Sharing
                    // `typingAnchor` between the two let SwiftUI treat the swap
                    // as "same view, unchanged" and keep the indicator on screen
                    // while an approval was already waiting.
                    if let approval = chat.pendingApproval {
                        ToolApprovalCard(
                            approval: approval,
                            onApprove: chat.approvePendingTools,
                            onApproveAlways: chat.approvePendingToolsAlways,
                            onDeny: chat.denyPendingTools
                        )
                        .id(ChatTranscriptSupport.Anchor.approval)
                    }
                    if chat.isSending, chat.pendingApproval == nil {
                        typingIndicator.id(ChatTranscriptSupport.Anchor.typing)
                    }
                    if let failure = chat.failure {
                        ChatErrorRow(failure: failure) { Task { await chat.regenerateLast() } }
                            .id(ChatTranscriptSupport.Anchor.failure)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // The indicator leaving and the answer arriving are one motion,
                // so they share a single animation driven by the same value.
                .animation(.standard(reduceMotion: reduceMotion), value: chat.isSending)
            }
            .onChange(of: chat.messages.count) { _ in scrollToEnd(proxy) }
            .onChange(of: chat.isSending) { _ in scrollToEnd(proxy) }
            // A failure arrives without a message to announce it, and one the
            // user cannot see is one they cannot act on.
            .onChange(of: chat.failure) { _ in scrollToEnd(proxy) }
            // A growing answer pushes itself off-screen otherwise.
            // Keyed on length, not the string: SwiftUI would otherwise compare
            // the whole growing answer on every flush.
            .onChange(of: chat.messages.last?.content.count) { _ in scrollToEnd(proxy) }
        }
    }

    /// Centred in whatever height is left rather than pinned under the title.
    ///
    /// Its own branch, outside the transcript's scroll view: the composer is
    /// anchored to the bottom, so a top-aligned home left a screen-height gap
    /// between the two things the user is meant to use. The layout reader is
    /// scoped to this branch and stops existing the moment a message lands —
    /// the warning in `.agents/rules/swiftui.md` is about readers wrapping the
    /// streaming transcript, which this one never does. It still scrolls, so a
    /// short window doesn't clip the openers.
    private var chatHome: some View {
        GeometryReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                emptyState
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    /// The home surface: this is what opening Nod shows, so it greets the user
    /// and points at their own sessions rather than describing the feature.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ChatHomeSuggestions.greeting(for: profileStore.profile?.displayName))
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            // What the question will actually reach. Without it an empty
            // composer reads as a chatbot rather than as the user's own memory.
            Text(ChatHomeSuggestions.homeSubtitle(projects: scopeLabels.map(\.name)))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 14)

            // The counts used to sit here too. Today owns them now — and owns
            // them as a briefing rather than as two numbers — so this screen is
            // the composer again instead of a second door to the same list.
            MemoryBriefCard()
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChatHomeSuggestions.build(
                    meetings: meetingStore.meetings,
                    projects: scopeLabels.map(\.name),
                    firstRunPreview: ChatHomeSuggestions.isPreviewingFirstRun
                )) { opener in
                    suggestion(opener)
                }
            }

            ConnectToolsRow()
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 28)
    }

    /// Tapping an opener asks it, rather than typing it into the composer for
    /// the user to press send on. The chip already *is* the question — a
    /// pre-filled field asks them to confirm a choice they just made.
    ///
    /// The composer is filled too, and then cleared by `send()`, so the question
    /// travels the same path a typed one does and lands in the transcript the
    /// same way.
    private func suggestion(_ opener: ChatHomeSuggestions.Opener) -> some View {
        ChatSuggestionChip(text: opener.label, isFeatured: opener.isFeatured) {
            // A door rather than a question — the sample's opener carries the
            // session it is about, and the same notification the notch's recap
            // card posts is what opens it, so there is one way in.
            if let id = opener.opens {
                NotificationCenter.default.post(
                    name: .nodOpenMeetingDetail,
                    object: nil,
                    userInfo: [Notification.nodMeetingIDKey: id]
                )
                return
            }
            guard !chat.isSending else { return }
            draft = opener.question
            send()
        }
    }

    @ViewBuilder
    private func bubble(_ message: KnowledgeChatStore.Message) -> some View {
        if message.role == .user {
            ChatUserTurn(text: message.content, marks: marks(in: message)) {
                notes(for: message.id)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                AssistantTextBubble(
                    content: message.content,
                    isStreaming: chat.isStreaming && message.id == chat.messages.last?.id,
                    onRegenerate: regenerateAction(for: message)
                )
                .padding(.trailing, 40)
                notes(for: message.id)
                // What the turn did, collapsed. Below the answer rather than
                // above it: the answer is what was asked for, the record of how
                // it was reached is there to be checked, not read.
                ChatTurnTrace(steps: message.steps)
                if message.steps.ranOutOfCredits {
                    ChatCreditsNotice()
                }
                // Sessions and apps are both just "where this came from", so
                // they read as one row of chips rather than two lists in two
                // shapes. A session opens; an app is a label — the chip says
                // which by whether it responds to the pointer.
                ChatSourcesRow(sources: message.sources) { source, rank in
                    chat.noteOpenedSource(meetingID: source.id, rank: rank, in: message.id)
                    analytics.record(.answerSourceOpened, properties: .init(surface: .ask))
                    onOpenMeeting(source.id)
                }
            }
        }
    }

    private func regenerateAction(for message: KnowledgeChatStore.Message) -> (() -> Void)? {
        ChatTranscriptSupport.regenerateAction(
            isNewest: message.id == chat.messages.last?.id,
            isBusy: chat.isSending || chat.isStreaming
        ) {
            Task { await chat.regenerateLast() }
        }
    }

    private func notes(for id: KnowledgeChatStore.Message.ID) -> some View {
        ChatTurnNotes(
            wasStopped: chat.stoppedMessageIDs.contains(id),
            isUnsaved: chat.unsavedMessageIDs.contains(id),
            storeNoun: "this thread"
        ) {
            Task { await chat.retrySaving(id) }
        }
    }

    /// A sent message's pills, rebuilt at render time from what the app knows
    /// now rather than stored on the message: only session mentions are
    /// persisted, and a project or a tool named in the sentence would otherwise
    /// lose its mark the moment the question was sent.
    ///
    /// The `@` test comes first because it is the cheap one: most questions
    /// name nothing, and this runs for every visible turn on every publish of
    /// the store — which, while an answer streams, is twenty times a second.
    private func marks(in message: KnowledgeChatStore.Message) -> [MentionMark] {
        let candidates = labelStore.labels.map(MentionMark.init(project:))
            + IntegrationProvider.allCases.map(MentionMark.init(tool:))
            + message.mentions.map { MentionMark(session: $0, opens: true) }
        return MentionMark.named(in: message.content, from: candidates)
    }

    private var typingIndicator: some View {
        ThinkingIndicator(
            script: chat.thinkingScript,
            icon: chat.callingProvider?.iconName
        )
    }

    /// The composer carries the product: asking is the main way into everything
    /// Nod remembers, so it gets a surface of its own rather than sitting as a
    /// line of controls at the bottom of the window. The scope lives inside that
    /// surface because "what this reaches" is part of the question, not a
    /// setting beside it.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChatComposer(
                prompt: composerPrompt,
                text: $draft,
                isFocused: $inputFocused,
                canSend: canSend,
                isGenerating: chat.isSending,
                onStop: chat.cancel,
                sources: ChatMentionSources(
                    projects: labelStore.labels,
                    sessions: meetingStore.meetings,
                    tools: true
                ),
                mentions: mentionNames,
                onPick: record,
                onSend: { send() }
            )
            // Scope lives in the sentence as an `@project` token now — the pill
            // that used to sit here said the same thing in a second place, and
            // the two disagreed the moment either one changed.
            ConnectedToolsRow()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                        .stroke(inputFocused ? Theme.Palette.violet.opacity(0.5) : Theme.Palette.border, lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Every name that should read as a token in the field: the projects in
    /// scope, the tools named, and the sessions mentioned.
    private var mentionNames: [MentionMark] {
        scopeLabels.map(MentionMark.init(project:))
            + mentionedTools.map(MentionMark.init(tool:))
            + mentions.map { MentionMark(session: $0) }
    }

    private var composerPrompt: String {
        // The wait is the composer's business too: a field that says nothing
        // while an answer runs looks disabled, and one that says what pressing
        // Return will do turns the wait into somewhere to keep working.
        if queued != nil { return "Queued — sends when this answer finishes" }
        if chat.isSending { return "Ask something else while you wait…" }
        // Not the headline's words again — it sits four lines above, and a
        // placeholder that repeats it teaches nothing twice.
        guard !chat.scopeLabelIDs.isEmpty else { return "Ask anything  (/ for projects, @ for sessions and tools)" }
        return ChatHomeSuggestions.scopeHeadline(projects: scopeLabels.map(\.name), titleLimit: 48)
    }

    /// The composer writes the token; this is what the token means to this
    /// thread. A project narrows retrieval as well as reading as a word, so
    /// picking one sets the scope the pill used to own — the token and the
    /// filter stay the same act instead of two, and `syncScope` keeps them
    /// that way when the words are edited by hand.
    private func record(_ pick: ChatMentionPick) {
        switch pick {
        case let .session(meeting):
            let title = meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
            guard !mentions.contains(where: { $0.id == meeting.id }) else { return }
            mentions.append(SessionRef(id: meeting.id, title: title))
        case .connectTool:
            settingsFocus.open(.integrations)
        case .project, .tool:
            break
        }
    }

    /// One owner for the scope: whichever projects are named in the draft.
    /// Deleting the token now unscopes the question, which is what deleting the
    /// words it is made of should do.
    private func syncScope() {
        let named = MentionMark.named(in: draft, from: labelStore.labels, mark: MentionMark.init(project:))
        let next = Set(named.map(\.id))
        guard chat.scopeLabelIDs != next else { return }
        chat.scopeLabelIDs = next
    }

    private func adoptPendingDraft() {
        guard let pending = chat.pendingDraft else { return }
        draft = pending
        mentions = chat.pendingMentions
        chat.pendingDraft = nil
        chat.pendingMentions = []
        inputFocused = true
    }

    /// Derived rather than tracked: a stored list outlived the draft it
    /// described, so a tool named in one question came back as a pill in the
    /// next.
    private var mentionedTools: [IntegrationProvider] {
        MentionMark.namedTools(in: draft)
    }

    /// The send button is swapped for Stop while a turn runs, so this only has
    /// to answer "is there anything to send" — a question written mid-answer is
    /// queued rather than refused.
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The view's only job at send time: work out which mentions are still
    /// live in the text (deleting the inline "@Title" drops the mention) and
    /// hand the question to the store — or hold it, if one is still running.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let active = MentionMark.named(in: text, from: mentions) { MentionMark(session: $0) }
        let scope = scopeLabels
        draft = ""
        mentions = []
        let question = QueuedQuestion(text: text, pinned: active, scope: scope)
        // One deep. A second question written while one is queued replaces it:
        // a backlog nobody can see or edit is worse than losing the older of
        // two things typed in the same ten seconds.
        guard !chat.isSending else {
            queued = question
            return
        }
        ask(question)
    }

    private func ask(_ question: QueuedQuestion) {
        let baseline = chat.messages.count
        let aim: ProductAnalytics.Detail = if !question.pinned.isEmpty {
            .pinned
        } else if !question.scope.isEmpty {
            .project
        } else if chat.threadID != nil {
            .followUp
        } else {
            .open
        }
        analytics.record(.questionAsked, properties: .init(entryPoint: .ask, surface: .ask, detail: aim))
        Task {
            await chat.ask(question.text, pinned: question.pinned, scope: question.scope)
            if let answer = chat.answer(after: baseline) {
                analytics.record(
                    .aiActionCompleted,
                    properties: .init(
                        entryPoint: .ask,
                        surface: .ask,
                        contentType: .answer,
                        aiFeature: .knowledgeAsk,
                        // Answered from nothing is its own number: a reply
                        // with no session behind it is the retrieval failing,
                        // however fluent the words.
                        outcome: answer.sources.isEmpty ? .empty : .success
                    )
                )
            }
            if let next = queued {
                queued = nil
                ask(next)
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        proxy.scrollToEnd(scrollTarget, animated: !chat.isStreaming)
    }

    private var scrollTarget: AnyHashable? {
        if chat.pendingApproval != nil { return AnyHashable(ChatTranscriptSupport.Anchor.approval) }
        if chat.failure != nil { return AnyHashable(ChatTranscriptSupport.Anchor.failure) }
        if chat.isSending { return AnyHashable(ChatTranscriptSupport.Anchor.typing) }
        return chat.messages.last.map { AnyHashable($0.id) }
    }
}
