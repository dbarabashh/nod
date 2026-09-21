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
        /// Set when the thread was written by a beat rather than typed. Decoded
        /// only — a thread claims a beat by being attached to one, never by
        /// saying so on insert.
        var beatID: UUID?

        enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id"
            case title
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case beatID = "beat_id"
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
    /// Bumped when every thread was deleted at once, so each chat holding one
    /// of them lets go: a thread id kept past this points at nothing, and the
    /// next answer's persist would fail on it.
    @Published private(set) var purges = 0
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
            // Beat threads are left out: they have their own list, and a
            // daily beat would otherwise push every real conversation off the
            // first screen within a week.
            threads = try await supabase
                .from(Self.threadsTable)
                .select()
                .is("beat_id", value: nil)
                .order("updated_at", ascending: false)
                .limit(200)
                .execute()
                .value
            hasLoaded = true
        } catch {
            Log.ui.error("KnowledgeThreadStore.refresh failed: \(error.localizedDescription)")
        }
    }

    /// Drops the previous account's conversations on sign-out.
    ///
    /// `hasLoaded` matters as much as the list: without it `refreshIfNeeded`
    /// answers "already loaded" for the next person who signs in, so they are
    /// shown the last account's chat titles and never a fetch of their own.
    /// That is how a sign-out, a sign-in as somebody else and a sign-in back
    /// left an account looking at an empty list until the app was relaunched.
    func clear() {
        threads = []
        hasLoaded = false
        isLoading = false
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
            updatedAt: Date(),
            beatID: nil
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

    /// Marks a finished thread as a beat's answer and names it after the beat.
    /// Done after the run rather than before, so a beat that fails leaves no
    /// half-written thread claiming to be its answer.
    /// Titles a thread an agent just wrote, so the Ask list shows the agent's
    /// name rather than the first words of its prompt. Unlike a beat's
    /// `attach`, the thread stays in the list — an after-meeting brief is
    /// meant to be seen there.
    func rename(threadID: UUID, title: String) async {
        do {
            try await supabase
                .from(Self.threadsTable)
                .update(["title": Self.trimmedTitle(title)])
                .eq("id", value: threadID.uuidString)
                .execute()
        } catch {
            Log.ui.error("thread rename failed: \(error.localizedDescription)")
        }
    }

    func attach(threadID: UUID, to beatID: UUID, title: String) async {
        struct Attachment: Encodable {
            let beat_id: String
            let title: String
        }
        do {
            try await supabase
                .from(Self.threadsTable)
                .update(Attachment(beat_id: beatID.uuidString, title: Self.trimmedTitle(title)))
                .eq("id", value: threadID.uuidString)
                .execute()
            // It was inserted into the visible list by `create`; a beat's
            // answer does not belong there.
            threads.removeAll { $0.id == threadID }
        } catch {
            Log.ui.error("KnowledgeThreadStore.attach failed: \(error.localizedDescription)")
        }
    }

    struct PastAnswer: Decodable {
        struct Origin: Decodable {
            let title: String
            let beatID: UUID?

            enum CodingKeys: String, CodingKey {
                case title
                case beatID = "beat_id"
            }
        }

        let content: String
        let createdAt: Date
        let sources: [KnowledgeChatStore.SessionRef]
        /// Read with the row: `threads` holds no beat threads, which are
        /// exactly the ones a report comes from.
        let thread: Origin

        enum CodingKeys: String, CodingKey {
            case content
            case createdAt = "created_at"
            case sources
            case thread = "knowledge_threads"
        }
    }

    /// What Nod already wrote — in another chat, or in an agent's report —
    /// that mentions any of `names`, newest first.
    ///
    /// Matched as text, on names only: an answer is found by who or what it is
    /// about, and a question's ordinary words are in every answer there is.
    func answers(
        mentioning names: [String],
        outside threadID: UUID?,
        limit: Int = 3,
        keeping isStillTrue: (PastAnswer) -> Bool
    ) async -> [PastAnswer] {
        let patterns = Self.mentionFilters(for: names)
        guard !patterns.isEmpty else { return [] }
        do {
            var query = supabase
                .from(Self.messagesTable)
                .select("content,created_at,sources,knowledge_threads(title,beat_id)")
                .eq("role", value: "assistant")
                .or(patterns.joined(separator: ","))
            if let threadID { query = query.neq("thread_id", value: threadID.uuidString) }
            let found: [PastAnswer] = try await query
                .order("created_at", ascending: false)
                .limit(limit * 8)
                .execute()
                .value
            // `ilike` finds "Leo" inside "Leonid", so the name is checked
            // again as a whole word. And an answer that cites nothing is
            // either Nod saying it found nothing — handed back, the failure a
            // person retried three times becomes the record of their week —
            // or one whose grounding cannot be checked against what has since
            // been deleted.
            return Array(found.filter { answer in
                !answer.sources.isEmpty
                    && !EntityMatcher.matched(names: names, in: answer.content).isEmpty
                    && isStillTrue(answer)
            }.prefix(limit))
        } catch {
            Log.ui.error("KnowledgeThreadStore.answers failed: \(error.localizedDescription)")
            return []
        }
    }

    /// One PostgREST `or` clause per name. Anything that could end the filter
    /// becomes a wildcard rather than vanishing, so "Node.js" still finds
    /// itself.
    static func mentionFilters(for names: [String]) -> [String] {
        names
            .map { String($0.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "*" }) }
            .filter { $0.filter(\.isLetter).count >= 3 }
            .map { "content.ilike.\"*\($0)*\"" }
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

    /// Every conversation at once, beats' own threads left alone. One request
    /// rather than a loop of `delete`: a list of eighty deletes that stops at
    /// forty leaves a sidebar nobody asked for.
    func deleteAll() async {
        guard let userID = supabase.auth.currentUser?.id else { return }
        let previous = threads
        threads = []
        do {
            try await supabase
                .from(Self.threadsTable)
                .delete()
                .eq("user_id", value: userID.uuidString)
                .is("beat_id", value: nil)
                .execute()
            purges += 1
        } catch {
            threads = previous
            Log.ui.error("KnowledgeThreadStore.deleteAll failed: \(error.localizedDescription)")
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
