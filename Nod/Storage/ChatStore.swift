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

    private let supabase: SupabaseClient
    private let llm: OpenRouterClient
    private static let tableName = "chat_messages"
    private var openMeetingID: UUID?

    init(supabase: SupabaseClient, llm: OpenRouterClient) {
        self.supabase = supabase
        self.llm = llm
    }

    /// Loads the saved conversation for a session. Re-opening the same
    /// meeting keeps the cached messages (no refetch).
    func open(meetingID: UUID) async {
        if openMeetingID == meetingID, case .loaded = loadState { return }
        openMeetingID = meetingID
        messages = []
        sendState = .idle
        loadState = .loading
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

    /// Sends a user message: optimistically appends + persists it, calls the
    /// model with the full history, then appends + persists the reply. On LLM
    /// failure the user turn stays (it's saved) and `sendState` carries the
    /// error so the view can offer a retry.
    func send(text: String, systemPrompt: String, meetingID: UUID, userID: UUID) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sendState != .sending else { return }

        let userMessage = ChatMessage.new(meetingID: meetingID, userID: userID, role: .user, content: trimmed)
        messages.append(userMessage)
        sendState = .sending
        await persist(userMessage)
        await requestReply(systemPrompt: systemPrompt, meetingID: meetingID, userID: userID)
    }

    /// Re-runs the model for the last (already-saved) user turn after a
    /// failure. The turn is not re-appended or re-persisted — doing so would
    /// duplicate it in the conversation and the `chat_messages` table.
    func retryLast(systemPrompt: String, meetingID: UUID, userID: UUID) async {
        guard sendState != .sending, messages.last?.role == .user else { return }
        sendState = .sending
        await requestReply(systemPrompt: systemPrompt, meetingID: meetingID, userID: userID)
    }

    private func requestReply(systemPrompt: String, meetingID: UUID, userID: UUID) async {
        let history = messages.map {
            OpenRouterClient.ChatTurn(role: $0.role == .user ? .user : .assistant, content: $0.content)
        }
        do {
            // Low temperature: grounded answers about a real recording should
            // stay faithful, not creative.
            let reply = try await llm.chat(system: systemPrompt, history: history, temperature: 0.2)
            guard openMeetingID == meetingID else { return }
            let assistantMessage = ChatMessage.new(meetingID: meetingID, userID: userID, role: .assistant, content: reply)
            messages.append(assistantMessage)
            sendState = .idle
            await persist(assistantMessage)
        } catch {
            Log.ui.error("ChatStore.send LLM failed: \(error.localizedDescription)")
            guard openMeetingID == meetingID else { return }
            sendState = .failed(error.localizedDescription)
        }
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
        do {
            try await supabase.from(Self.tableName).insert(message).execute()
        } catch {
            Log.ui.error("ChatStore.persist failed (non-fatal): \(error.localizedDescription)")
        }
    }
}
