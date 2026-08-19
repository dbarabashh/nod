import Foundation
import Supabase

/// Saved cross-session conversations. `ChatStore` can't hold these — its rows
/// are keyed to one `meeting_id` — so "Ask Nod" threads live in their own pair
/// of tables (`20260719160000_add_knowledge_threads.sql`) and are listed,
/// reopened, and deleted from here.
@MainActor
final class KnowledgeThreadStore: ObservableObject {
    struct Thread: Codable, Identifiable, Equatable {
        let id: UUID
        let userID: UUID
        var title: String
        let createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id"
            case title
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }

        /// Insert payload — `created_at`/`updated_at` are omitted so Postgres'
        /// `default now()` applies, matching `Meeting`/`ActionItem`. Sending the
        /// device's clock instead lets a machine that's a day fast pin its
        /// threads to the top of a list ordered by `updated_at` forever.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(userID, forKey: .userID)
            try container.encode(title, forKey: .title)
        }

        /// What the list shows before the first question has been asked.
        var displayTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "New chat" : trimmed
        }
    }

    /// A persisted turn. `sources`/`evidence` ride along so a reopened thread
    /// still shows what its answers were built on.
    struct StoredMessage: Codable {
        let id: UUID
        let threadID: UUID
        let userID: UUID
        let role: String
        let content: String
        let sources: [KnowledgeChatStore.SessionRef]
        let evidence: [StoredExcerpt]
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case threadID = "thread_id"
            case userID = "user_id"
            case role
            case content
            case sources
            case evidence
            case createdAt = "created_at"
        }

        /// `created_at` is server-assigned, so it's left out of inserts.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(threadID, forKey: .threadID)
            try container.encode(userID, forKey: .userID)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
            try container.encode(sources, forKey: .sources)
            try container.encode(evidence, forKey: .evidence)
        }
    }

    struct StoredExcerpt: Codable, Equatable {
        let meetingID: UUID
        let title: String
        let date: String
        let text: String

        enum CodingKeys: String, CodingKey {
            case meetingID = "meeting_id"
            case title
            case date
            case text
        }
    }

    @Published private(set) var threads: [Thread] = []
    @Published private(set) var isLoading = false

    private static let threadsTable = "knowledge_threads"
    private static let messagesTable = "knowledge_messages"

    private let supabase: SupabaseClient

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    private var hasLoaded = false

    /// The list is maintained locally after the first load (create inserts,
    /// append reorders, delete removes), and this view is rebuilt on every
    /// section switch — so refetching on each appearance is 200 rows for
    /// nothing.
    func refreshIfNeeded() async {
        guard !hasLoaded else { return }
        await refresh()
    }

    /// Most recently used first — a thread you replied in ten minutes ago is
    /// more findable than one you started last month.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            threads = try await supabase
                .from(Self.threadsTable)
                .select()
                .order("updated_at", ascending: false)
                .limit(200)
                .execute()
                .value
            hasLoaded = true
        } catch {
            Log.ui.error("KnowledgeThreadStore.refresh failed: \(error.localizedDescription)")
        }
    }

    /// The owner comes from the live session rather than an injected auth
    /// service — `AuthService` lives in `Features/`, and a `Core` store must
    /// not reach into a feature to learn who is signed in.
    private func currentUserID() async -> UUID? {
        try? await supabase.auth.session.user.id
    }

    func create(title: String) async -> Thread? {
        guard let userID = await currentUserID() else { return nil }
        let thread = Thread(
            id: UUID(),
            userID: userID,
            title: Self.trimmedTitle(title),
            createdAt: Date(),
            updatedAt: Date()
        )
        do {
            try await supabase.from(Self.threadsTable).insert(thread).execute()
            threads.insert(thread, at: 0)
            return thread
        } catch {
            Log.ui.error("KnowledgeThreadStore.create failed: \(error.localizedDescription)")
            return nil
        }
    }

    func messages(in threadID: UUID) async -> [StoredMessage] {
        do {
            return try await supabase
                .from(Self.messagesTable)
                .select()
                .eq("thread_id", value: threadID.uuidString)
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch {
            Log.ui.error("KnowledgeThreadStore.messages failed: \(error.localizedDescription)")
            return []
        }
    }

    /// The thread's `updated_at` is bumped by a trigger on insert, so appending
    /// a message is one request rather than an insert plus an update — and the
    /// timestamp comes from the database rather than the device's clock, which
    /// is the same reason `Thread.encode` omits it.
    @discardableResult
    func append(
        threadID: UUID,
        id: UUID,
        role: String,
        content: String,
        sources: [KnowledgeChatStore.SessionRef],
        evidence: [StoredExcerpt]
    ) async -> Bool {
        guard let userID = await currentUserID() else { return false }
        let message = StoredMessage(
            id: id,
            threadID: threadID,
            userID: userID,
            role: role,
            content: content,
            sources: sources,
            evidence: evidence,
            createdAt: nil
        )
        do {
            try await supabase.from(Self.messagesTable).insert(message).execute()
            moveToTop(threadID)
            return true
        } catch {
            Log.ui.error("KnowledgeThreadStore.append failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Drops specific turns from a saved thread. Used when an answer is
    /// regenerated: the replaced turns have to leave the thread too, or
    /// reopening it shows the same question answered twice.
    func deleteMessages(_ ids: [UUID], in threadID: UUID) async {
        guard !ids.isEmpty else { return }
        do {
            try await supabase
                .from(Self.messagesTable)
                .delete()
                .eq("thread_id", value: threadID.uuidString)
                .in("id", values: ids.map(\.uuidString))
                .execute()
        } catch {
            Log.ui.error("KnowledgeThreadStore.deleteMessages failed: \(error.localizedDescription)")
        }
    }

    /// Names an untitled thread from its first question, so the list is
    /// readable without a second model call.
    func setTitleIfEmpty(_ title: String, threadID: UUID) async {
        guard let index = threads.firstIndex(where: { $0.id == threadID }),
              threads[index].title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let trimmed = Self.trimmedTitle(title)
        threads[index].title = trimmed
        do {
            try await supabase
                .from(Self.threadsTable)
                .update(["title": trimmed])
                .eq("id", value: threadID.uuidString)
                .execute()
        } catch {
            Log.ui.error("KnowledgeThreadStore.setTitle failed: \(error.localizedDescription)")
        }
    }

    /// Gone means gone — messages cascade. Optimistic, because a thread the
    /// user deleted should leave the list immediately.
    func delete(_ threadID: UUID) async {
        let previous = threads
        threads.removeAll { $0.id == threadID }
        do {
            try await supabase
                .from(Self.threadsTable)
                .delete()
                .eq("id", value: threadID.uuidString)
                .execute()
        } catch {
            threads = previous
            Log.ui.error("KnowledgeThreadStore.delete failed: \(error.localizedDescription)")
        }
    }

    /// The list's optimistic half of the trigger: the row the user just added
    /// to jumps to the top without waiting for a refetch.
    private func moveToTop(_ threadID: UUID) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].updatedAt = Date()
        let thread = threads.remove(at: index)
        threads.insert(thread, at: 0)
    }

    /// Long enough to tell two questions apart in a list, short enough not to
    /// wrap in the sidebar.
    private static func trimmedTitle(_ title: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 60 else { return clean }
        return String(clean.prefix(60)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
