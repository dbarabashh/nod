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
    private let mirrorCompletion: ((ProviderLinkItem, Bool) async -> Void)?

    /// `mirrorCompletion` carries a tick on a filed task out to the product it
    /// was filed in. Injected rather than reached for: this store must not know
    /// what an integration is, or `Core/Storage` and `Core/Backend` would point
    /// at each other.
    init(
        supabase: SupabaseClient,
        mirrorCompletion: ((ProviderLinkItem, Bool) async -> Void)? = nil
    ) {
        self.supabase = supabase
        self.mirrorCompletion = mirrorCompletion
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
        items
            .filter { $0.meetingID == meetingID }
            .sorted { $0.order < $1.order }
    }

    var openItems: [ActionItem] {
        items.filter(\.isOpen)
    }

    /// Promote recap actions for meetings that never got theirs — a finalize
    /// that ran offline, or one whose save raced and lost. `saveExtracted`
    /// writes only what the meeting does not already have, in whatever state,
    /// so this fills real gaps and never resurrects deleted tasks.
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
    /// Idempotent and non-resurrecting: every recap action is matched against
    /// what the meeting already has — in any state, including trashed — and only
    /// the unmatched ones are inserted. So a re-run, a view backfill racing the
    /// finalize save, or a meeting whose items the user deleted never produces
    /// duplicates or brings deleted tasks back. The partial-unique index on
    /// `(meeting_id, position) where deleted_at is null` is the atomic backstop
    /// for two callers that reach this at the same instant.
    ///
    /// This used to be a flat "does the meeting have any rows" gate, which was
    /// simpler and is no longer possible: `live` arrives alongside the recap and
    /// has to be merged with it, not refused because the other one got there.
    ///
    /// `live` is what `LiveMeetingAnalyst` heard during the call. The recap read
    /// the whole transcript afterwards, so where the two agree the live finding
    /// is corroborated and becomes a real task; where the recap is silent about
    /// something the live pass called an action, the live pass over-read and the
    /// row is written `dropped`. Both are kept — a task Nod caught mid-meeting
    /// and one it talked itself out of are both part of what happened, and
    /// neither costs the user anything, because only `confirmed` actions are
    /// ever counted or shown.
    func saveExtracted(
        _ actions: [MeetingRecap.Action],
        live: [LiveFinding] = [],
        meetingID: UUID,
        userID: UUID
    ) async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        let recap = actions.enumerated().compactMap { idx, action -> (position: Int, action: MeetingRecap.Action)? in
            action.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (idx, action)
        }
        guard !recap.isEmpty || !live.isEmpty else { return }
        guard let existing = await existingRows(forMeeting: meetingID) else { return }

        var rows = Self.rows(for: live, meetingID: meetingID, userID: userID)
        // Superseded findings are history and cannot be what the recap means;
        // a dismissed one is the user's own veto and must not be silently
        // resurrected because the recap happens to mention something similar.
        // Only what still stands, unrejected, is open to corroboration.
        var unclaimed = live
            .filter { $0.kind == .action && $0.state == .standing }
            .compactMap { rows[$0.id] }

        for (position, action) in recap {
            let text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Already on the server, in whatever state — an earlier run's row,
            // or one the user deleted. Left exactly as it is.
            if existing.contains(where: { ActionItemDedup.same($0.text, text) }) { continue }

            if let matchIndex = unclaimed.firstIndex(where: { ActionItemDedup.same($0.text, text) }) {
                let match = unclaimed.remove(at: matchIndex)
                // The recap's wording wins. It read the whole transcript with the
                // stronger model where the live pass had a few minutes and a
                // weaker one, and on a real call the difference is visible:
                // "Start the Blend vs. Telnyx comparison and send it to Mike by
                // Monday" against "Create a comparison table for Blend research
                // (comparing Telnyx and the server)". What the live row keeps is
                // what the recap has no way to know — which line it came from.
                rows[match.id] = match.corroborating(action, position: position)
                continue
            }
            rows[UUID()] = ActionItem.new(
                meetingID: meetingID,
                userID: userID,
                text: text,
                deadline: action.deadline?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                position: position
            )
        }

        for orphan in unclaimed {
            rows[orphan.id]?.status = .dropped
        }

        let inserts = Array(rows.values)
        guard !inserts.isEmpty else { return }
        do {
            try await supabase.from(Self.tableName).insert(inserts).execute()
        } catch {
            Log.ui.error("ActionItemStore.saveExtracted failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Live findings as rows, keyed by the finding's own id so `revision_of`
    /// keeps pointing at the right one.
    ///
    /// Only actions start out unconfirmed. The recap emits nothing but tasks, so
    /// its silence about a decision or an open question is not evidence against
    /// it — those stand on the quote the analyst already verified against the
    /// transcript, and `isOpen` keeps them out of the user's task list anyway.
    private static func rows(for live: [LiveFinding], meetingID: UUID, userID: UUID) -> [UUID: ActionItem] {
        var rows: [UUID: ActionItem] = [:]
        for finding in live {
            let row = ActionItem.new(
                id: finding.id,
                meetingID: meetingID,
                userID: userID,
                text: finding.text,
                deadline: finding.deadline,
                position: nil,
                kind: finding.kind,
                status: finding.resolvedStatus,
                source: .live,
                revisionOf: finding.revisionOf,
                evidenceIdx: finding.evidenceIdx
            )
            rows[finding.id] = row
        }
        return rows
    }

    /// Every row the meeting already has, trashed ones included — the input to
    /// `saveExtracted`'s reconciliation. Nil means the read failed, and the
    /// caller must then write nothing: without knowing what is there, an insert
    /// risks a duplicate or a resurrected-after-delete task.
    private func existingRows(forMeeting meetingID: UUID) async -> [ActionItem]? {
        do {
            return try await supabase
                .from(Self.tableName)
                .select()
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
                .value
        } catch {
            Log.ui.error("ActionItemStore.existingRows failed — skipping extract: \(error.localizedDescription)")
            return nil
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
            .eq("kind", value: ActionItem.Kind.action.rawValue)
            .eq("status", value: ActionItem.Status.confirmed.rawValue)
            .order("created_at", ascending: false)
            .order("position", ascending: true)
            .limit(2000)
            .execute()
            .value
    }

    /// What a meeting produced that is NOT a task — the decisions it settled,
    /// the questions it left open, the risks somebody named.
    ///
    /// Its own fetch rather than a slice of `items`, because these are not the
    /// user's to-do list and must never be counted as one: `items` feeds the
    /// attention column, the cross-meeting checklist and the open-commitments
    /// count, and a decision landing in any of those is wrong. Loaded per
    /// meeting, where they are read, and nowhere else.
    func notes(forMeeting meetingID: UUID) async throws -> [ActionItem] {
        #if DEBUG
            if DemoMode.isEnabled { return [] }
        #endif
        return try await supabase
            .from(Self.tableName)
            .select()
            .eq("meeting_id", value: meetingID.uuidString)
            .neq("kind", value: ActionItem.Kind.action.rawValue)
            .eq("status", value: ActionItem.Status.confirmed.rawValue)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: true)
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
            .eq("kind", value: ActionItem.Kind.action.rawValue)
            .eq("status", value: ActionItem.Status.confirmed.rawValue)
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
        await markDone(done, itemID: itemID, mirroring: true)
    }

    /// `mirroring` is false only when the tick *came* from the other side —
    /// telling a tracker what it just told us is a wasted call, and on a
    /// reconnect it would be a whole list of them.
    private func markDone(_ done: Bool, itemID: UUID, mirroring: Bool) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let previous = items[index]
        items[index] = previous.marked(done: done, at: done ? Date() : nil)
        didMutate()
        do {
            try await persistDone(done, itemID: itemID)
        } catch {
            restore(previous)
            Log.ui.error("ActionItemStore.setDone failed: \(error.localizedDescription)")
            return
        }
        if mirroring, let reference = previous.filed {
            await mirrorCompletion?(reference, done)
        }
    }

    /// Brings filed items into line with the tracker they live in.
    ///
    /// Writes only the ones that disagree, so a pass where nothing moved — which
    /// is nearly every pass — costs nothing. One write each rather than a batch:
    /// an item crosses this line once or twice in its life.
    func applyRemoteCompletions(_ states: [UUID: Bool]) async {
        for (itemID, closed) in states {
            guard let item = items.first(where: { $0.id == itemID }), item.done != closed else { continue }
            await markDone(closed, itemID: itemID, mirroring: false)
        }
    }

    /// Records that an item has been filed in a connected product. Optimistic
    /// like `setDone`: the row is already created on the other side, so the UI
    /// must stop offering the button immediately — a slow write here would
    /// otherwise invite a second, duplicate ticket.
    func recordFiling(itemID: UUID, reference: ProviderLinkItem) async {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let previous = items[index]
        let filedAt = Date()
        items[index] = previous.filed(in: reference, at: filedAt)
        didMutate()

        let body = FilingBody(
            external_provider: reference.provider.rawValue,
            external_key: reference.title,
            external_url: reference.url.absoluteString,
            external_created_at: filedAt,
            updated_at: filedAt
        )
        for delay in Self.filingRetryDelays {
            do {
                try await patch(body, itemID: itemID)
                return
            } catch {
                Log.ui.error("ActionItemStore.recordFiling failed: \(error.localizedDescription)")
                guard delay > 0 else { break }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        // Deliberately no `restore`. Every other write here is undone on failure
        // because nothing happened; this one has already happened, in another
        // product. Reverting the row to "not filed" is what re-offers the button
        // for a ticket that exists, and that is how a duplicate gets created.
        // The pointer is lost until the next `refresh`, not the ticket.
        Log.ui.error("ActionItemStore.recordFiling gave up; \(reference.title) is filed but unrecorded")
    }

    /// Between attempts, ending in 0 — the last pass doesn't wait, it reports.
    /// A failure here is a network blip or an expired session, and both are
    /// gone or permanent within a couple of seconds.
    private static let filingRetryDelays: [UInt64] = [500_000_000, 1_500_000_000, 0]

    private struct FilingBody: Encodable {
        let external_provider: String
        let external_key: String
        let external_url: String
        let external_created_at: Date
        let updated_at: Date
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
        struct Body: Encodable {
            let deleted_at: Date
            let updated_at: Date
        }
        let now = Date()
        try await patch(Body(deleted_at: now, updated_at: now), itemID: itemID)
    }

    private func persistText(_ text: String, itemID: UUID) async throws {
        struct Body: Encodable {
            let text: String
            let updated_at: Date
        }
        try await patch(Body(text: text, updated_at: Date()), itemID: itemID)
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
            position: position,
            source: .user
        )
        try await supabase.from(Self.tableName).insert(item).execute()
        return item
    }

    /// The one update path: every mutation here is the same
    /// demo-guard-then-patch-by-id, and it was written four times.
    private func patch(_ body: some Encodable, itemID: UUID) async throws {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        try await supabase
            .from(Self.tableName)
            .update(body)
            .eq("id", value: itemID.uuidString)
            .execute()
    }

    private func persistDone(_ done: Bool, itemID: UUID) async throws {
        struct Body: Encodable {
            let done: Bool
            let done_at: Date?
            let updated_at: Date
        }
        let now = Date()
        try await patch(Body(done: done, done_at: done ? now : nil, updated_at: now), itemID: itemID)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
