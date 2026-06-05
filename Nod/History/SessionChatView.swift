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

    /// Above this transcript size we retrieve the parts relevant to the
    /// question instead of stuffing the whole thing — keeps long meetings
    /// focused and within context.
    private static let longTranscriptChars = 8000

    @State private var draft: String = ""
    /// nil until the transcript load resolves — the composer stays disabled
    /// until then so the first message is always fully grounded.
    @State private var transcriptText: String? = nil
    @FocusState private var inputFocused: Bool

    /// Freshest copy so chat grounds on the latest edited recap/title.
    private var current: Meeting {
        meetingStore.meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    private var isSending: Bool {
        chatStore.sendState == .sending
    }

    private var isReady: Bool {
        transcriptText != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            messages
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await chatStore.open(meetingID: meeting.id)
            await loadTranscript()
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
                    if isSending {
                        typingIndicator.id(Self.typingAnchor)
                    }
                    if case let .failed(detail) = chatStore.sendState {
                        errorRow(detail)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: chatStore.messages.count) { _ in scrollToEnd(proxy) }
            .onChange(of: chatStore.sendState) { _ in scrollToEnd(proxy) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask anything about this \(kindNoun)")
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

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Text(isUser ? AttributedString(message.content) : renderRecapMarkdown(message.content))
                .font(.system(size: 13.5))
                .foregroundStyle(isUser ? Color.white : Theme.Palette.ink.opacity(0.95))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .chatBubbleBackground(isUser: isUser)
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var typingIndicator: some View {
        ChatTypingIndicator(label: "Thinking…")
            .padding(.vertical, 4)
    }

    private func errorRow(_ detail: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button("Retry") { send(retryLast: true) }
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(isReady ? "Message" : "Loading session…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1 ... 5)
                .focused($inputFocused)
                .disabled(!isReady)
                .chatSubmit(text: $draft) { send() }
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

            Button(action: { send() }) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(canSend ? Theme.Palette.violet : Theme.Palette.muted.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var canSend: Bool {
        isReady && !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    private func send(retryLast: Bool = false) {
        let text: String
        if retryLast {
            // The last user turn is already saved; resend it to get a reply.
            guard let last = chatStore.messages.last(where: { $0.role == .user }) else { return }
            text = last.content
        } else {
            text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard canSend else { return }
        }
        if !retryLast { draft = "" }
        Task {
            let systemPrompt = await buildSystemPrompt(for: text)
            if retryLast {
                await chatStore.retryLast(
                    systemPrompt: systemPrompt,
                    meetingID: meeting.id,
                    userID: meeting.userID
                )
            } else {
                await chatStore.send(
                    text: text,
                    systemPrompt: systemPrompt,
                    meetingID: meeting.id,
                    userID: meeting.userID
                )
            }
        }
    }

    private func buildSystemPrompt(for query: String) async -> String {
        // Match the user's typed language; fall back to the meeting's language.
        let language = AppLanguage.detect(from: query) ?? AppLanguage(rawValue: current.language) ?? .english
        let full = transcriptText ?? ""
        let grounding: String
        if full.count > Self.longTranscriptChars {
            // Retrieve the relevant parts of a long meeting. Fall back to the
            // (truncated) full text if retrieval is empty — e.g. the session
            // isn't indexed yet.
            let chunks = await knowledgeStore.search(query: query, matchCount: 8, meetingID: meeting.id)
            grounding = chunks.isEmpty
                ? String(full.prefix(Self.longTranscriptChars))
                : chunks.map(\.content).joined(separator: "\n…\n")
        } else {
            grounding = full
        }
        return PromptLibrary.buildChatSystem(
            sessionKind: current.kind,
            title: current.title ?? "",
            summary: current.summary,
            transcript: grounding,
            language: language,
            personalContext: profileStore.promptContext
        )
    }

    private func loadTranscript() async {
        do {
            let records = try await meetingStore.fetchTranscript(meetingID: meeting.id)
            transcriptText = records.map { record in
                let label = TranscriptSource(rawValue: record.source)?.label ?? record.source
                return "[\(label)] \(record.text)"
            }.joined(separator: "\n")
        } catch {
            Log.ui.error("SessionChatView transcript load failed: \(error.localizedDescription)")
            // Empty (not nil) so chat still works off the recap alone.
            transcriptText = ""
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: AnyHashable? = isSending
            ? AnyHashable(Self.typingAnchor)
            : chatStore.messages.last.map { AnyHashable($0.id) }
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private var kindNoun: String {
        switch current.kind {
        case .meeting: "meeting"
        case .voiceNote: "voice note"
        case .media: "recording"
        }
    }

    private static let typingAnchor = "nod.chat.typing"
}
