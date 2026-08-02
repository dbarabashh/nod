import Combine
import Foundation
import Supabase

/// Owns the user's action items: the live rows, and every write to them. RLS
/// scopes each read/write to the owner, so queries carry no `user_id` filter.
///
/// It holds the rows rather than handing each screen its own array because four
/// surfaces render the same tasks — the attention column, the full checklist, a
/// meeting's own list, and one task's detail. When they each kept a copy, a box
/// ticked on one stayed unticked on the others until something unrelated
/// reloaded it, and the optimistic-write-then-revert dance was written out four
/// times, four slightly different ways.
@MainActor
final class ActionItemStore: ObservableObject {
    /// Every live (non-trashed) task, across meetings. Mutations apply here
    /// first and revert if the write fails, so the UI stays instant without any
    /// screen owning rollback.
    @Published private(set) var items: [ActionItem] = []
    /// Bumped with every change to `items`, as a cheap key for the derivations
    /// that shouldn't re-run on an unrelated render.
    @Published private(set) var revision = 0

    private let supabase: SupabaseClient
    private static let tableName = "action_items"
    private var didLoad = false
    private var loading: Task<Void, Never>?

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    private func didMutate() {
        revision &+= 1
    }

    // MARK: - Cache

    /// Loads every live task once. Concurrent callers await the same fetch —
    /// three surfaces mount together on the main window.
    func refresh(force: Bool = false) async {
        if let loading {
            await loading.value
            if !force { return }
        }
        if didLoad, !force { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let rows = try await allItems()
                items = rows
                didLoad = true
                didMutate()
            } catch {
                Log.ui.error("ActionItemStore.refresh failed: \(error.localizedDescription)")
            }
        }
        loading = task
        await task.value
        loading = nil
    }

    func items(forMeeting meetingID: UUID) -> [ActionItem] {
        items.filter { $0.meetingID == meetingID }.sorted { $0.position < $1.position }
    }

    var openItems: [ActionItem] {
        items.filter { !$0.done }
    }

    /// Promote recap actions for meetings that never got theirs — a finalize
    /// that ran offline, or one whose save raced and lost. `saveExtracted`
    /// no-ops when the meeting already has rows, so this only writes for real
    /// gaps and never resurrects deleted tasks.
    func promoteMissing(in meetings: [Meeting]) async {
        await refresh()
        let present = Set(items.map(\.meetingID))
        let missing = meetings.filter { meeting in
            meeting.kind.extractsActionItems
                && !present.contains(meeting.id)
                && !(meeting.recap?.actionItems.isEmpty ?? true)
        }
        guard !missing.isEmpty else { return }
        for meeting in missing {
            if let pending = meeting.recap?.actionItems {
                await saveExtracted(pending, meetingID: meeting.id, userID: meeting.userID)
            }
        }
        await refresh(force: true)
    }

    func clear() {
        items = []
        didLoad = false
        didMutate()
    }

    /// Persist a freshly-finalized meeting's extracted actions as rows. Called
    /// after the parent meeting has landed on the server (so the FK resolves),
    /// from the same enrichment block as entities/embeddings, AND lazily from
    /// the views as a backfill when an offline / raced finalize skipped it.
    /// Best-effort: a failed insert is logged, not surfaced — the recap is
    /// already saved.
    ///
    /// Idempotent and non-resurrecting: it no-ops when the meeting already has
    /// any rows (even trashed ones), so a re-run, a view backfill racing the
    /// finalize save, or a meeting whose items the user deleted never produces
    /// duplicates or brings deleted tasks back. The partial-unique index on
    /// `(meeting_id, position) where deleted_at is null` is the atomic backstop
    /// for two callers that both pass this check at the same instant.
    func saveExtracted(_ actions: [MeetingRecap.Action], meetingID: UUID, userID: UUID) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        let rows = actions.enumerated().compactMap { idx, action -> ActionItem? in
            let text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ActionItem.new(
                meetingID: meetingID,
                userID: userID,
                text: text,
                deadline: action.deadline?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                position: idx
            )
        }
        guard !rows.isEmpty else { return }
        guard await !hasAnyRows(forMeeting: meetingID) else { return }
        do {
            try await supabase.from(Self.tableName).insert(rows).execute()
        } catch {
            Log.ui.error("ActionItemStore.saveExtracted failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// True if the meeting has ANY action-item rows, including trashed ones —
    /// the resurrection / duplication guard for `saveExtracted`.
    private func hasAnyRows(forMeeting meetingID: UUID) async -> Bool {
        struct Row: Decodable { let id: UUID }
        do {
            let rows: [Row] = try await supabase
                .from(Self.tableName)
                .select("id")
                .eq("meeting_id", value: meetingID.uuidString)
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
            // On a read failure, assume rows exist so we never risk a duplicate
            // or a resurrected-after-delete insert.
            Log.ui.error("ActionItemStore.hasAnyRows failed — skipping extract: \(error.localizedDescription)")
            return true
        }
    }

    /// Every non-trashed action item across the user's meetings, newest meeting
    /// first. The `deleted_at IS NULL` filter lives in the query, not the RLS
    /// SELECT policy — a soft-delete UPDATE would otherwise trip the policy as a
    /// WITH CHECK on the now-hidden new row.
    private func allItems() async throws -> [ActionItem] {
        #if DEBUG
            if DemoMode.isEnabled { return DemoData.allActionItems() }
        #endif
        return try await supabase
            .from(Self.tableName)
            .select()
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .order("position", ascending: true)
            .limit(2000)
            .execute()
            .value
    }

    /// Just the outstanding tasks, newest first. Grounding an "what should I
    /// do" answer needs a couple of dozen open items — pulling all 2000 rows to
    /// filter and drop 99% of them client-side is transfer and decode for
    /// nothing, on the answer's critical path.
    func openItems(limit: Int) async throws -> [ActionItem] {
        #if DEBUG
            if DemoMode.isEnabled { return Array(DemoData.allActionItems().filter { !$0.done }.prefix(limit)) }
        #endif
        // Tasks outlive their session's own soft delete (the FK cascades on hard
        // delete only), so the parent has to be filtered too — otherwise a
        // trashed session's tasks keep grounding "what's on my plate", credited
        // to a session the user deleted and can no longer open.
        return try await supabase
            .from(Self.tableName)
            .select("*, meetings!inner(deleted_at)")
            .is("meetings.deleted_at", value: nil)
            .is("deleted_at", value: nil)
            .eq("done", value: false)
            .order("created_at", ascending: false)
            .order("position", ascending: true)
            .limit(limit)
            .execute()
            .value
    }

    // MARK: - Writes

    //
    // Each one applies to `items` first and puts the row back if the write
    // fails. Optimism is what makes a checkbox feel instant, and keeping it
    // here is what stops four screens from each owning a rollback.

    /// Soft-delete a single item. Mirrors the `meetings` soft-delete: stamps
    /// `deleted_at` so it drops out of every read without a hard delete.
    func softDelete(itemID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let removed = items.remove(at: index)
        didMutate()
        do {
            try await persistSoftDelete(itemID: itemID)
        } catch {
            items.insert(removed, at: min(index, items.count))
            didMutate()
            Log.ui.error("ActionItemStore.softDelete failed: \(error.localizedDescription)")
        }
    }

    /// Rename a task — the inline edit of an extracted or user-added item.
    func updateText(_ text: String, itemID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let previous = items[index]
        items[index] = previous.renamed(text)
        didMutate()
        do {
            try await persistText(text, itemID: itemID)
        } catch {
            restore(previous)
            Log.ui.error("ActionItemStore.updateText failed: \(error.localizedDescription)")
        }
    }

    /// Check / uncheck a task, stamping `done_at`.
    func setDone(_ done: Bool, itemID: UUID) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let previous = items[index]
        items[index] = previous.marked(done: done, at: done ? Date() : nil)
        didMutate()
        do {
            try await persistDone(done, itemID: itemID)
        } catch {
            restore(previous)
            Log.ui.error("ActionItemStore.setDone failed: \(error.localizedDescription)")
        }
    }

    /// Insert one user-added task under a meeting. Returns nil when the write
    /// failed, so the caller can leave its field open instead of pretending.
    @discardableResult
    func add(text: String, meetingID: UUID, position: Int) async -> ActionItem? {
        do {
            let item = try await persistInsert(text: text, meetingID: meetingID, position: position)
            items.append(item)
            didMutate()
            return item
        } catch {
            Log.ui.error("ActionItemStore.add failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Puts a row back where the id still is, after a failed write.
    private func restore(_ item: ActionItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        didMutate()
    }

    private func persistSoftDelete(itemID: UUID) async throws {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        struct Patch: Encodable {
            let deleted_at: Date
            let updated_at: Date
        }
        let now = Date()
        try await supabase
            .from(Self.tableName)
            .update(Patch(deleted_at: now, updated_at: now))
            .eq("id", value: itemID.uuidString)
            .execute()
    }

    private func persistText(_ text: String, itemID: UUID) async throws {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        struct Patch: Encodable {
            let text: String
            let updated_at: Date
        }
        try await supabase
            .from(Self.tableName)
            .update(Patch(text: text, updated_at: Date()))
            .eq("id", value: itemID.uuidString)
            .execute()
    }

    /// The owner is resolved from the current session so the view needn't thread
    /// it through; RLS still checks `auth.uid() = user_id` on insert.
    private func persistInsert(text: String, meetingID: UUID, position: Int) async throws -> ActionItem {
        #if DEBUG
            if DemoMode.isEnabled {
                return ActionItem.new(
                    meetingID: meetingID,
                    userID: UUID(),
                    text: text,
                    deadline: nil,
                    position: position
                )
            }
        #endif
        let userID = try await supabase.auth.session.user.id
        let item = ActionItem.new(
            meetingID: meetingID,
            userID: userID,
            text: text,
            deadline: nil,
            position: position
        )
        try await supabase.from(Self.tableName).insert(item).execute()
        return item
    }

    private func persistDone(_ done: Bool, itemID: UUID) async throws {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        struct Patch: Encodable {
            let done: Bool
            let done_at: Date?
            let updated_at: Date
        }
        let now = Date()
        let patch = Patch(done: done, done_at: done ? now : nil, updated_at: now)
        try await supabase
            .from(Self.tableName)
            .update(patch)
            .eq("id", value: itemID.uuidString)
            .execute()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
