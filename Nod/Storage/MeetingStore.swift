import Foundation
import Combine
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

    private let supabase: SupabaseClient
    private static let tableName = "meetings"

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    // MARK: - Write

    /// Persists a completed meeting. Throws on network / RLS / decode error
    /// so the caller can surface a retry toast.
    func insert(_ meeting: Meeting) async throws {
        Log.ui.info("MeetingStore.insert id=\(meeting.id.uuidString) startedAt=\(meeting.startedAt.timeIntervalSince1970)")
        try await supabase
            .from(Self.tableName)
            .insert(meeting)
            .execute()
        // Optimistic local update so HistoryView reflects the new row even
        // before the next full refresh. Sorted newest-first to match the
        // server-side ordering.
        meetings.insert(meeting, at: 0)
        meetings.sort { $0.startedAt > $1.startedAt }
        // Promote loadState so HistoryView's content switch shows the list
        // even if `refresh()` has never run (first meeting on a fresh
        // install, HistoryView opened later).
        loadState = .loaded
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
        struct Patch: Encodable {
            let title: String?
            let summary: String

            enum CodingKeys: String, CodingKey {
                case title, summary
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(summary, forKey: .summary)
                if let title {
                    try c.encode(title, forKey: .title)
                } else {
                    try c.encodeNil(forKey: .title)
                }
            }
        }
        let patch = Patch(title: meeting.title, summary: meeting.summary)

        try await supabase
            .from(Self.tableName)
            .update(patch)
            .eq("id", value: meeting.id.uuidString)
            .execute()

        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        }
    }

    // MARK: - Lifecycle

    /// Drops any cached meetings + resets the state machine. Call on sign-out
    /// so the next user can't briefly see the previous one's rows from the
    /// in-memory cache before RLS-scoped refresh runs.
    func clear() {
        meetings = []
        loadState = .idle
    }

    // MARK: - Read

    /// Fetches the current user's non-deleted meetings, newest first. RLS
    /// makes the WHERE-on-user-id implicit — the server only returns rows
    /// that match the JWT.
    func refresh() async {
        // Dedupe concurrent calls (toolbar spam + .task race). The disabled
        // toolbar state is best-effort UI — gate at the source.
        if case .loading = loadState {
            Log.ui.info("MeetingStore.refresh skipped — already in flight")
            return
        }
        Log.ui.info("MeetingStore.refresh starting")
        loadState = .loading
        do {
            // Capped at 500 newest. With no transcript column (#14 follow-up)
            // each row is ~1-2 KB, so 500 ≈ 1 MB — acceptable for v1.
            // Real cursor pagination is a follow-up once a user hits this cap;
            // for now SwiftUI's List is lazy at the row-render level so the
            // memory cost is only the in-array storage.
            let rows: [Meeting] = try await supabase
                .from(Self.tableName)
                .select()
                .order("started_at", ascending: false)
                .limit(500)
                .execute()
                .value
            meetings = rows
            loadState = .loaded
            Log.ui.info("MeetingStore.refresh loaded \(rows.count) meetings")
        } catch {
            Log.ui.error("MeetingStore.refresh failed: \(error.localizedDescription)")
            loadState = .failed(error.localizedDescription)
        }
    }
}
