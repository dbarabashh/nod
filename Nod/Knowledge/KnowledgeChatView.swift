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

    @EnvironmentObject private var llm: OpenRouterClient
    @EnvironmentObject private var knowledgeStore: KnowledgeStore
    @EnvironmentObject private var meetingStore: MeetingStore
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var language: LanguagePreference

    private struct QAMessage: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String
        var sources: [SessionRef] = []
        var mentions: [SessionRef] = []
        enum Role { case user, assistant }
    }

    /// A session reference — either a source an answer drew on or a session the
    /// user pinned via @-mention. Both are just an id + display title.
    private struct SessionRef: Identifiable, Equatable {
        let id: UUID
        let title: String
    }

    @State private var messages: [QAMessage] = []
    @State private var draft: String = ""
    @State private var isSending = false
    @State private var thinkingPhase = ""
    @State private var errorText: String?
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

    private static let sourceDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            messageList
            composer
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

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if messages.isEmpty { emptyState }
                    ForEach(messages) { message in
                        bubble(message).id(message.id)
                    }
                    if isSending { typingIndicator.id(Self.typingAnchor) }
                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: messages.count) { _ in scrollToEnd(proxy) }
            .onChange(of: isSending) { _ in scrollToEnd(proxy) }
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
    private func bubble(_ message: QAMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                UserTextBubble(text: userAttributed(message))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    AssistantTextBubble(content: message.content)
                    Spacer(minLength: 40)
                }
                if !message.sources.isEmpty {
                    sourcesRow(message.sources)
                }
            }
        }
    }

    private func sourcesRow(_ sources: [SessionRef]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SOURCES")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.Palette.muted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sources) { source in
                        Button { onOpenMeeting(source.id) } label: {
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
    private func userAttributed(_ message: QAMessage) -> AttributedString {
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
        ThinkingIndicator(phase: thinkingPhase)
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
        HStack(spacing: 8) {
            TextField(composerPrompt, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1 ... 5)
                .focused($inputFocused)
                .chatSubmit(text: $draft) { send() }
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
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )
                // Floats above the field, auto-sized, so opening it never
                // reflows the composer; dismisses on outside-click or Escape.
                .popover(isPresented: $showMentionPicker, arrowEdge: .top) { mentionPicker }

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? Theme.Palette.violet : Theme.Palette.muted.opacity(0.4)))
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
        .help("Scope questions to a label")
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
                    Text(meeting.displayTitle(dateFormatter: Self.sourceDateFormatter))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink)
                        .lineLimit(1)
                    Text(Self.sourceDateFormatter.string(from: meeting.startedAt))
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
        let query = mentionSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return meetingStore.meetings }
        return meetingStore.meetings.filter {
            ($0.title?.lowercased().contains(query) ?? false) || $0.summary.lowercased().contains(query)
        }
    }

    /// Inserts the chosen session inline as "@Title" so the mention is part of
    /// the message the user is writing. Tracks the id→title mapping; which
    /// mentions are actually "active" is re-derived from the text at send time
    /// (so deleting the inline text drops the mention).
    private func insertMention(_ meeting: Meeting) {
        let title = meeting.displayTitle(dateFormatter: Self.sourceDateFormatter)
        if !mentions.contains(where: { $0.id == meeting.id }) {
            mentions.append(SessionRef(id: meeting.id, title: title))
        }
        if !draft.isEmpty, !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(title) "
        showMentionPicker = false
        inputFocused = true
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Send

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // Mentions are per-message: only those still present inline count, and
        // they travel with this message then reset.
        let active = mentions.filter { text.localizedCaseInsensitiveContains("@\($0.title)") }
        let pinned = active.map(\.id)
        draft = ""
        mentions = []
        errorText = nil
        messages.append(QAMessage(role: .user, content: text, mentions: active))
        thinkingPhase = "Searching your sessions…"
        isSending = true
        let scope = scopeLabel
        Task {
            // Precedence: an explicit @mention is the most specific intent and
            // wins; otherwise an active label scope narrows to its sessions;
            // otherwise the router decides ("last meeting" / "the pricing one"
            // resolve to specific rows, broad questions stay corpus-wide).
            let route: Route
            if !pinned.isEmpty {
                route = .specific(pinned)
            } else if let scope {
                let ids = Array(labelStore.meetingIDs(withLabel: scope.id))
                guard !ids.isEmpty else {
                    messages.append(QAMessage(
                        role: .assistant,
                        content: "No sessions carry the “\(scope.name)” label yet. Add it to a session from its detail view, then ask again."
                    ))
                    isSending = false
                    return
                }
                route = .scoped(ids)
            } else {
                route = await routeQuery(text)
            }
            let (excerpts, sources) = await gather(for: route, query: text)
            // Answer in the language the user typed, not the app default —
            // the retrieved excerpts (often Ukrainian) otherwise drag the
            // reply away from an English question.
            let replyLanguage = AppLanguage.detect(from: text) ?? language.current
            let system = PromptLibrary.buildKnowledgeSystem(
                excerpts: excerpts,
                language: replyLanguage,
                personalContext: profileStore.promptContext
            )
            let history = messages.map {
                OpenRouterClient.ChatTurn(role: $0.role == .user ? .user : .assistant, content: $0.content)
            }
            do {
                // Low temperature — cross-session answers must stay grounded in
                // the retrieved excerpts, not improvise. The reply is kicked off
                // first so the "reading" beat below overlaps real work rather
                // than adding latency.
                async let pendingReply = llm.chat(system: system, history: history, temperature: 0.2)
                if !sources.isEmpty {
                    thinkingPhase = sources.count == 1
                        ? "Reading 1 session…"
                        : "Reading \(sources.count) sessions…"
                    try? await Task.sleep(nanoseconds: 700_000_000)
                }
                thinkingPhase = "Writing your answer…"
                let reply = try await pendingReply
                messages.append(QAMessage(role: .assistant, content: reply, sources: sources))
            } catch {
                Log.ui.error("KnowledgeChat send failed: \(error.localizedDescription)")
                errorText = error.localizedDescription
            }
            isSending = false
        }
    }

    private enum Route {
        case all
        case specific([UUID])
        case scoped([UUID])
    }

    private struct SessionRoute: Decodable {
        let scope: String
        let indices: [Int]?
    }

    /// Asks the model which session(s) the question targets. Falls back to a
    /// corpus-wide search on any failure or ambiguity.
    private func routeQuery(_ text: String) async -> Route {
        // Cap the routable list so the prompt stays small; broad questions that
        // reference an older session still resolve via the "all" path.
        let routable = Array(meetingStore.meetings.prefix(60))
        guard !routable.isEmpty else { return .all }
        let list = routable.enumerated().map { idx, meeting in
            "\(idx) | \(Self.sourceDateFormatter.string(from: meeting.startedAt)) | \(meeting.displayTitle(dateFormatter: Self.sourceDateFormatter)) | \(meeting.kind.rawValue)"
        }.joined(separator: "\n")

        let (system, user) = PromptLibrary.buildSessionRouter(sessionList: list, query: text)
        do {
            let route = try await llm.completeJSON(system: system, user: user, as: SessionRoute.self)
            guard route.scope == "specific" else { return .all }
            let ids = (route.indices ?? []).compactMap { routable.indices.contains($0) ? routable[$0].id : nil }
            return ids.isEmpty ? .all : .specific(ids)
        } catch {
            Log.ui.error("KnowledgeChat router failed (using all): \(error.localizedDescription)")
            return .all
        }
    }

    /// Builds the grounding excerpts + sources for the routed scope. Specific
    /// sessions are answered from their recap (+ relevant transcript parts if
    /// indexed) so sources show only what the question is actually about.
    private func gather(for route: Route, query: String) async -> (excerpts: [String], sources: [SessionRef]) {
        switch route {
        case .all, .scoped:
            // Corpus-style search (similarity + entity boost). A label scope is
            // the same path, constrained server-side to the label's sessions.
            let scopedIDs: [UUID]? = if case let .scoped(ids) = route { ids } else { nil }
            let chunks = await knowledgeStore.search(query: query, meetingIDs: scopedIDs)
            let byID = Dictionary(meetingStore.meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return (chunks.map { labeledExcerpt($0, in: byID) }, resolveSources(chunks, in: byID))
        case let .specific(ids):
            // Resolve each session's static metadata up front (main-actor
            // state), then run the per-session transcript searches concurrently
            // — they're independent, so a 5-session ask shouldn't pay five
            // serial round-trips.
            let resolved: [ResolvedSession] = ids.compactMap { id in
                guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else { return nil }
                return ResolvedSession(
                    id: id,
                    title: meeting.displayTitle(dateFormatter: Self.sourceDateFormatter),
                    date: Self.sourceDateFormatter.string(from: meeting.startedAt),
                    summary: meeting.summary
                )
            }
            let store = knowledgeStore
            let chunksByIndex = await withTaskGroup(of: (Int, [RetrievedChunk]).self) { group in
                for (index, session) in resolved.enumerated() {
                    group.addTask { await (index, store.search(query: query, meetingID: session.id)) }
                }
                var collected = [[RetrievedChunk]](repeating: [], count: resolved.count)
                for await (index, chunks) in group {
                    collected[index] = chunks
                }
                return collected
            }

            var excerpts: [String] = []
            var sources: [SessionRef] = []
            for (index, session) in resolved.enumerated() {
                var block = "[From: \(session.title) (\(session.date))]\nRecap:\n\(session.summary.isEmpty ? "(no recap)" : session.summary)"
                let chunks = chunksByIndex[index]
                if !chunks.isEmpty {
                    block += "\n\nRelevant excerpts:\n" + chunks.map(\.content).joined(separator: "\n…\n")
                }
                excerpts.append(block)
                sources.append(SessionRef(id: session.id, title: session.title))
            }
            return (excerpts, sources)
        }
    }

    /// Distinct sessions behind the retrieved chunks, in retrieval order, so
    /// the answer can show what it drew on.
    private func resolveSources(_ chunks: [RetrievedChunk], in byID: [UUID: Meeting]) -> [SessionRef] {
        var seen = Set<UUID>()
        var refs: [SessionRef] = []
        for chunk in chunks where seen.insert(chunk.meetingID).inserted {
            let title = byID[chunk.meetingID]?
                .displayTitle(dateFormatter: Self.sourceDateFormatter) ?? "A past session"
            refs.append(SessionRef(id: chunk.meetingID, title: title))
        }
        return refs
    }

    /// Prefix each excerpt with a human source label so the model can cite it.
    private func labeledExcerpt(_ chunk: RetrievedChunk, in byID: [UUID: Meeting]) -> String {
        let label: String
        if let meeting = byID[chunk.meetingID] {
            let title = meeting.displayTitle(dateFormatter: Self.sourceDateFormatter)
            label = "\(title) (\(Self.sourceDateFormatter.string(from: meeting.startedAt)))"
        } else {
            label = "a past session"
        }
        return "[From: \(label)]\n\(chunk.content)"
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = isSending
            ? AnyHashable(Self.typingAnchor)
            : messages.last.map { AnyHashable($0.id) }
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    private static let typingAnchor = "nod.knowledge.typing"
}

/// A pinned session's static metadata, resolved on the main actor before its
/// transcript search runs concurrently with the others.
private struct ResolvedSession {
    let id: UUID
    let title: String
    let date: String
    let summary: String
}
