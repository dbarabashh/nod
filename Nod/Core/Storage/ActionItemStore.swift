import Combine
import Foundation
import Supabase

/// Data access for `action_items`. Stateless beyond the Supabase client — the
/// per-meeting checklist view and (later) the History aggregate hold their own
/// `@State`/`@Published` and call these methods, mirroring `EntityStore`. RLS
/// scopes every read/write to the owner, so reads carry no `user_id` filter.
@MainActor
final class ActionItemStore: ObservableObject {
    private let supabase: SupabaseClient
    private static let tableName = "action_items"

    init(supabase: SupabaseClient) {
        self.supabase = supabase
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

    /// A meeting's items, promoting the recap's extracted actions first if they
    /// were never persisted — the offline / raced-finalize backfill. Driven by
    /// the per-meeting checklist's load so a meeting that finalized without
    /// network (its `saveExtracted` skipped) still materialises its tasks the
    /// first time it's opened, instead of showing an empty list forever.
    func itemsPromoting(for meeting: Meeting) async throws -> [ActionItem] {
        let existing = try await items(forMeeting: meeting.id)
        if !existing.isEmpty { return existing }
        // Passive media carries no personal to-dos — never promote a checklist
        // for it, even if a stray recap emitted one.
        guard meeting.kind.extractsActionItems,
              let pending = meeting.recap?.actionItems, !pending.isEmpty else { return existing }
        await saveExtracted(pending, meetingID: meeting.id, userID: meeting.userID)
        return try await items(forMeeting: meeting.id)
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

    /// A meeting's own action items, in recap order (open + done), excluding
    /// trashed rows. The `deleted_at IS NULL` filter lives in the query, not the
    /// RLS SELECT policy — a soft-delete UPDATE would otherwise trip the policy
    /// as a WITH CHECK on the now-hidden new row.
    func items(forMeeting meetingID: UUID) async throws -> [ActionItem] {
        try await supabase
            .from(Self.tableName)
            .select()
            .eq("meeting_id", value: meetingID.uuidString)
            .is("deleted_at", value: nil)
            .order("position", ascending: true)
            .limit(500)
            .execute()
            .value
    }

    /// Every non-trashed action item across the user's meetings, newest meeting
    /// first — backs the History aggregate. RLS scopes to the owner; the
    /// `deleted_at IS NULL` filter is applied here in the query (see above).
    func allItems() async throws -> [ActionItem] {
        try await supabase
            .from(Self.tableName)
            .select()
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .order("position", ascending: true)
            .limit(2000)
            .execute()
            .value
    }

    /// Soft-delete a single item (used to resolve a flagged duplicate). Mirrors
    /// the `meetings` soft-delete: stamps `deleted_at` so it drops out of every
    /// read without a hard delete.
    func softDelete(itemID: UUID) async throws {
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

    /// Rename a single item's text — the inline edit of an AI-extracted or
    /// user-added task. The caller updates its local copy optimistically.
    func updateText(_ text: String, itemID: UUID) async throws {
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

    /// Insert one user-added task under a meeting and return the local row. The
    /// owner is resolved from the current session so the view needn't thread it
    /// through; RLS still checks `auth.uid() = user_id` on insert.
    func add(text: String, meetingID: UUID, position: Int) async throws -> ActionItem {
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

    /// Check / uncheck a single item, stamping `done_at` and `updated_at`. The
    /// caller updates its local copy optimistically; this persists the change.
    func setDone(_ done: Bool, itemID: UUID) async throws {
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
