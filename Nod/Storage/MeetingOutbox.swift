import Foundation

/// The two Supabase writes the outbox needs, abstracted so the persistence /
/// retry logic can be unit-tested against a fake instead of a live network.
/// `MeetingStore` is the production conformance.
protocol MeetingRemoteWriter: Sendable {
    func upsert(_ meeting: Meeting) async throws
    func upsertTranscript(_ records: [TranscriptRecord]) async throws
}

extension MeetingStore: MeetingRemoteWriter {}

/// One meeting that hasn't fully landed on the server yet — the durable,
/// on-disk counterpart to `MeetingStore`'s RAM-only cache.
///
/// Background: meetings were held only in memory until a *successful* Supabase
/// insert at the very tail of the end-of-meeting flow (after summary + title +
/// diarization). A long meeting whose recap was already shown could be lost if
/// the insert failed or the user quit / updated the app before it ran — the
/// only server trace was anonymous usage meters. This is the WAL that closes
/// that gap: the transcript is appended here as it's captured, and the finished
/// summary is stamped here before (and independently of) the network write.
///
/// Sync bookkeeping (`meetingSynced`, `syncedTranscriptIDs`) is in-memory only:
/// every server write is an idempotent upsert, so losing it on a crash just
/// means recovery re-pushes once — never a duplicate or a loss.
struct OutboxEntry {
    enum State: String, Codable {
        /// In progress, or interrupted before End — the summary may be absent.
        case recording
        /// Ended + summarised; it only needs to reach the server.
        case completed
    }

    var meeting: Meeting
    var transcripts: [TranscriptRecord]
    var state: State
    /// True once the `meetings` row is confirmed on the server (transient).
    var meetingSynced: Bool
    /// Transcript ids confirmed on the server, so streaming pushes only the
    /// delta (transient).
    var syncedTranscriptIDs: Set<UUID>
    /// Transcript ids already written to the on-disk `.jsonl` log, so `record`
    /// appends only new lines instead of rewriting the file (transient).
    var persistedTranscriptIDs: Set<UUID>
}

/// Disk-backed write-ahead log + retry queue for meeting persistence.
///
/// Per meeting: a small `<id>.meta.json` (meeting + state, rewritten only on
/// begin / complete / recover) plus an append-only `<id>.jsonl` of transcript
/// records (appended as they settle — O(delta) per tick, not an O(n) full-file
/// rewrite). An `actor` so the live streaming loop, the end-of-meeting flush,
/// and the launch replay can't corrupt the files by racing.
actor MeetingOutbox {
    private let dir: URL
    private var entries: [UUID: OutboxEntry] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Serialises flushes: each `flush` chains behind the previous one and
    /// awaits its turn, so a caller always observes a real attempt at its own
    /// work instead of silently no-op'ing when another flush is mid-await.
    private var flushChain: Task<Void, Never>?

    /// Ids that were `.recording` when the files were loaded at process start —
    /// the only entries `recoverInterruptedMeetings` may promote. A recording
    /// begun during THIS process is never in this set, so a sign-in racing a
    /// fresh `beginRecording` can't promote a live recording to `.completed`.
    private var recordingIDsAtLaunch: Set<UUID> = []

    /// Shown in place of a real recap when an interrupted (never-ended) meeting
    /// is recovered on launch — the transcript is preserved even though the
    /// summary was never generated.
    static let recoveredPlaceholder =
        "⏳ Recovered from an interrupted session — the transcript was preserved, but a summary was never generated for it."

    /// `directory` is injectable so tests run against a temp dir, not the real
    /// Application Support location.
    init(directory: URL? = nil) {
        let resolved: URL
        if let directory {
            resolved = directory
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            resolved = base.appendingPathComponent("Nod/outbox", isDirectory: true)
        }
        dir = resolved
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - WAL mutations (driven live by MeetingSession)

    /// Register a meeting as recording. Idempotent: a no-op if an entry already
    /// exists, so the end-of-meeting "ensure" call can't wipe streamed progress.
    func begin(_ meeting: Meeting) {
        guard entries[meeting.id] == nil else { return }
        entries[meeting.id] = OutboxEntry(
            meeting: meeting,
            transcripts: [],
            state: .recording,
            meetingSynced: false,
            syncedTranscriptIDs: [],
            persistedTranscriptIDs: []
        )
        Log.ui.info("MeetingOutbox.begin id=\(meeting.id.uuidString)")
        writeMeta(meeting.id)
    }

    /// Merge settled transcript records into the WAL (by id, so a re-sent prefix
    /// is idempotent) and append only the not-yet-persisted ones to disk. No
    /// server I/O — call `flush` to push.
    func record(_ records: [TranscriptRecord], for id: UUID) {
        guard var entry = entries[id], !records.isEmpty else { return }
        var byID = Dictionary(entry.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for record in records {
            byID[record.id] = record
        }
        entry.transcripts = byID.values.sorted { $0.idx < $1.idx }
        for record in records where !entry.persistedTranscriptIDs.contains(record.id) {
            appendTranscriptLine(record, for: id)
            entry.persistedTranscriptIDs.insert(record.id)
        }
        entries[id] = entry
    }

    /// Stamp the final, summarised meeting. The transcript snapshot replaces the
    /// streamed rows; any row whose speaker label changed is un-synced so the
    /// completion push updates it on the server.
    func complete(_ meeting: Meeting, transcripts: [TranscriptRecord], for id: UUID) {
        var entry = entries[id] ?? OutboxEntry(
            meeting: meeting,
            transcripts: [],
            state: .completed,
            meetingSynced: false,
            syncedTranscriptIDs: [],
            persistedTranscriptIDs: []
        )
        let prior = Dictionary(entry.transcripts.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        var synced = entry.syncedTranscriptIDs
        for record in transcripts where prior[record.id]?.speaker != record.speaker {
            synced.remove(record.id)
        }
        entry.meeting = meeting
        entry.transcripts = transcripts
        entry.syncedTranscriptIDs = synced
        entry.state = .completed
        // Force a re-push of the row: during recording it may already have
        // landed with an empty summary, and skipping the upsert here (on a stale
        // `meetingSynced`) would leave that empty row on the server instead of
        // the real recap.
        entry.meetingSynced = false
        // Append the tail records not yet on disk (speaker-only updates to
        // already-persisted ids aren't re-written — the disk copy is a crash
        // backstop; the server gets speakers via the normal push / backfill).
        let tail = transcripts.filter { !entry.persistedTranscriptIDs.contains($0.id) }
        for record in tail {
            entry.persistedTranscriptIDs.insert(record.id)
        }
        entries[id] = entry
        for record in tail {
            appendTranscriptLine(record, for: id)
        }
        Log.ui.info("MeetingOutbox.complete id=\(id.uuidString) transcripts=\(transcripts.count)")
        writeMeta(id)
    }

    /// Drop an entry entirely — an empty start→stop, or a meeting the caller
    /// decided not to keep.
    func discard(_ id: UUID) {
        guard entries.removeValue(forKey: id) != nil else { return }
        removeFiles(id)
        Log.ui.info("MeetingOutbox.discard id=\(id.uuidString)")
    }

    /// Completed meetings for `userID` still waiting on the server — drives
    /// MeetingSession's retry toast. In-progress recordings are excluded (they
    /// legitimately sit in the WAL until End); other users' rows are excluded so
    /// the toast never blames the current user for a signed-out account's row.
    func pendingCompletedMeetings(for userID: UUID) -> [Meeting] {
        entries.values
            .filter { $0.state == .completed && $0.meeting.userID == userID }
            .map(\.meeting)
    }

    func isPending(_ id: UUID) -> Bool {
        entries[id] != nil
    }

    /// Promote any meeting still marked `.recording` on disk to a terminal,
    /// placeholder-summarised `.completed` entry (or drop it if nothing was
    /// captured). Safe ONLY at launch / sign-in, when no recording is in
    /// progress: a fresh process has no live recording, so a `.recording` entry
    /// can only be one interrupted by a crash / force-quit / app update. Without
    /// this an interrupted meeting would re-push forever and never reach a
    /// terminal state.
    func recoverInterruptedMeetings() {
        for (id, entry) in entries where entry.state == .recording && recordingIDsAtLaunch.contains(id) {
            guard !entry.transcripts.isEmpty else {
                discard(id)
                continue
            }
            var recovered = entry
            recovered.meeting = entry.meeting.updating(title: entry.meeting.title, summary: Self.recoveredPlaceholder)
            recovered.state = .completed
            recovered.meetingSynced = false // force a re-push so the placeholder lands
            entries[id] = recovered
            writeMeta(id)
            Log.ui.info("MeetingOutbox recovered interrupted meeting \(id.uuidString)")
        }
    }

    // MARK: - Server flush

    /// Push every pending entry for `userID` to Supabase through the writer.
    ///
    /// Serialised, not reentrancy-skipped: each call chains behind the previous
    /// flush and awaits its turn, so a caller (e.g. end-of-meeting `drainOutbox`)
    /// always observes a real attempt at its own work — a silent no-op used to
    /// leave a just-completed meeting unpushed and falsely "still pending".
    ///
    /// Scoped to `userID`: another account signed in on the same device must
    /// never push a signed-out user's rows (Supabase RLS would reject them under
    /// the new session, looping forever). Those rows stay on disk until their
    /// owner signs back in.
    func flush(using writer: any MeetingRemoteWriter, userID: UUID) async {
        let previous = flushChain
        let task = Task {
            await previous?.value
            await self.performFlush(using: writer, userID: userID)
        }
        flushChain = task
        await task.value
    }

    /// One flush pass. A meeting row is created only once it has at least one
    /// transcript (or is completed), so an empty start→stop never leaves an
    /// orphan row. Fully-synced completed entries are removed. State is re-read
    /// after every await so a concurrent `record`/`complete` is never clobbered.
    private func performFlush(using writer: any MeetingRemoteWriter, userID: UUID) async {
        for id in Array(entries.keys) {
            guard let entry = entries[id], entry.meeting.userID == userID else { continue }
            // Nothing worth a server row for an empty in-progress recording.
            if entry.state == .recording, entry.transcripts.isEmpty { continue }

            do {
                if entry.meetingSynced == false {
                    try await writer.upsert(entry.meeting)
                    entries[id]?.meetingSynced = true
                }

                if let current = entries[id] {
                    let unsynced = current.transcripts.filter { !current.syncedTranscriptIDs.contains($0.id) }
                    if !unsynced.isEmpty {
                        try await writer.upsertTranscript(unsynced)
                        entries[id]?.syncedTranscriptIDs.formUnion(unsynced.map(\.id))
                    }
                }

                if let current = entries[id],
                   current.state == .completed,
                   current.meetingSynced,
                   current.transcripts.allSatisfy({ current.syncedTranscriptIDs.contains($0.id) }) {
                    entries.removeValue(forKey: id)
                    removeFiles(id)
                }
            } catch {
                // Leave the entry on disk for the next flush (launch, focus,
                // manual retry). Durability is the whole point — never drop it.
                Log.ui.error("MeetingOutbox.flush kept \(id.uuidString) on disk — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Persistence

    private func metaURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).meta.json")
    }

    private func transcriptURL(_ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).jsonl")
    }

    private func writeMeta(_ id: UUID) {
        guard let entry = entries[id] else { return }
        do {
            let data = try encoder.encode(OutboxMeta(meeting: entry.meeting, state: entry.state))
            try data.write(to: metaURL(id), options: .atomic)
        } catch {
            Log.ui.error("MeetingOutbox.writeMeta failed for \(id.uuidString): \(error.localizedDescription)")
        }
    }

    private func appendTranscriptLine(_ record: TranscriptRecord, for id: UUID) {
        guard let data = try? encoder.encode(record) else { return }
        let url = transcriptURL(id)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))
        } else {
            try? (data + Data([0x0A])).write(to: url, options: .atomic)
        }
    }

    private func removeFiles(_ id: UUID) {
        try? FileManager.default.removeItem(at: metaURL(id))
        try? FileManager.default.removeItem(at: transcriptURL(id))
    }

    private func load() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        let suffix = ".meta.json"
        for metaFile in files where metaFile.lastPathComponent.hasSuffix(suffix) {
            let name = String(metaFile.lastPathComponent.dropLast(suffix.count))
            guard let id = UUID(uuidString: name),
                  let data = try? Data(contentsOf: metaFile),
                  let meta = try? decoder.decode(OutboxMeta.self, from: data) else { continue }

            var byID: [UUID: TranscriptRecord] = [:]
            if let text = try? String(contentsOf: transcriptURL(id), encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    if let rec = try? decoder.decode(TranscriptRecord.self, from: Data(line.utf8)) {
                        byID[rec.id] = rec // last-wins: a re-appended id reflects its latest form
                    }
                }
            }
            let transcripts = byID.values.sorted { $0.idx < $1.idx }
            entries[id] = OutboxEntry(
                meeting: meta.meeting,
                transcripts: transcripts,
                state: meta.state,
                meetingSynced: false,
                syncedTranscriptIDs: [],
                persistedTranscriptIDs: Set(transcripts.map(\.id))
            )
            if meta.state == .recording { recordingIDsAtLaunch.insert(id) }
        }
        if !entries.isEmpty {
            Log.ui.info("MeetingOutbox loaded \(entries.count) pending meeting(s) from disk")
        }
    }

    private struct OutboxMeta: Codable {
        var meeting: Meeting
        var state: OutboxEntry.State
    }
}
