import Combine
import Foundation
import Supabase

/// Supabase-backed repository for completed meetings.
///
/// Two-layer responsibility:
/// - **Write path** (`insert`) — called from the end-of-meeting flow once the
///   summary is ready. Failures bubble up so the caller can surface a retry
///   toast; this class does NOT cache pending writes itself (v1 — add an
///   outbox if real losses surface).
/// - **Read path** (`refresh`, `meetings`) — drives HistoryView. Holds the
///   list of meetings sorted newest-first as an `@Published` collection so
///   the SwiftUI list re-renders on insert / refresh.
///
/// All requests use the user's Supabase JWT; the `meetings` RLS policies
/// enforce `auth.uid() = user_id`, so an authenticated client can only ever
/// read or write its own rows.
///
/// Issue #14.
@MainActor
final class MeetingStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var loadState: LoadState = .idle

    /// Soft-deleted meetings (the "Trash") — loaded lazily by the Trash
    /// segment of HistoryView. Empty until `refreshTrash()` runs.
    @Published private(set) var trashedMeetings: [Meeting] = []
    @Published private(set) var trashState: LoadState = .idle

    /// Most recently soft-deleted meeting — drives the Undo toast in
    /// HistoryView. Set by `softDelete(_:)`, cleared by `restore(_:)`,
    /// `hardDelete(_:)`, `dismissUndo()`, or the 5-second auto-timer.
    /// Lives on the store so deletions triggered from MeetingDetailView's
    /// toolbar surface the same Undo affordance as right-click deletes.
    /// `private(set)` so all mutations flow through the explicit methods
    /// (`softDelete` sets, `dismissUndo` / `restore` / `hardDelete` clear).
    @Published private(set) var pendingUndo: Meeting?

    /// True when the most recent `refresh()` attempt failed AND we kept
    /// cached `meetings` instead of flipping to `.failed`. Drives a
    /// non-blocking "couldn't sync, showing cached" warning in
    /// HistoryView's toolbar so the user knows the list may be stale
    /// without losing access to what we already have. Cleared on the
    /// next successful refresh.
    @Published private(set) var lastRefreshFailed: Bool = false

    /// Meeting IDs whose summary the LLM is still producing. Populated by
    /// `beginGenerating(_:)` when the floating panel hands off to
    /// MeetingDetailView at end-of-meeting, drained by
    /// `applyGenerated(_:)` / `markGenerationFailed(...)` when the LLM
    /// returns. MeetingDetailView watches this set to swap the Summary
    /// tab between the live loading placeholder and the real content,
    /// and to gate edit/copy/transcript affordances that don't make
    /// sense until the row has been finalised.
    @Published private(set) var generatingSummaryIDs: Set<UUID> = []

    private let supabase: SupabaseClient
    private static let tableName = "meetings"
    private static let transcriptsTableName = "meeting_transcripts"

    /// In-flight guard for `refresh()`. Set unconditionally at entry so
    /// concurrent silent refreshes (when `loadState` stays `.loaded`)
    /// dedupe — the previous `if case .loading = loadState` guard only
    /// fired for the first non-cached fetch, letting subsequent silent
    /// refreshes race each other on every NavigationStack pop.
    private var isFetching: Bool = false

    /// Timestamp of the last successful server fetch. Used by `refresh()`
    /// to throttle silent refreshes: `.task` re-fires on every
    /// NavigationStack pop, but if we just fetched < 30s ago the cache is
    /// almost certainly fresh enough — skip the 500-row round trip.
    private var lastSuccessfulFetchAt: Date?
    private let refreshThrottle: TimeInterval = 30

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    // MARK: - Write

    /// Persists a completed meeting. Throws on network / RLS / decode error
    /// so the caller can surface a retry toast. Idempotent on the local
    /// cache: if a draft for this id already exists (the meeting was
    /// previously registered via `beginGenerating(_:)`), the local row
    /// is replaced rather than duplicated.
    func insert(_ meeting: Meeting) async throws {
        Log.ui.info("MeetingStore.insert id=\(meeting.id.uuidString) startedAt=\(meeting.startedAt.timeIntervalSince1970)")
        try await supabase
            .from(Self.tableName)
            .insert(meeting)
            .execute()
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        } else {
            // Optimistic local update so HistoryView reflects the new row even
            // before the next full refresh. Sorted newest-first to match the
            // server-side ordering.
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        // Promote loadState so HistoryView's content switch shows the list
        // even if `refresh()` has never run (first meeting on a fresh
        // install, HistoryView opened later).
        loadState = .loaded
    }

    // MARK: - Generating handoff

    /// Inserts a draft meeting (empty summary, nil title) into the local
    /// cache and flags its id as generating. No server call — the row
    /// only reaches Supabase when the caller follows up with
    /// `insert(_:)` after the LLM lands. Used by the end-of-meeting flow
    /// so MeetingDetailView can open immediately with a loading state
    /// while summary + title are still being produced.
    func beginGenerating(_ draft: Meeting) {
        Log.ui.info("MeetingStore.beginGenerating id=\(draft.id.uuidString)")
        if let idx = meetings.firstIndex(where: { $0.id == draft.id }) {
            meetings[idx] = draft
        } else {
            meetings.insert(draft, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        generatingSummaryIDs.insert(draft.id)
        loadState = .loaded
    }

    /// Replaces the local draft with the LLM-finalised meeting (summary
    /// + title now populated) and clears the generating flag so
    /// MeetingDetailView swaps from the loading placeholder to the
    /// real content. Local-only — server persistence remains the
    /// caller's responsibility via `insert(_:)`.
    func applyGenerated(_ meeting: Meeting) {
        Log.ui.info("MeetingStore.applyGenerated id=\(meeting.id.uuidString)")
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        } else {
            // Draft was wiped between begin and apply — most likely a
            // sign-out triggered `clear()` while the LLM was running.
            // The detail view (if still open) will fall back to the
            // empty captured draft; log so the missing UI update isn't
            // silent.
            Log.ui.info("MeetingStore.applyGenerated dropped — meeting not in cache: \(meeting.id.uuidString)")
        }
        generatingSummaryIDs.remove(meeting.id)
    }

    /// Summary generation failed end-to-end. Stamp the error message into
    /// `summary` so the detail view can show it inline, then clear the
    /// generating flag. Local-only — a failed generation never gets
    /// persisted to the server.
    func markGenerationFailed(id: UUID, errorMessage: String) {
        Log.ui.info("MeetingStore.markGenerationFailed id=\(id.uuidString)")
        if let idx = meetings.firstIndex(where: { $0.id == id }) {
            meetings[idx] = meetings[idx].updating(
                title: meetings[idx].title,
                summary: errorMessage
            )
        }
        generatingSummaryIDs.remove(id)
    }

    /// Patches `title` + `summary` for an existing meeting. Only those two
    /// fields are sent in the payload — other columns (started_at, etc.)
    /// stay untouched even though the local Meeting carries them. Local
    /// cache is replaced on success so HistoryView re-renders without a
    /// full refresh.
    func update(_ meeting: Meeting) async throws {
        Log.ui.info("MeetingStore.update id=\(meeting.id.uuidString)")

        // Custom encode so a nil title emits explicit `null` (not an omitted
        // key). Swift's synthesised Encodable uses `encodeIfPresent` for
        // optionals → server keeps the old value when the user clears the
        // title. Forcing `null` makes the PATCH actually clear the column.
        // `recap` follows the same rule: if the client has structured state,
        // send it; if it's been dropped (e.g. legacy markdown-only meeting
        // or a manual edit that invalidated the JSON), don't touch the column.
        struct Patch: Encodable {
            let title: String?
            let summary: String
            let recap: MeetingRecap?

            enum CodingKeys: String, CodingKey {
                case title, summary
                case recap = "recap_json"
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(summary, forKey: .summary)
                if let title {
                    try c.encode(title, forKey: .title)
                } else {
                    try c.encodeNil(forKey: .title)
                }
                try c.encodeIfPresent(recap, forKey: .recap)
            }
        }
        let patch = Patch(title: meeting.title, summary: meeting.summary, recap: meeting.recap)

        try await supabase
            .from(Self.tableName)
            .update(patch)
            .eq("id", value: meeting.id.uuidString)
            .execute()

        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        }
    }

    // MARK: - Transcripts

    /// Bulk-inserts the in-memory transcript entries for a just-saved
    /// meeting. Called from the end-of-meeting flow right after
    /// `insert(_:)` succeeds. Throws on RLS / network / decode error so
    /// the caller can decide whether to surface this — failing here
    /// shouldn't block the summary save (the summary is already on the
    /// server), so callers should log + continue rather than abort.
    func insertTranscript(_ records: [TranscriptRecord]) async throws {
        guard !records.isEmpty else { return }
        Log.ui.info("MeetingStore.insertTranscript meeting=\(records[0].meetingID.uuidString) count=\(records.count)")
        try await supabase
            .from(Self.transcriptsTableName)
            .insert(records)
            .execute()
    }

    /// Loads the full transcript for one meeting, ordered chronologically.
    /// Used by MeetingDetailView's Transcript tab — lazy, only runs when
    /// the tab is first opened.
    func fetchTranscript(meetingID: UUID) async throws -> [TranscriptRecord] {
        Log.ui.info("MeetingStore.fetchTranscript meeting=\(meetingID.uuidString)")
        // Sanity cap: ~5000 ≈ a 7-hour meeting at 5-second chunks. Real
        // meetings stay well under this; the cap exists so a runaway
        // (corrupted idx, bug in the ingest path) can't blow up the
        // detail view's memory footprint.
        return try await supabase
            .from(Self.transcriptsTableName)
            .select()
            .eq("meeting_id", value: meetingID.uuidString)
            .order("idx", ascending: true)
            .limit(5000)
            .execute()
            .value
    }

    // MARK: - Sharing

    /// Base URL of the share web viewer (share-nod-ui-service), deployed at
    /// `share.hellonod.app`. Override per-device — e.g. to the Vite dev server
    /// `http://localhost:5173` while developing the viewer — via the
    /// `share.viewerBaseURL` UserDefaults key (same pattern as the
    /// `openrouter.model` / `whisper.model` overrides).
    private static var shareViewerBaseURL: String {
        UserDefaults.standard.string(forKey: "share.viewerBaseURL") ?? "https://share.hellonod.app"
    }

    /// Creates (or reuses) a public share link for a meeting and returns the
    /// viewer URL to drop on the clipboard.
    ///
    /// Privacy-by-default: nothing is shared until this is called. The
    /// `create_meeting_share` RPC verifies ownership server-side, mints an
    /// opaque token (reusing the meeting's existing live share if there is
    /// one — so the same meeting always yields a stable link), and the viewer
    /// reads only the summary back through that token. The link is revocable.
    func createShareURL(for meeting: Meeting) async throws -> URL {
        Log.ui.info("MeetingStore.createShareURL meeting=\(meeting.id.uuidString)")
        struct Params: Encodable {
            let p_meeting_id: UUID
        }
        let token: UUID = try await supabase
            .rpc("create_meeting_share", params: Params(p_meeting_id: meeting.id))
            .execute()
            .value

        guard let url = URL(string: "\(Self.shareViewerBaseURL)/share/\(token.uuidString.lowercased())") else {
            throw URLError(.badURL)
        }
        return url
    }

    // MARK: - Trash (issue #16)

    /// Soft delete — calls the `soft_delete_meeting` RPC so `deleted_at`
    /// is stamped with the server's `now()` (not the client's wall-clock,
    /// which can be skewed and cause the pg_cron purge to fire early).
    /// Row drops out of `meetings` and (if trash is already loaded)
    /// appears in `trashedMeetings`. `pendingUndo` is ALWAYS set on
    /// success so the Undo toast surfaces even when the row wasn't in
    /// the local `meetings` cache (e.g. delete-from-detail with a stale
    /// list).
    func softDelete(_ meeting: Meeting) async throws {
        Log.ui.info("MeetingStore.softDelete id=\(meeting.id.uuidString)")
        struct Params: Encodable {
            let meeting_id: UUID
        }
        try await supabase
            .rpc("soft_delete_meeting", params: Params(meeting_id: meeting.id))
            .execute()

        meetings.removeAll { $0.id == meeting.id }
        if case .loaded = trashState {
            // The trash-list copy carries a client-side `deletedAt` for
            // the "trashed Xd ago" badge until the next refreshTrash
            // overwrites with the server-stamped value.
            let trashedCopy = Meeting(
                id: meeting.id,
                userID: meeting.userID,
                createdAt: meeting.createdAt,
                startedAt: meeting.startedAt,
                endedAt: meeting.endedAt,
                title: meeting.title,
                kind: meeting.kind,
                summary: meeting.summary,
                recap: meeting.recap,
                language: meeting.language,
                deletedAt: Date()
            )
            trashedMeetings.insert(trashedCopy, at: 0)
        }
        pendingUndo = meeting
    }

    /// Restore — calls the `restore_meeting` RPC; row returns to
    /// `meetings`. Symmetric with `softDelete` so any future audit /
    /// logging hook lives server-side. The local cache copy is rebuilt
    /// with `deletedAt: nil` so callers reading the field don't see a
    /// stale trash timestamp on a row that's now live.
    func restore(_ id: UUID) async throws {
        Log.ui.info("MeetingStore.restore id=\(id.uuidString)")
        struct Params: Encodable {
            let meeting_id: UUID
        }
        try await supabase
            .rpc("restore_meeting", params: Params(meeting_id: id))
            .execute()

        if let idx = trashedMeetings.firstIndex(where: { $0.id == id }) {
            let row = trashedMeetings.remove(at: idx)
            if case .loaded = loadState {
                let restored = Meeting(
                    id: row.id,
                    userID: row.userID,
                    createdAt: row.createdAt,
                    startedAt: row.startedAt,
                    endedAt: row.endedAt,
                    title: row.title,
                    kind: row.kind,
                    summary: row.summary,
                    recap: row.recap,
                    language: row.language,
                    deletedAt: nil
                )
                meetings.insert(restored, at: 0)
                meetings.sort { $0.startedAt > $1.startedAt }
            }
        }
        if pendingUndo?.id == id { pendingUndo = nil }
    }

    /// Hard delete — removes the row from the table outright. Used by
    /// "Delete Forever" + the nightly pg_cron purge.
    func hardDelete(_ id: UUID) async throws {
        Log.ui.info("MeetingStore.hardDelete id=\(id.uuidString)")
        try await supabase
            .from(Self.tableName)
            .delete()
            .eq("id", value: id.uuidString)
            .execute()

        meetings.removeAll { $0.id == id }
        trashedMeetings.removeAll { $0.id == id }
        if pendingUndo?.id == id { pendingUndo = nil }
    }

    /// Dismiss the Undo toast without acting on it (user clicked the X
    /// or the 5s window elapsed). The meeting stays in Trash.
    func dismissUndo() {
        pendingUndo = nil
    }

    /// Fetches the user's soft-deleted meetings, newest-trashed first.
    /// Lazy — only runs when the Trash segment is opened.
    func refreshTrash() async {
        if case .loading = trashState {
            Log.ui.info("MeetingStore.refreshTrash skipped — already in flight")
            return
        }
        Log.ui.info("MeetingStore.refreshTrash starting")
        trashState = .loading
        do {
            let rows: [Meeting] = try await supabase
                .from(Self.tableName)
                .select()
                .not("deleted_at", operator: .is, value: "null")
                .order("deleted_at", ascending: false)
                .limit(500)
                .execute()
                .value
            trashedMeetings = rows
            trashState = .loaded
            Log.ui.info("MeetingStore.refreshTrash loaded \(rows.count) trashed meetings")
        } catch {
            Log.ui.error("MeetingStore.refreshTrash failed: \(error.localizedDescription)")
            trashState = .failed(error.localizedDescription)
        }
    }

    /// Server rows plus any local drafts still mid-generation — they aren't
    /// on the server yet, so a naive `meetings = rows` would yank the row out
    /// from under MeetingDetailView while it renders the loading placeholder.
    static func merging(rows: [Meeting], drafts: [Meeting]) -> [Meeting] {
        var merged = rows
        for draft in drafts where !merged.contains(where: { $0.id == draft.id }) {
            merged.append(draft)
        }
        merged.sort { $0.startedAt > $1.startedAt }
        return merged
    }

    // MARK: - Lifecycle

    /// Drops any cached meetings + resets the state machine. Call on sign-out
    /// so the next user can't briefly see the previous one's rows from the
    /// in-memory cache before RLS-scoped refresh runs.
    func clear() {
        meetings = []
        loadState = .idle
        trashedMeetings = []
        trashState = .idle
        lastRefreshFailed = false
        lastSuccessfulFetchAt = nil
        generatingSummaryIDs = []
    }

    // MARK: - Read

    /// Fetches the current user's non-deleted meetings, newest first. RLS
    /// makes the WHERE-on-user-id implicit — the server only returns rows
    /// that match the JWT.
    /// `force` bypasses the 30s throttle but never the in-flight guard.
    /// Use `force: true` for explicit user-initiated retries (toolbar
    /// reload button, "Couldn't sync" warning chip); leave the default
    /// for `.task`-driven auto-refreshes that should be throttled.
    func refresh(force: Bool = false) async {
        // Unconditional in-flight guard. Covers both initial fetch
        // (loadState would flip to .loading and the old check caught
        // those) AND silent refresh (loadState stays .loaded and the
        // old check would have let concurrent calls through).
        if isFetching {
            Log.ui.info("MeetingStore.refresh skipped — already in flight")
            return
        }

        let hadLoadedCache = if case .loaded = loadState { true } else { false }

        // Throttle silent refreshes. `.task` re-fires on every
        // NavigationStack pop; if the cache is < 30s old it's basically
        // fresh and the 500-row round trip is wasteful. Initial fetch
        // (no loaded cache yet) always proceeds. `force=true` (manual
        // retry) bypasses — user explicitly asked, honor that even if
        // the last success was 5s ago.
        if !force, hadLoadedCache, let last = lastSuccessfulFetchAt,
           Date().timeIntervalSince(last) < refreshThrottle {
            Log.ui.info("MeetingStore.refresh throttled — last success \(Int(Date().timeIntervalSince(last)))s ago")
            return
        }

        isFetching = true
        defer { isFetching = false }

        // Silent refresh when we already have a loaded cache: don't flip
        // to .loading (which would show the spinner and blank the list
        // mid-fetch), and on failure keep the cache while surfacing a
        // non-blocking warning chip via `lastRefreshFailed` so the user
        // knows the list may be stale. Failures are recoverable on the
        // next attempt; cached rows are better than an error screen, but
        // silent stale data is worse than a visible warning.
        Log.ui.info("MeetingStore.refresh starting (silent=\(hadLoadedCache))")
        if !hadLoadedCache { loadState = .loading }
        do {
            // Capped at 500 newest. Transcript lives in `meeting_transcripts`
            // (loaded lazily by the detail view), so each row here is ~1-2 KB
            // and 500 ≈ 1 MB — acceptable for v1.
            // Real cursor pagination is a follow-up once a user hits this cap;
            // for now SwiftUI's List is lazy at the row-render level so the
            // memory cost is only the in-array storage.
            // Explicit `deleted_at IS NULL` filter. After #16 added the
            // second SELECT policy ("users read own trashed meetings"),
            // RLS OR-combines both policies — a bare SELECT now returns
            // BOTH live and trashed rows. Without this client-side
            // filter, trashed meetings would reappear in the All segment
            // on every refresh.
            let rows: [Meeting] = try await supabase
                .from(Self.tableName)
                .select()
                .is("deleted_at", value: nil)
                .order("started_at", ascending: false)
                .limit(500)
                .execute()
                .value
            let drafts = meetings.filter { generatingSummaryIDs.contains($0.id) }
            meetings = Self.merging(rows: rows, drafts: drafts)
            loadState = .loaded
            lastSuccessfulFetchAt = Date()
            lastRefreshFailed = false
            Log.ui.info("MeetingStore.refresh loaded \(rows.count) meetings (+ \(drafts.count) drafts)")
        } catch {
            if hadLoadedCache {
                Log.ui.error("MeetingStore.refresh failed (keeping cache): \(error.localizedDescription)")
                // Keep loadState = .loaded so the cached list stays
                // rendered, but raise lastRefreshFailed so HistoryView
                // can show a small warning chip. Without that flag the
                // user has no signal at all that data is stale.
                lastRefreshFailed = true
            } else {
                Log.ui.error("MeetingStore.refresh failed: \(error.localizedDescription)")
                loadState = .failed(error.localizedDescription)
                lastRefreshFailed = true
            }
        }
    }
}
