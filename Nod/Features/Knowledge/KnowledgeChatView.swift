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
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var entitlements: EntitlementService
    /// The thread itself — shared with any other surface onto the same
    /// conversation, so a question asked in the launcher can be continued here.
    @EnvironmentObject private var chat: KnowledgeChatStore

    private typealias SessionRef = KnowledgeChatStore.SessionRef

    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    /// Sessions the user pinned with @ — when non-empty the question is scoped
    /// to exactly these (the router is skipped; the user said what they want).
    @State private var mentions: [SessionRef] = []
    @State private var showMentionPicker = false
    @State private var mentionSearch = ""
    @FocusState private var mentionSearchFocused: Bool

    /// When set, questions are answered using ONLY sessions carrying this
    /// label. Persists across turns until the user clears it. An explicit
    /// @mention overrides it for that message.
    @State private var scopeLabel: SessionLabel?

    var body: some View {
        Group {
            // Cross-session "Ask Nod" is a Pro feature (`ask_across_meetings`).
            // The server enforces it too; this gate is the UX side — show an
            // upsell instead of a composer that would only 403.
            if canAskAcross {
                VStack(spacing: 0) {
                    messageList
                    composer
                }
            } else {
                upsell
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await meetingStore.refresh() }
        .onChange(of: labelStore.labels) { labels in
            if let scope = scopeLabel, !labels.contains(where: { $0.id == scope.id }) {
                scopeLabel = nil
            }
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
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .regular))
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
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    // Once tokens are arriving the answer bubble IS the
                    // progress indicator — two of them reads as a stall.
                    if chat.isSending, !chat.isStreaming { typingIndicator.id(Self.typingAnchor) }
                    if let errorText = chat.errorText {
                        Text(errorText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: chat.messages.count) { _ in scrollToEnd(proxy) }
            .onChange(of: chat.isSending) { _ in scrollToEnd(proxy) }
            // A growing answer pushes itself off-screen otherwise.
            // Keyed on length, not the string: SwiftUI would otherwise compare
            // the whole growing answer on every flush.
            .onChange(of: chat.messages.last?.content.count) { _ in scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask anything across your recordings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            VStack(alignment: .leading, spacing: 5) {
                suggestion("What have I been thinking about lately?")
                suggestion("What did I say I'd follow up on?")
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
    private func bubble(_ message: KnowledgeChatStore.Message) -> some View {
        if message.role == .user {
            UserTextBubble(text: userAttributed(message))
                .padding(.leading, 40)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                AssistantTextBubble(content: message.content)
                    .padding(.trailing, 40)
                if !message.evidence.isEmpty {
                    // The passages an answer stands on, not just which sessions
                    // it touched. They're persisted with the message, so a
                    // reopened thread shows the same evidence it was read with.
                    evidenceRows(message.evidence, in: message.id)
                } else if !message.sources.isEmpty {
                    sourcesRow(message.sources, in: message.id)
                }
            }
        }
    }

    /// One row per session, with the passage the answer used — the same shape
    /// the launcher shows, so an answer reads the same wherever it's opened.
    private func evidenceRows(
        _ items: [KnowledgeChatStore.Excerpt],
        in answerID: KnowledgeChatStore.Message.ID
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FROM YOUR SESSIONS")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { rank, item in
                Button {
                    chat.noteOpenedSource(meetingID: item.meetingID, rank: rank, in: answerID)
                    onOpenMeeting(item.meetingID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                                .lineLimit(1)
                            Text(item.date)
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.muted)
                            Spacer(minLength: 0)
                        }
                        Text(item.text)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.graphite)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .fill(Theme.Palette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                    .stroke(Theme.Palette.border, lineWidth: 0.5)
                            )
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open this session")
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 40)
    }

    private func sourcesRow(_ sources: [SessionRef], in answerID: KnowledgeChatStore.Message.ID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCES")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.element.id) { rank, source in
                        Button {
                            chat.noteOpenedSource(meetingID: source.id, rank: rank, in: answerID)
                            onOpenMeeting(source.id)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 8.5, weight: .semibold))
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
                        .buttonStyle(.plain)
                        .help("Open this session")
                    }
                }
            }
        }
        .padding(.leading, 2)
    }

    /// User message with its @mentions rendered as underlined, tappable links
    /// (white on the violet bubble) that open the session.
    private func userAttributed(_ message: KnowledgeChatStore.Message) -> AttributedString {
        var result = AttributedString(message.content)
        for mention in message.mentions {
            let token = "@\(mention.title)"
            if let range = result.range(of: token) {
                result[range].font = .system(size: 13.5, weight: .semibold)
                result[range].underlineStyle = .single
                if let url = URL(string: "nod-meeting://m/\(mention.id.uuidString)") {
                    result[range].link = url
                }
            }
        }
        return result
    }

    private var typingIndicator: some View {
        ThinkingIndicator(phase: chat.thinkingPhase)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            composerInput
            if !labelStore.labels.isEmpty { scopeMenu }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var composerInput: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ChatComposerField(
                prompt: composerPrompt,
                text: $draft,
                focus: $inputFocused,
                onSend: { send() }
            )
            // A word-boundary "@" opens the session picker (and is consumed
            // — the chosen mention is re-inserted as "@Title" inline). A
            // mid-word "@" (e.g. an email or handle) stays literal.
            .onChange(of: draft) { value in
                guard value.hasSuffix("@") else { return }
                let beforeAt = value.dropLast().last
                let atWordBoundary = beforeAt == nil || beforeAt == " " || beforeAt == "\n"
                guard atWordBoundary else { return }
                draft.removeLast()
                mentionSearch = ""
                showMentionPicker = true
            }
            // Floats above the field, auto-sized, so opening it never
            // reflows the composer; dismisses on outside-click or Escape.
            .popover(isPresented: $showMentionPicker, arrowEdge: .top) { mentionPicker }

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Theme.GlassButton.text : .white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(canSend ? AnyShapeStyle(Theme.GlassButton.fill) : AnyShapeStyle(Theme.Palette.muted.opacity(0.4)))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }

    private var composerPrompt: String {
        if let scopeLabel { return "Ask within \(scopeLabel.name)" }
        return "Ask across your sessions  (@ to mention a session)"
    }

    private var scopeMenu: some View {
        Menu {
            Button { scopeLabel = nil } label: {
                menuItemLabel("All sessions", isSelected: scopeLabel == nil)
            }
            Divider()
            ForEach(labelStore.labels) { label in
                Button { scopeLabel = label } label: {
                    menuItemLabel(label.name, isSelected: scopeLabel?.id == label.id)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9, weight: .semibold))
                Text(scopeLabel?.name ?? "All sessions")
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(scopeLabel == nil ? Theme.Palette.muted : Theme.Palette.violet)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Scope questions to a folder")
    }

    @ViewBuilder
    private func menuItemLabel(_ text: String, isSelected: Bool) -> some View {
        if isSelected { SwiftUI.Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    private var mentionPicker: some View {
        VStack(spacing: 0) {
            TextField("Search sessions", text: $mentionSearch)
                .textFieldStyle(.roundedBorder)
                .focused($mentionSearchFocused)
                .padding(8)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredMeetings.isEmpty {
                        Text("No matching sessions")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Palette.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(filteredMeetings) { meeting in
                        mentionPickerRow(meeting)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 300)
        .onAppear { mentionSearchFocused = true }
    }

    private func mentionPickerRow(_ meeting: Meeting) -> some View {
        Button {
            insertMention(meeting)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: meeting.kind.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Text(Meeting.shortDateFormatter.string(from: meeting.startedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredMeetings: [Meeting] {
        meetingStore.meetings.filter { $0.matches(mentionSearch) }
    }

    /// Inserts the chosen session inline as "@Title" so the mention is part of
    /// the message the user is writing. Tracks the id→title mapping; which
    /// mentions are actually "active" is re-derived from the text at send time
    /// (so deleting the inline text drops the mention).
    private func insertMention(_ meeting: Meeting) {
        let title = meeting.displayTitle(dateFormatter: Meeting.shortDateFormatter)
        if !mentions.contains(where: { $0.id == meeting.id }) {
            mentions.append(SessionRef(id: meeting.id, title: title))
        }
        if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(title) "
        showMentionPicker = false
        inputFocused = true
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
        let active = mentions.filter { text.localizedCaseInsensitiveContains("@\($0.title)") }
        draft = ""
        mentions = []
        let scope = scopeLabel
        Task { await chat.ask(text, pinned: active, scope: scope) }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = chat.isSending
            ? AnyHashable(Self.typingAnchor)
            : chat.messages.last.map { AnyHashable($0.id) }
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
}
