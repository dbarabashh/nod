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
    /// Opens what needs the user — the memory brief under the openers is a
    /// button, and this is where it goes.
    let onOpenActions: () -> Void

    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @EnvironmentObject private var entitlements: EntitlementService
    /// The thread itself — shared with any other surface onto the same
    /// conversation, so a question asked in the launcher can be continued here.
    @EnvironmentObject private var chat: KnowledgeChatStore
    @EnvironmentObject private var analytics: ProductAnalytics

    private typealias SessionRef = KnowledgeChatStore.SessionRef

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft: String = ""
    @State private var inputFocused = false

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
        .onChange(of: chat.pendingDraft) { pending in
            guard let pending else { return }
            draft = pending
            chat.pendingDraft = nil
            inputFocused = true
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
            Text("Ask across all your meetings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("Search and ask questions across everything you've recorded — your personal knowledge base. Available on Pro.")
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
                            onDeny: chat.denyPendingTools
                        )
                        .id(Self.approvalAnchor)
                    }
                    if chat.isSending, chat.pendingApproval == nil {
                        typingIndicator.id(Self.typingAnchor)
                    }
                    if let errorText = chat.errorText {
                        Text(errorText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(ChatHomeSuggestions.scopeHeadline(projects: scopeLabels.map(\.name)))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.bottom, 14)

            // What is waiting before what you could ask about it: the counts are
            // the reason to open Nod, and underneath the openers they were the
            // last thing on a screen that is mostly empty below them.
            TodayFocus(onOpenActions: onOpenActions, onOpenMeeting: onOpenMeeting)
                .padding(.bottom, 10)
            MemoryBriefCard()
                .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(ChatHomeSuggestions.build(meetings: meetingStore.meetings, projects: scopeLabels.map(\.name))) { opener in
                    suggestion(opener)
                }
            }
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
        ChatSuggestionChip(text: opener.label) {
            guard !chat.isSending else { return }
            draft = opener.question
            send()
        }
    }

    @ViewBuilder
    private func bubble(_ message: KnowledgeChatStore.Message) -> some View {
        if message.role == .user {
            UserTextBubble(text: message.content, marks: marks(in: message))
                .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                AssistantTextBubble(
                    content: message.content,
                    isStreaming: chat.isStreaming && message.id == chat.messages.last?.id
                )
                .padding(.trailing, 40)
                // What the turn did, collapsed. Below the answer rather than
                // above it: the answer is what was asked for, the record of how
                // it was reached is there to be checked, not read.
                ChatTurnTrace(steps: message.steps)
                // Sessions and apps are both just "where this came from", so
                // they read as one row of chips rather than two lists in two
                // shapes. A session opens; an app is a label — the chip says
                // which by whether it responds to the pointer.
                if !message.sources.isEmpty {
                    sourcesRow(message.sources, in: message.id)
                }
            }
        }
    }

    /// Everything the answer drew on, in one row: sessions first — they're the
    /// spine of the answer and they open — then the apps it read off the screen.
    private func sourcesRow(_ sources: [SessionRef], in answerID: KnowledgeChatStore.Message.ID) -> some View {
        let ordered = sources.filter { !$0.isApp } + sources.filter(\.isApp)
        return VStack(alignment: .leading, spacing: 4) {
            Text("SOURCES")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { rank, source in
                        if source.isApp {
                            sourceChip(source)
                        } else {
                            Button {
                                chat.noteOpenedSource(meetingID: source.id, rank: rank, in: answerID)
                                onOpenMeeting(source.id)
                            } label: {
                                sourceChip(source)
                            }
                            .buttonStyle(.plain)
                            .help("Open this session")
                        }
                    }
                }
            }
        }
        .padding(.leading, 2)
    }

    /// One chip. The icon carries the kind: an app's own icon for something read
    /// off the screen, a document glyph for a recorded session.
    private func sourceChip(_ source: SessionRef) -> some View {
        HStack(spacing: 5) {
            if let bundleID = source.bundleID,
               let icon = AppDirectory.icon(for: AppDirectory.identity(forBundleID: bundleID)) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 12, height: 12)
            } else {
                Image(source.isApp ? "nc-window-pointer" : "nc-file")
                    .icon(8.5)
            }
            Text(source.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.Palette.ink.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(Capsule().stroke(Theme.Palette.border, lineWidth: 0.5))
        )
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

    /// Derived rather than tracked: a stored list outlived the draft it
    /// described, so a tool named in one question came back as a pill in the
    /// next. `allCases` is three long, which is body-safe.
    private var mentionedTools: [IntegrationProvider] {
        MentionMark.named(in: draft, from: IntegrationProvider.allCases, mark: MentionMark.init(tool:))
    }

    private var canSend: Bool {
        !chat.isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send

    /// The view's only job at send time: work out which mentions are still
    /// live in the text (deleting the inline "@Title" drops the mention) and
    /// hand the question to the store.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let active = MentionMark.named(in: text, from: mentions) { MentionMark(session: $0) }
        draft = ""
        mentions = []
        let scope = scopeLabels
        let baseline = chat.messages.count
        Task {
            await chat.ask(text, pinned: active, scope: scope)
            if chat.answer(after: baseline) != nil {
                analytics.record(
                    .aiActionCompleted,
                    properties: .init(
                        entryPoint: .ask,
                        surface: .ask,
                        contentType: .answer,
                        aiFeature: .knowledgeAsk,
                        outcome: .success
                    )
                )
            }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = if chat.pendingApproval != nil {
            AnyHashable(Self.approvalAnchor)
        } else if chat.isSending {
            AnyHashable(Self.typingAnchor)
        } else {
            chat.messages.last.map { AnyHashable($0.id) }
        }
        guard let target else { return }
        // Mid-stream each flush would restart a 150ms scroll before the last
        // finished, which is what makes streaming scroll feel rubbery.
        guard !chat.isStreaming else {
            proxy.scrollTo(target, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    private static let typingAnchor = "nod.knowledge.typing"
    private static let approvalAnchor = "nod.knowledge.approval"
}
