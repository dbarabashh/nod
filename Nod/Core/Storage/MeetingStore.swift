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
/// - **Read path** (`refresh`, `meetings`) — drives MainWindowView. Holds the
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

    /// Whether this launch has already put the welcome-session question to the
    /// server. The server is the authority on whether one is owed; this only
    /// keeps an empty account from asking on every silent refresh.
    private var hasAskedForWelcomeSession = false

    @Published private(set) var meetings: [Meeting] = [] {
        didSet {
            byID = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            digestKey = DigestKey(count: meetings.count, newest: meetings.first?.id)
            hasSharedSessions = meetings.contains(where: isSharedWithMe)
        }
    }

    /// Whether anybody else's session is in the loaded list, so the owner filter
    /// can stay out of the way of an account working alone. Derived with the
    /// list rather than in a `body`: for that solo account the scan never
    /// short-circuits, and it would run on every keystroke of the search field.
    @Published private(set) var hasSharedSessions = false

    /// Cheap identity of the loaded set, for the surfaces that re-derive when
    /// sessions are added or removed. They used to join every id into a string
    /// as a `.task(id:)` argument — evaluated on every render, allocating the
    /// whole list to detect a change that a count and the newest id already
    /// carry.
    @Published private(set) var digestKey = DigestKey(count: 0, newest: nil)

    struct DigestKey: Equatable {
        let count: Int
        let newest: UUID?
    }

    /// Meetings keyed by id, rebuilt with the list. Every surface that renders
    /// a retrieved chunk, a source chip, or a launcher row resolves a meeting
    /// from an id, and each of them was building this same dictionary itself.
    private(set) var byID: [UUID: Meeting] = [:]
    @Published private(set) var loadState: LoadState = .idle

    /// Soft-deleted meetings (the "Trash") — loaded lazily by the Trash
    /// segment of MainWindowView. Empty until `refreshTrash()` runs.
    @Published private(set) var trashedMeetings: [Meeting] = []
    @Published private(set) var trashState: LoadState = .idle

    /// Most recently soft-deleted meeting — drives the Undo toast in
    /// MainWindowView. Set by `softDelete(_:)`, cleared by `restore(_:)`,
    /// `hardDelete(_:)`, `dismissUndo()`, or the 5-second auto-timer.
    /// Lives on the store so deletions triggered from MeetingDetailView's
    /// toolbar surface the same Undo affordance as right-click deletes.
    /// `private(set)` so all mutations flow through the explicit methods
    /// (`softDelete` sets, `dismissUndo` / `restore` / `hardDelete` clear).
    @Published private(set) var pendingUndo: Meeting?

    /// Fires after a soft delete, restore, or hard delete lands — the set of
    /// meetings retrieval is allowed to draw on just changed. Anything
    /// caching search results keyed on content rather than on this set needs
    /// telling, since it has no other way to notice a chunk it holds now
    /// belongs to a trashed (or freshly un-trashed) session.
    let onTrashChange = EventBroadcaster<Void>()

    /// True when the most recent `refresh()` attempt failed AND we kept
    /// cached `meetings` instead of flipping to `.failed`. Drives a
    /// non-blocking "couldn't sync, showing cached" warning in
    /// MainWindowView's toolbar so the user knows the list may be stale
    /// without losing access to what we already have. Cleared on the
    /// next successful refresh.
    @Published private(set) var lastRefreshFailed: Bool = false

    /// Meeting IDs whose summary the LLM is still producing. Populated by
    /// `beginGenerating(_:)` when the floating panel hands off to
    /// MeetingDetailView at end-of-meeting, drained by
    /// `applyGenerated(_:)` / `markGenerationFailed(...)` when the LLM
    /// returns. MeetingDetailView watches this set to swap the Summary
    /// tab between the live loading placeholder and the real content.
    @Published private(set) var generatingSummaryIDs: Set<UUID> = []

    /// Meeting IDs whose local draft has not fully landed on the server yet.
    /// Summary generation may already be done, but edit/chat/transcript
    /// affordances still need the meeting row and transcript records to exist.
    @Published private(set) var finalizingMeetingIDs: Set<UUID> = []

    /// Meetings whose speaker labels are still being decided — clustering at
    /// finalize, then the pass that puts names to the clusters. A row's label
    /// changes twice in that window (`Them` → `Speaker 2` → `Eric`), so the
    /// transcript shows a placeholder rather than an answer it is about to
    /// overwrite while the user is reading it.
    @Published private(set) var resolvingSpeakerIDs: Set<UUID> = []

    /// Meeting IDs that finished generating but haven't fully reached the server
    /// — they still sit in the durable `MeetingOutbox`. Mirrored from the
    /// session's drain (`setUnsyncedMeetings`). Two jobs:
    ///   1. `refresh` treats the local copy as authoritative for these, so a
    ///      stale/empty-summary server row (written mid-recording) can't clobber
    ///      the finished recap before the completion push lands.
    ///   2. the list row + detail surface a "Not synced" indicator, so the
    ///      failure is visible on the meeting itself — not only via the
    ///      detached main-window retry toast.
    @Published private(set) var unsyncedMeetingIDs: Set<UUID> = []

    /// Whether the server has this meeting yet. Anything that asks the backend
    /// about a meeting — sharing it with a team, say — has to wait for the row
    /// to exist, and the two sets below are what "not yet" looks like.
    func isPersisted(_ meetingID: UUID) -> Bool {
        !finalizingMeetingIDs.contains(meetingID) && !unsyncedMeetingIDs.contains(meetingID)
    }

    /// The meeting currently being recorded, if any — `nil` once it ends.
    /// Mirrored from `MeetingSession.recordingDraft` so surfaces that only
    /// have `MeetingStore` in their environment (Sessions list) can tell a
    /// live recording apart from an old, still-blank draft: both render with
    /// the same placeholder title and "(no summary)" preview, so without this
    /// a live recording and old clutter are visually identical — and sit
    /// right next to each other, since the live draft syncs into `meetings`
    /// within seconds of starting.
    @Published private(set) var recordingMeetingID: UUID?

    /// Partial recap markdown streamed in while a meeting's summary generates,
    /// keyed by meeting id. The end-of-meeting flow updates this section-by-
    /// section as the LLM produces them; MeetingDetailView renders it live so
    /// the recap fills in instead of popping in at the end. Cleared when
    /// generation finishes (`applyGenerated`) or fails (`markGenerationFailed`).
    @Published private(set) var streamingSummaries: [UUID: String] = [:]

    private let supabase: SupabaseClient
    /// Counts links minted. Set by the composition root.
    var analytics: ProductAnalytics?
    private static let tableName = "meetings"
    private static let speakersTableName = "meeting_speakers"

    /// Sessions this person has taken out of their own list. Somebody else's
    /// work, still where its owner left it and still readable — just not here.
    @Published private(set) var hiddenMeetingIDs: Set<UUID> = []

    private static let hidesTableName = "meeting_hides"

    /// Takes a shared session out of this account's list, on every device.
    ///
    /// Applied locally first: the row is the subject of the gesture. The server
    /// refuses this for a session of your own — Trash is the mechanism for those,
    /// and it is the one with a way back.
    func hide(_ meeting: Meeting) async throws {
        guard isSharedWithMe(meeting), let me = supabase.auth.currentUser?.id else { return }
        struct Row: Encodable {
            let user_id: UUID
            let meeting_id: UUID
        }
        let wasHidden = hiddenMeetingIDs.contains(meeting.id)
        hiddenMeetingIDs.insert(meeting.id)
        do {
            try await supabase
                .from(Self.hidesTableName)
                .upsert(Row(user_id: me, meeting_id: meeting.id), onConflict: "user_id,meeting_id")
                .execute()
        } catch {
            if !wasHidden { hiddenMeetingIDs.remove(meeting.id) }
            throw error
        }
        Log.ui.info("MeetingStore.hide id=\(meeting.id.uuidString)")
    }

    func unhide(_ meetingID: UUID) async throws {
        guard let me = supabase.auth.currentUser?.id else { return }
        let wasHidden = hiddenMeetingIDs.contains(meetingID)
        hiddenMeetingIDs.remove(meetingID)
        do {
            try await supabase
                .from(Self.hidesTableName)
                .delete()
                .eq("user_id", value: me.uuidString)
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
        } catch {
            if wasHidden { hiddenMeetingIDs.insert(meetingID) }
            throw error
        }
        Log.ui.info("MeetingStore.unhide id=\(meetingID.uuidString)")
    }

    func isHidden(_ meeting: Meeting) -> Bool {
        hiddenMeetingIDs.contains(meeting.id)
    }

    /// Re-read on every access poke: hiding on one device is a change the others
    /// have to hear about, and it travels on the same `user:` topic.
    func refreshHidden() async {
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        struct Row: Decodable { let meeting_id: UUID }
        do {
            let rows: [Row] = try await supabase
                .from(Self.hidesTableName)
                .select("meeting_id")
                .execute()
                .value
            hiddenMeetingIDs = Set(rows.map(\.meeting_id))
        } catch {
            Log.ui.error("MeetingStore.refreshHidden failed: \(error.localizedDescription)")
        }
    }

    /// Whether a session reached this list through a folder somebody shared,
    /// rather than by being recorded here. Row-level security started returning
    /// other people's sessions the moment sharing existed, and a list that mixes
    /// them in silently is a list that misleads about who was in the room.
    func isSharedWithMe(_ meeting: Meeting) -> Bool {
        guard let me = supabase.auth.currentUser?.id else { return false }
        return meeting.userID != me
    }

    private static let transcriptsTableName = "meeting_transcripts"
    private static let liveFindingsTableName = "meeting_live_findings"

    /// In-flight guard for `refresh()`. Set unconditionally at entry so
    /// concurrent silent refreshes (when `loadState` stays `.loaded`)
    /// dedupe — the previous `if case .loading = loadState` guard only
    /// fired for the first non-cached fetch, letting subsequent silent
    /// refreshes race each other on every NavigationStack pop.
    private var isFetching: Bool = false
    private var refetchRequested: Bool = false
    private var isFetchingTrash: Bool = false
    private var refetchTrashRequested: Bool = false
    private var queuedTrashIsSilent: Bool = true

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

    /// Insert-or-update on the primary key. Used by the durable `MeetingOutbox`
    /// path: a meeting may already exist server-side from an earlier streamed
    /// insert (live transcript), so a plain insert would PK-conflict. Promotes
    /// `loadState` and updates the local cache optimistically so MainWindowView
    /// reflects the new row before the next full refresh.
    func upsert(_ meeting: Meeting) async throws {
        Log.ui.info("MeetingStore.upsert id=\(meeting.id.uuidString)")
        #if DEBUG
            if DemoMode.isEnabled {
                if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
                    meetings[idx] = meeting
                } else {
                    meetings.insert(meeting, at: 0)
                    meetings.sort { $0.startedAt > $1.startedAt }
                }
                loadState = .loaded
                return
            }
        #endif
        try await supabase
            .from(Self.tableName)
            .upsert(meeting)
            .execute()
        if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[idx] = meeting
        } else {
            meetings.insert(meeting, at: 0)
            meetings.sort { $0.startedAt > $1.startedAt }
        }
        loadState = .loaded
    }

    // MARK: - Generating handoff

    /// Inserts a draft meeting (empty summary, nil title) into the local
    /// cache and flags its id as generating. No server call — the row
    /// only reaches Supabase when the caller follows up with
    /// `upsert(_:)` after the LLM lands. Used by the end-of-meeting flow
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
        finalizingMeetingIDs.insert(draft.id)
        loadState = .loaded
    }

    /// Publishes the latest partial recap markdown for a still-generating
    /// meeting so MeetingDetailView can render it live. No-op once the meeting
    /// has left the generating set (a late stream delta after finalize).
    func updateStreamingSummary(id: UUID, markdown: String) {
        guard generatingSummaryIDs.contains(id) else { return }
        streamingSummaries[id] = markdown
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
        streamingSummaries[meeting.id] = nil
    }

    func beginResolvingSpeakers(id: UUID) {
        resolvingSpeakerIDs.insert(id)
    }

    func finishResolvingSpeakers(id: UUID) {
        resolvingSpeakerIDs.remove(id)
    }

    /// Marks the end-of-meeting persistence path complete for a local draft.
    func finishFinalizing(id: UUID) {
        Log.ui.info("MeetingStore.finishFinalizing id=\(id.uuidString)")
        finalizingMeetingIDs.remove(id)
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
        finalizingMeetingIDs.remove(id)
        streamingSummaries[id] = nil
    }

    /// Mirror of the durable outbox's not-yet-synced completed meetings, pushed
    /// by the session after every drain. Records the ids (for the "Not synced"
    /// UI + the refresh-merge override) and folds the outbox's authoritative
    /// copies into the cache — on a cold launch the cache is hydrated from the
    /// server, where these rows may still carry an empty mid-recording summary,
    /// so the on-disk recap has to win until the completion push lands.
    func setUnsyncedMeetings(_ unsynced: [Meeting]) {
        unsyncedMeetingIDs = Set(unsynced.map(\.id))
        guard !unsynced.isEmpty else { return }
        var inserted = false
        for meeting in unsynced {
            if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
                meetings[idx] = meeting
            } else {
                meetings.append(meeting)
                inserted = true
            }
        }
        if inserted { meetings.sort { $0.startedAt > $1.startedAt } }
        loadState = .loaded
    }

    /// Mirrors `MeetingSession.recordingDraft`'s id — set when a recording
    /// starts, cleared when it ends or is discarded.
    func setRecordingMeetingID(_ id: UUID?) {
        recordingMeetingID = id
    }

    /// Patches `title` + `summary` for an existing meeting. Only those two
    /// fields are sent in the payload — other columns (started_at, etc.)
    /// stay untouched even though the local Meeting carries them. Local
    /// cache is replaced on success so MainWindowView re-renders without a
    /// full refresh.
    func update(_ meeting: Meeting) async throws {
        Log.ui.info("MeetingStore.update id=\(meeting.id.uuidString)")
        #if DEBUG
            if DemoMode.isEnabled {
                if let idx = meetings.firstIndex(where: { $0.id == meeting.id }) {
                    meetings[idx] = meeting
                }
                return
            }
        #endif

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

    /// Local mirrors of a soft delete / restore, until the next refresh brings
    /// the server-stamped timestamp.
    private func trashed(_ meeting: Meeting) -> Meeting {
        var copy = meeting
        copy.deletedAt = Date()
        return copy
    }

    private func restored(_ meeting: Meeting) -> Meeting {
        var copy = meeting
        copy.deletedAt = nil
        return copy
    }

    /// Patches only `speaker_names`, for the late-relabel path.
    ///
    /// A meeting whose clustering finished inside the join timeout carries its
    /// names on the insert instead — they are resolved before the recap, so they
    /// exist by the time the row is written. This is the other case: clustering
    /// overran, the row landed unnamed minutes ago, and the names can only be
    /// patched in.
    /// Point a session at a calendar entry, by hand.
    ///
    /// The automatic path is the server's: `_stamp_lease_identity` derives the
    /// identity from a device lease and its value always beats a client's. This
    /// writes the one case that leaves — a session the lease never identified,
    /// which is exactly the session a person is looking at when they reach for
    /// a picker. Where the server knows better it keeps knowing better, and the
    /// pick is quietly ignored rather than fought over.
    func link(_ meetingID: UUID, toCalendarEvent externalID: String?) async throws {
        Log.ui.info("MeetingStore.link id=\(meetingID.uuidString) event=\(externalID != nil)")
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        struct Patch: Encodable {
            let icalUID: String?

            enum CodingKeys: String, CodingKey {
                case icalUID = "ical_uid"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                if let icalUID {
                    try container.encode(icalUID, forKey: .icalUID)
                } else {
                    try container.encodeNil(forKey: .icalUID)
                }
            }
        }
        try await supabase
            .from(Self.tableName)
            .update(Patch(icalUID: externalID))
            .eq("id", value: meetingID.uuidString)
            .execute()

        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[index].icalUID = externalID
        }
    }

    func updateSpeakerNames(_ names: [String: String], for meetingID: UUID) async throws {
        guard !names.isEmpty else { return }
        Log.ui.info("MeetingStore.updateSpeakerNames id=\(meetingID.uuidString) count=\(names.count)")
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif

        struct Patch: Encodable {
            let speakerNames: [String: String]

            enum CodingKeys: String, CodingKey {
                case speakerNames = "speaker_names"
            }
        }
        try await supabase
            .from(Self.tableName)
            .update(Patch(speakerNames: names))
            .eq("id", value: meetingID.uuidString)
            .execute()

        if let idx = meetings.firstIndex(where: { $0.id == meetingID }) {
            meetings[idx].speakerNames = names
        }
    }

    /// Records which voice was whose, beside the names the transcript draws.
    ///
    /// Best-effort and never in anybody's way: the meeting, its transcript and
    /// its names are already saved by the time this runs, and a failure costs
    /// the ability to assign work to a speaker later — not anything the user is
    /// currently looking at. Throwing here would turn a bookkeeping problem into
    /// a visible one.
    func recordSpeakers(_ speakers: [MeetingSpeaker], for meetingID: UUID) async {
        guard !speakers.isEmpty else { return }
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif

        struct Row: Encodable {
            let meetingID: UUID
            let cluster: Int
            let personID: UUID?
            let displayName: String?
            let confidence: Double
            let decidedBy: String

            enum CodingKeys: String, CodingKey {
                case meetingID = "meeting_id"
                case cluster
                case personID = "person_id"
                case displayName = "display_name"
                case confidence
                case decidedBy = "decided_by"
            }
        }

        do {
            try await supabase
                .from(Self.speakersTableName)
                .upsert(
                    speakers.map {
                        Row(
                            meetingID: meetingID,
                            cluster: $0.cluster,
                            personID: $0.personID,
                            displayName: $0.displayName,
                            confidence: $0.confidence,
                            decidedBy: $0.decidedBy.rawValue
                        )
                    },
                    onConflict: "meeting_id,cluster"
                )
                .execute()
            Log.stt.info("diarization: recorded \(speakers.count) speaker attribution(s)")
        } catch {
            Log.stt.error("diarization: recording speakers failed — \(error.localizedDescription)")
        }
    }

    func speakers(forMeeting meetingID: UUID) async -> [MeetingSpeaker] {
        #if DEBUG
            if DemoMode.isEnabled { return [] }
        #endif
        do {
            return try await supabase
                .from(Self.speakersTableName)
                .select("cluster, person_id, display_name, confidence, decided_by")
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
                .value
        } catch {
            Log.ui.error("MeetingStore.speakers failed: \(error.localizedDescription)")
            return []
        }
    }

    /// The user answering "who was that".
    ///
    /// Goes through `confirm_speaker` rather than two writes, because the
    /// structured row and the `speaker_names` map the transcript reads have to
    /// move together — the server does both or neither. Passing no person
    /// clears the naming entirely.
    func confirmSpeaker(
        cluster: Int,
        personID: UUID?,
        name: String?,
        for meetingID: UUID
    ) async -> Bool {
        #if DEBUG
            if DemoMode.isEnabled { return false }
        #endif
        struct Params: Encodable {
            let p_meeting: UUID
            let p_cluster: Int
            let p_person: UUID?
            let p_name: String?
        }
        do {
            _ = try await supabase
                .rpc(
                    "confirm_speaker",
                    params: Params(p_meeting: meetingID, p_cluster: cluster, p_person: personID, p_name: name)
                )
                .execute()
            // Mirrors what the function just did to the row, so the transcript
            // relabels without a refetch.
            if let idx = meetings.firstIndex(where: { $0.id == meetingID }) {
                var names = meetings[idx].speakerNames ?? [:]
                if let name, !name.isEmpty {
                    names["\(cluster)"] = name
                } else {
                    names.removeValue(forKey: "\(cluster)")
                }
                meetings[idx].speakerNames = names.isEmpty ? nil : names
            }
            Log.ui.info("speaker confirmed cluster=\(cluster) meeting=\(meetingID.uuidString)")
            return true
        } catch {
            Log.ui.error("MeetingStore.confirmSpeaker failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Recently-ended meetings whose recap never landed, for the launch retry.
    /// `recap_json IS NULL` narrows the scan server-side; the caller still has
    /// to match the placeholder summaries, because a meeting streamed
    /// mid-recording is also recap-less and must be left alone.
    func fetchMeetingsMissingRecap(since: Date, limit: Int) async throws -> [Meeting] {
        #if DEBUG
            if DemoMode.isEnabled { return [] }
        #endif
        return try await supabase
            .from(Self.tableName)
            .select()
            .is("recap_json", value: nil)
            .is("deleted_at", value: nil)
            .is("merged_into", value: nil)
            .gte("ended_at", value: ISO8601DateFormatter().string(from: since))
            .order("ended_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    // MARK: - Transcripts

    /// Insert-or-update transcript rows. The streaming / outbox path re-sends a
    /// slot (e.g. a re-transcription or dedup swap reissues `(meeting_id, idx)`
    /// under a fresh `id`), so the conflict target must be the `(meeting_id,
    /// idx)` unique index — the default PK (`id`) target misses the reissued
    /// row and Postgres rejects it on `meeting_transcripts_meeting_id_idx_key`,
    /// stranding the meeting as "saved on this device only" forever. The batch
    /// is also collapsed to one row per slot first: it's keyed by `id` upstream,
    /// so it may carry two rows for the same `idx`, which a single multipart
    /// upsert can't touch twice. Falls back to dropping the diarization
    /// `speaker` labels if that column hasn't been migrated to this environment
    /// yet (they backfill once it exists), rather than losing the transcript.
    func upsertTranscript(_ records: [TranscriptRecord]) async throws {
        guard !records.isEmpty else { return }
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        let deduped = Self.collapseByIdx(records)
        Log.ui.info("MeetingStore.upsertTranscript meeting=\(deduped[0].meetingID.uuidString) count=\(deduped.count)")
        do {
            try await supabase
                .from(Self.transcriptsTableName)
                .upsert(deduped, onConflict: "meeting_id,idx")
                .execute()
        } catch {
            guard Self.isMissingSpeakerColumn(error) else { throw error }
            Log.ui.error("upsertTranscript: 'speaker' column absent — retrying without diarization labels")
            try await supabase
                .from(Self.transcriptsTableName)
                .upsert(deduped.map { $0.droppingSpeaker() }, onConflict: "meeting_id,idx")
                .execute()
        }
    }

    /// What a listener's Notes read while this meeting is being recorded.
    ///
    /// Unconditional rather than gated on somebody actually listening, for the
    /// same reason `upsertTranscript` is: the transcript already streams up
    /// during the call whether or not anyone reads it, so a finding is not a new
    /// category of thing to be holding. Gating would mean this object knowing
    /// about `RoomListenerService`, and a race the first listener always loses.
    ///
    /// Every finding, not just the one that changed. The cost is a few kilobytes
    /// an hour, and it buys the property that matters here: because this call
    /// swallows its own failures, each successful write repairs every write that
    /// silently failed before it. A delta would leave a dropped finding missing
    /// from the listener's Notes for the rest of the meeting.
    ///
    /// Best-effort, and silent on failure by design. A listener's Notes going
    /// blank is a worse outcome than nothing only for the listener; the person
    /// recording must not lose so much as a log line's worth of attention over
    /// it, and an environment without the table — it arrives with
    /// `20260816260000` — simply has nothing to show.
    func mirrorLiveFindings(_ findings: [LiveFinding]) async {
        guard let meetingID = recordingMeetingID, !findings.isEmpty else { return }
        #if DEBUG
            if DemoMode.isEnabled { return }
        #endif
        do {
            try await supabase
                .from(Self.liveFindingsTableName)
                .upsert(
                    findings.map { LiveFindingRow($0, meetingID: meetingID) },
                    onConflict: "meeting_id,id"
                )
                .execute()
        } catch {
            Log.ui.error("MeetingStore.mirrorLiveFindings failed: \(error.localizedDescription)")
        }
    }

    /// Keep one row per `(meetingID, idx)`, last wins — the freshest text after
    /// a re-transcription / dedup swap reissues a slot under a new `id`.
    private static func collapseByIdx(_ records: [TranscriptRecord]) -> [TranscriptRecord] {
        var byKey: [String: TranscriptRecord] = [:]
        for record in records {
            byKey["\(record.meetingID.uuidString)-\(record.idx)"] = record
        }
        return byKey.values.sorted { $0.idx < $1.idx }
    }

    /// PostgREST reports an unknown column as PGRST204 with a message naming it
    /// ("Could not find the 'speaker' column … in the schema cache"). Match on
    /// the column name so an unrelated failure still propagates.
    private static func isMissingSpeakerColumn(_ error: Error) -> Bool {
        let text = String(describing: error).lowercased()
        return text.contains("speaker") && text.contains("column")
    }

    /// Loads the full transcript for one meeting, ordered chronologically.
    /// Used by MeetingDetailView's Transcript tab — lazy, only runs when
    /// the tab is first opened.
    func fetchTranscript(meetingID: UUID) async throws -> [TranscriptRecord] {
        #if DEBUG
            if DemoMode.isEnabled { return DemoData.transcript(for: meetingID) }
        #endif
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
    /// `share.hellonod.app`. Debug builds default to the local Vite dev server
    /// (`http://localhost:5173`) so a share link opens the viewer you're
    /// editing; Release always points at production. Either default can be
    /// overridden per-device via the `share.viewerBaseURL` UserDefaults key
    /// (same pattern as the `openrouter.model` / `whisper.model` overrides).
    private static let shareViewerBaseURLKey = "share.viewerBaseURL"

    private static let defaultShareViewerBaseURL: String = {
        #if DEBUG
            return "http://localhost:5173"
        #else
            return "https://share.hellonod.app"
        #endif
    }()

    private static var shareViewerBaseURL: String {
        UserDefaults.standard.string(forKey: shareViewerBaseURLKey) ?? defaultShareViewerBaseURL
    }

    /// Creates (or reuses) a public share link for a meeting and returns the
    /// viewer URL to drop on the clipboard.
    ///
    /// Privacy-by-default: nothing is shared until this is called. The
    /// `create_meeting_share` RPC verifies ownership server-side, mints an
    /// opaque token (reusing the meeting's existing live share if there is
    /// one — so the same meeting always yields a stable link), and the viewer
    /// reads only the summary back through that token. The link is revocable.
    /// Tells the server this recording is still running.
    ///
    /// On the session's own clock rather than on the transcript's: chunks only
    /// exist while somebody is speaking, and a meeting is no less live for a
    /// quiet stretch. See `touch_meeting_lease`.
    func touchLease(meetingID: UUID) async {
        struct Params: Encodable { let p_meeting: UUID }
        do {
            _ = try await supabase
                .rpc("touch_meeting_lease", params: Params(p_meeting: meetingID))
                .execute()
        } catch {
            // Best-effort: a missed beat costs the room a moment of visibility,
            // never the recording.
            Log.ui.error("lease heartbeat failed: \(error.localizedDescription)")
        }
    }

    /// Somebody else in the organization recorded the same meeting.
    ///
    /// Both sides keep their own recording — two microphones hear different
    /// halves of a room, and neither copy is the canonical one. This only asks
    /// the question; `merge(_:into:)` is what a person answering it calls.
    func sameMeetingCandidates(for meetingID: UUID) async -> [SameMeeting] {
        guard !isSomebodyElses(meetingID) else { return [] }
        async let mine = matches(from: "my_earlier_recording", for: meetingID)
        async let others = matches(from: "same_meeting_in_org", for: meetingID)
        // Your own first: rejoining a call is the commoner event and the more
        // confusing one to find filed as two meetings.
        return await mine.map { var match = $0; match.isMine = true; return match } + others
    }

    /// Whether this session is known to belong to somebody else.
    ///
    /// Both matchers anchor on a recording of the caller's own — they answer
    /// "is anyone else holding the meeting *I* recorded" — and raise `that
    /// meeting is not yours` for anything else. A session shared by a colleague
    /// therefore logged two authorization errors every time it was opened, for
    /// a question that could not have applied to it.
    ///
    /// Only when we positively know. A meeting missing from the local list is
    /// asked about as before and the server decides; guessing "not mine" from
    /// an incomplete list would switch the feature off on real sessions.
    private func isSomebodyElses(_ meetingID: UUID) -> Bool {
        guard let owner = meetings.first(where: { $0.id == meetingID })?.userID,
              let me = supabase.auth.currentSession?.user.id
        else { return false }
        return owner != me
    }

    private func matches(from rpc: String, for meetingID: UUID) async -> [SameMeeting] {
        struct Params: Encodable { let p_meeting: UUID }
        do {
            return try await supabase
                .rpc(rpc, params: Params(p_meeting: meetingID))
                .execute()
                .value
        } catch {
            Log.ui.error("\(rpc) failed: \(error.localizedDescription)")
            return []
        }
    }

    func merge(_ source: UUID, into target: UUID) async throws {
        struct Params: Encodable {
            let p_source: UUID
            let p_target: UUID
        }
        try await supabase
            .rpc("merge_meeting", params: Params(p_source: source, p_target: target))
            .execute()
    }

    func createShareURL(for meeting: Meeting) async throws -> URL {
        Log.ui.info("MeetingStore.createShareURL meeting=\(meeting.id.uuidString)")
        #if DEBUG
            if DemoMode.isEnabled {
                let token = UUID().uuidString.lowercased()
                guard let url = URL(string: "\(Self.shareViewerBaseURL)/share/\(token)") else {
                    throw URLError(.badURL)
                }
                return url
            }
        #endif
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
        analytics?.record(.meetingShared, properties: .init(surface: .share, detail: .link))
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
        #if DEBUG
            if DemoMode.isEnabled {
                meetings.removeAll { $0.id == meeting.id }
                if case .loaded = trashState {
                    trashedMeetings.insert(trashed(meeting), at: 0)
                }
                pendingUndo = meeting
                onTrashChange.fire()
                return
            }
        #endif
        struct Params: Encodable {
            let meeting_id: UUID
        }
        // Refused here as well as by the server. `soft_delete_meeting` now says
        // so rather than reporting success on zero rows, but the optimistic
        // removal below would still take the row off screen for the length of a
        // round trip — a flinch on a session that was never going to move.
        guard !isSharedWithMe(meeting) else { throw DeleteError.notYours }

        // Off the list before the call, and back on it if the call fails. The
        // row is the subject of the gesture, so the round trip is the one delay
        // there is no hiding.
        //
        // One row each way, never a snapshot of the whole array: an access poke
        // can complete a full `refresh` during the await, and restoring a list
        // captured before it would revert every unrelated row that arrived or
        // left in the meantime.
        let wasListed = meetings.contains { $0.id == meeting.id }
        meetings.removeAll { $0.id == meeting.id }
        if case .loaded = trashState {
            // The trash-list copy carries a client-side `deletedAt` for
            // the "trashed Xd ago" badge until the next refreshTrash
            // overwrites with the server-stamped value.
            trashedMeetings.insert(trashed(meeting), at: 0)
        }
        do {
            try await supabase
                .rpc("soft_delete_meeting", params: Params(meeting_id: meeting.id))
                .execute()
        } catch {
            trashedMeetings.removeAll { $0.id == meeting.id }
            if wasListed, !meetings.contains(where: { $0.id == meeting.id }) {
                meetings.append(meeting)
                meetings.sort { $0.startedAt > $1.startedAt }
            }
            throw error
        }

        pendingUndo = meeting
        onTrashChange.fire()
    }

    /// Restore — calls the `restore_meeting` RPC; row returns to
    /// `meetings`. Symmetric with `softDelete` so any future audit /
    /// logging hook lives server-side. The local cache copy is rebuilt
    /// with `deletedAt: nil` so callers reading the field don't see a
    /// stale trash timestamp on a row that's now live.
    func restore(_ id: UUID) async throws {
        Log.ui.info("MeetingStore.restore id=\(id.uuidString)")
        #if DEBUG
            if DemoMode.isEnabled {
                if let idx = trashedMeetings.firstIndex(where: { $0.id == id }) {
                    let row = trashedMeetings.remove(at: idx)
                    meetings.insert(restored(row), at: 0)
                    meetings.sort { $0.startedAt > $1.startedAt }
                }
                if pendingUndo?.id == id { pendingUndo = nil }
                onTrashChange.fire()
                return
            }
        #endif
        struct Params: Encodable {
            let meeting_id: UUID
        }
        try await supabase
            .rpc("restore_meeting", params: Params(meeting_id: id))
            .execute()

        if let idx = trashedMeetings.firstIndex(where: { $0.id == id }) {
            let row = trashedMeetings.remove(at: idx)
            if case .loaded = loadState {
                meetings.insert(restored(row), at: 0)
                meetings.sort { $0.startedAt > $1.startedAt }
            }
        }
        if pendingUndo?.id == id { pendingUndo = nil }
        onTrashChange.fire()
    }

    /// Somebody else's session, reached through a folder they shared. Readable,
    /// never writable — the row-level policies on `meetings` scope both UPDATE
    /// and DELETE to the owner, so every write path here refuses the same way.
    enum DeleteError: LocalizedError {
        case notYours

        var errorDescription: String? {
            "This session belongs to whoever recorded it. Only they can delete it."
        }
    }

    enum HardDeleteError: Error {
        /// Refused because `id` is the meeting `recordingMeetingID` currently
        /// points at. Enforced here, not only by the UI that disables "Delete
        /// Forever" for it — a client-side-only guard doesn't stop every call
        /// site that will ever exist, and losing an in-progress recording this
        /// way already happened once (Sessions couldn't tell it apart from an
        /// old, still-blank draft sitting in the same list).
        case recordingInProgress
    }

    /// Hard delete — removes the row from the table outright. Used by
    /// "Delete Forever" + the nightly pg_cron purge.
    func hardDelete(_ id: UUID) async throws {
        guard id != recordingMeetingID else { throw HardDeleteError.recordingInProgress }
        if let meeting = meetings.first(where: { $0.id == id }) ?? trashedMeetings.first(where: { $0.id == id }),
           isSharedWithMe(meeting) {
            throw DeleteError.notYours
        }
        Log.ui.info("MeetingStore.hardDelete id=\(id.uuidString)")
        #if DEBUG
            if DemoMode.isEnabled {
                meetings.removeAll { $0.id == id }
                trashedMeetings.removeAll { $0.id == id }
                if pendingUndo?.id == id { pendingUndo = nil }
                onTrashChange.fire()
                return
            }
        #endif
        try await supabase
            .from(Self.tableName)
            .delete()
            .eq("id", value: id.uuidString)
            .execute()

        meetings.removeAll { $0.id == id }
        trashedMeetings.removeAll { $0.id == id }
        if pendingUndo?.id == id { pendingUndo = nil }
        onTrashChange.fire()
    }

    /// The nightly purge, run now, for this account only. The server filters
    /// by `deleted_at` rather than by the rows this client happens to have
    /// loaded, so a session trashed on another device goes with the rest.
    func emptyTrash() async throws {
        Log.ui.info("MeetingStore.emptyTrash loaded=\(trashedMeetings.count)")
        #if DEBUG
            if DemoMode.isEnabled {
                trashedMeetings.removeAll { $0.id != recordingMeetingID }
                if pendingUndo?.id != recordingMeetingID { pendingUndo = nil }
                onTrashChange.fire()
                return
            }
        #endif
        var query = supabase
            .from(Self.tableName)
            .delete(returning: .minimal)
            .not("deleted_at", operator: .is, value: "null")
        if let recordingMeetingID {
            query = query.neq("id", value: recordingMeetingID.uuidString)
        }
        try await query.execute()

        trashedMeetings.removeAll { $0.id != recordingMeetingID }
        if pendingUndo?.id != recordingMeetingID { pendingUndo = nil }
        onTrashChange.fire()
        // A silent fetch started before the delete can land after it and put
        // the rows back; queueing behind it reads the post-delete state.
        await refreshTrash(silent: true)
    }

    /// Dismiss the Undo toast without acting on it (user clicked the X
    /// or the 5s window elapsed). The meeting stays in Trash.
    func dismissUndo() {
        pendingUndo = nil
    }

    /// Fetches the user's soft-deleted meetings, newest-trashed first.
    /// Lazy — only runs when the Trash segment is opened.
    ///
    /// `silent` is for the refreshes nobody asked for: an access poke saying
    /// another device trashed something. Those must not flip to `.loading`,
    /// which would swap the list somebody is reading for a spinner, and must not
    /// flip to `.failed`, which would replace it with an error screen over a
    /// dropped packet. A refresh the user pressed a button for keeps both.
    func refreshTrash(silent: Bool = false) async {
        #if DEBUG
            if DemoMode.isEnabled {
                trashState = .loaded
                return
            }
        #endif
        // Its own flag rather than `trashState`: a silent refresh leaves the
        // state on `.loaded` for its whole duration, so a state-based guard
        // would let every concurrent call through and let the slowest response
        // win over a newer one.
        if isFetchingTrash {
            refetchTrashRequested = true
            // The queued run takes the *loudest* intent of everyone waiting: a
            // reload somebody pressed, queued behind a poke's silent refresh,
            // has to be allowed to show them that it failed.
            queuedTrashIsSilent = queuedTrashIsSilent && silent
            Log.ui.info("MeetingStore.refreshTrash queued behind the one in flight")
            return
        }
        isFetchingTrash = true
        defer { isFetchingTrash = false }
        var quietRun = silent
        repeat {
            refetchTrashRequested = false
            queuedTrashIsSilent = true
            await fetchTrash(silent: quietRun)
            quietRun = queuedTrashIsSilent
        } while refetchTrashRequested
    }

    private func fetchTrash(silent: Bool) async {
        let quiet = silent && { if case .loaded = trashState { true } else { false } }()
        Log.ui.info("MeetingStore.refreshTrash starting (silent=\(quiet))")
        if !quiet { trashState = .loading }
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
            if !quiet { trashState = .failed(error.localizedDescription) }
        }
    }

    /// The trash, but only for somebody who is looking at it.
    ///
    /// A session trashed on another device lands here rather than in `meetings`,
    /// so the access poke has to re-ask for both — and re-asking for a pane
    /// nobody has opened would spend a round trip to fill a cache that
    /// `refreshTrash` fills on arrival anyway.
    /// Gives a brand-new account one session to open.
    ///
    /// Asked of the server, which is the only thing that can answer it: it
    /// seeds only into an account that has never had a session — deleted ones
    /// included — so two Macs signing in the same morning produce one sample,
    /// and somebody who cleared their list is not handed it back.
    ///
    /// Once per launch. The guard is the server's, and this one only stops an
    /// account that genuinely has nothing from spending a round trip on every
    /// silent refresh.
    private func seedWelcomeSessionIfNeeded() async {
        guard meetings.isEmpty, !hasAskedForWelcomeSession else { return }
        hasAskedForWelcomeSession = true
        do {
            let seeded: UUID? = try await supabase
                .rpc("seed_welcome_session")
                .execute()
                .value
            guard let seeded else { return }
            Log.ui.info("MeetingStore seeded welcome session \(seeded.uuidString)")
            // Re-read rather than composing the row here: what the server wrote
            // is what every other surface will read, and a client-built copy of
            // it would be a second answer to the same question.
            await refresh(force: true)
        } catch {
            // A first launch with no sample is a worse empty state, not a
            // broken one — and the next launch asks again.
            Log.ui.error("MeetingStore.seedWelcomeSession failed: \(error.localizedDescription)")
        }
    }

    func refreshTrashIfLoaded() async {
        guard case .loaded = trashState else { return }
        await refreshTrash(silent: true)
    }

    /// Server rows plus any local drafts still mid-generation — they aren't
    /// on the server yet, so a naive `meetings = rows` would yank the row out
    /// from under MeetingDetailView while it renders the loading placeholder.
    ///
    /// `localAuthoritative` is the override for meetings still pending in the
    /// outbox: unlike `drafts` (where a present server row wins, since it's the
    /// confirmed version), these local copies REPLACE the matching server row
    /// and are appended if the server doesn't have them — the on-disk recap is
    /// truth until the completion push confirms otherwise.
    static func merging(
        rows: [Meeting],
        drafts: [Meeting],
        localAuthoritative: [UUID: Meeting] = [:]
    ) -> [Meeting] {
        var merged = rows
        var indexByID = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for draft in drafts {
            // A generating meeting is live-streamed to the server mid-recording
            // with `ended_at == started_at`, so its row may already be here with
            // a 0:00 duration. Splice the draft's accurate bookends onto that row
            // — but keep the server row's content, so an empty draft can't wipe a
            // summary that already landed (only `localAuthoritative` replaces
            // content). When the row is absent, keep the draft outright.
            if let idx = indexByID[draft.id] {
                merged[idx] = merged[idx].withBookends(from: draft)
            } else {
                indexByID[draft.id] = merged.count
                merged.append(draft)
            }
        }
        if !localAuthoritative.isEmpty {
            var present: Set<UUID> = []
            for i in merged.indices {
                if let local = localAuthoritative[merged[i].id] {
                    merged[i] = local
                    present.insert(local.id)
                }
            }
            for (id, local) in localAuthoritative where !present.contains(id) {
                merged.append(local)
            }
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
        finalizingMeetingIDs = []
        unsyncedMeetingIDs = []
        hiddenMeetingIDs = []
        streamingSummaries = [:]
    }

    // MARK: - Read

    /// Fetches the current user's non-deleted meetings, newest first. RLS
    /// makes the WHERE-on-user-id implicit — the server only returns rows
    /// that match the JWT.
    /// `force` bypasses the 30s throttle but never the in-flight guard.
    /// Use `force: true` for explicit user-initiated retries (toolbar
    /// reload button, "Couldn't sync" warning chip); leave the default
    /// for `.task`-driven auto-refreshes that should be throttled.
    ///
    /// A call arriving mid-fetch is queued rather than dropped — the query
    /// already running was issued before whatever the new call needs to see.
    func refresh(force: Bool = false) async {
        #if DEBUG
            if DemoMode.isEnabled {
                if meetings.isEmpty { meetings = DemoData.meetings }
                loadState = .loaded
                lastRefreshFailed = false
                lastSuccessfulFetchAt = Date()
                return
            }
        #endif

        // Unconditional in-flight guard. Covers both initial fetch
        // (loadState would flip to .loading and the old check caught
        // those) AND silent refresh (loadState stays .loaded and the
        // old check would have let concurrent calls through).
        if isFetching {
            // Remembered, not dropped — but only when the caller asked for it.
            // The query already running was issued before the change a `force`
            // caller is here to see (an access poke, a manual retry), so
            // answering it with "a fetch is in flight" leaves the deleted row on
            // screen until something else happens to ask again. A `.task`
            // re-firing on a navigation pop wants no such thing; it is the
            // caller the 30-second throttle exists for, and queueing it would
            // spend a second 500-row round trip to learn nothing.
            if force { refetchRequested = true }
            Log.ui.info("MeetingStore.refresh in flight (queued=\(force))")
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
        repeat {
            refetchRequested = false
            await fetchMeetings()
        } while refetchRequested
    }

    private func fetchMeetings() async {
        let hadLoadedCache = if case .loaded = loadState { true } else { false }

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
                // A recording filed into another one is no longer a meeting of
                // its own. The transcript stays readable under the row it was
                // captured in; the list shows the meeting, not the recordings.
                .is("merged_into", value: nil)
                .order("started_at", ascending: false)
                .limit(500)
                .execute()
                .value
            let localOnlyIDs = generatingSummaryIDs.union(finalizingMeetingIDs)
            let drafts = meetings.filter { localOnlyIDs.contains($0.id) }
            let authoritative = Dictionary(
                meetings.filter { unsyncedMeetingIDs.contains($0.id) }.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let previousIDs = Set(meetings.map(\.id))
            meetings = Self.merging(rows: rows, drafts: drafts, localAuthoritative: authoritative)
            // A session that vanished between two refreshes was trashed or
            // unshared somewhere else, and the retrieval cache is keyed only on
            // query text — it cannot notice that by itself, and would go on
            // answering out of a session this account can no longer read.
            if !previousIDs.isSubset(of: Set(meetings.map(\.id))) {
                onTrashChange.fire()
            }
            loadState = .loaded
            lastSuccessfulFetchAt = Date()
            lastRefreshFailed = false
            Log.ui.info("MeetingStore.refresh loaded \(rows.count) meetings (+ \(drafts.count) drafts)")
            await seedWelcomeSessionIfNeeded()
        } catch {
            if hadLoadedCache {
                Log.ui.error("MeetingStore.refresh failed (keeping cache): \(error.localizedDescription)")
                // Keep loadState = .loaded so the cached list stays
                // rendered, but raise lastRefreshFailed so MainWindowView
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

/// A colleague recording the meeting you just started recording.
///
/// Reported, never enforced. Two people wanting their own notes from one
/// conversation is a legitimate thing to want, and the only thing Nod is in a
/// position to add is that they know about each other.
struct ConcurrentRecording: Equatable, Decodable {
    let ownerName: String
    let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case ownerName = "owner_name"
        case startedAt = "started_at"
    }
}

extension MeetingStore {
    /// Whether somebody in the same organization is already recording this
    /// meeting, as the server sees it.
    ///
    /// Answers nil for everyone the question cannot apply to — no organization,
    /// no calendar connected, nothing identifying the meeting — which is most
    /// recordings, so this stays quiet rather than explaining itself.
    func concurrentRecording(for meetingID: UUID) async -> ConcurrentRecording? {
        struct Params: Encodable {
            let p_meeting: UUID
        }
        do {
            let rows: [ConcurrentRecording] = try await supabase
                .rpc("concurrent_recording", params: Params(p_meeting: meetingID))
                .execute()
                .value
            return rows.first
        } catch {
            // A question nobody asked for. Failing it is not worth a toast.
            Log.ui.error("MeetingStore.concurrentRecording failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Offers the on-device calendar's view of which meeting this is.
    ///
    /// Sends the invitation's own identifier and its join link as written; the
    /// server derives the room key, so the two calendar sources cannot reduce
    /// one Zoom link to two different rooms. Ignored when the server already
    /// identified the meeting from a connected calendar.
    func offerLeaseIdentity(meetingID: UUID, externalID: String?, conferenceURL: URL?) async {
        guard externalID != nil || conferenceURL != nil else { return }
        struct Params: Encodable {
            let p_meeting: UUID
            let p_ical_uid: String?
            let p_conference_url: String?
        }
        do {
            _ = try await supabase
                .rpc("set_lease_identity", params: Params(
                    p_meeting: meetingID,
                    p_ical_uid: externalID,
                    p_conference_url: conferenceURL?.absoluteString
                ))
                .execute()
        } catch {
            Log.ui.error("MeetingStore.offerLeaseIdentity failed: \(error.localizedDescription)")
        }
    }
}
