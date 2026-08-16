import Foundation

/// Turning a pinned transcript snapshot into the two shapes the finalize needs:
/// rows for the database, and prompt text for the model.
///
/// Statics on purpose — a snapshot is the input, and nothing here may reach for
/// the live `TranscriptStore` the next recording is already resetting.
enum TranscriptSnapshot {
    /// Array-based counterpart to `TranscriptStore.fullContext`. `names` maps a
    /// cluster number to the person behind it, so a transcript handed to the
    /// recap reads `[Them · Andy]` rather than `[Them · Speaker 3]` — the recap
    /// can only write a name it was given one for.
    static func context(
        from entries: [TranscriptEntry],
        speakers: [UUID: Int] = [:],
        names: [String: String] = [:]
    ) -> String {
        entries.map { entry in
            // The `[Them]` prefix is load-bearing — every playbook rule in
            // `PromptLibrary` keys on it — so a resolved speaker narrows the
            // label rather than replacing it.
            let speaker = entry.segmentID.flatMap { speakers[$0] }
            let label = speaker.map { cluster in
                "\(entry.source.label) · \(names["\(cluster)"] ?? "Speaker \(cluster)")"
            } ?? entry.source.label
            return "[\(label)]: \(entry.text)"
        }
        .joined(separator: "\n")
    }

    /// `baseIdx` offsets the row `idx` so a streamed tail (entries
    /// `baseIdx..<n`) keeps the same global positions as the final full snapshot
    /// (`baseIdx: 0`), letting the two paths upsert the same rows by id.
    static func records(
        from entries: [TranscriptEntry],
        meeting: Meeting,
        baseIdx: Int = 0,
        speakers: [UUID: Int] = [:]
    ) -> [TranscriptRecord] {
        entries.enumerated().map { offset, entry in
            TranscriptRecord(
                id: entry.id,
                meetingID: meeting.id,
                userID: meeting.userID,
                createdAt: nil,
                source: entry.source.rawValue,
                text: entry.text,
                ts: entry.timestamp,
                idx: baseIdx + offset,
                speaker: entry.segmentID.flatMap { speakers[$0] }
            )
        }
    }
}

/// Everything a meeting gets once its recap exists: which cluster is which
/// person, to-dos, entities, and the embeddings that make it searchable.
///
/// All best-effort — the meeting is already saved by the time any of this runs,
/// and none of it can change what the user reads in the recap. Its own type
/// rather than more methods on `MeetingSession` because none of it touches the
/// recording lifecycle: give it a finished meeting and a transcript and it has
/// everything it needs.
@MainActor
final class MeetingEnrichment {
    private let llm: LLMProxyClient
    private let meetingStore: MeetingStore
    private let entityStore: EntityStore
    private let knowledgeStore: KnowledgeStore
    private let actionItemStore: ActionItemStore

    init(
        llm: LLMProxyClient,
        meetingStore: MeetingStore,
        entityStore: EntityStore,
        knowledgeStore: KnowledgeStore,
        actionItemStore: ActionItemStore
    ) {
        self.llm = llm
        self.meetingStore = meetingStore
        self.entityStore = entityStore
        self.knowledgeStore = knowledgeStore
        self.actionItemStore = actionItemStore
    }

    /// Which diarized cluster is which person, from the transcript's own
    /// evidence plus whatever the conferencing app's roster named.
    ///
    /// Best-effort by design, and an empty map is the expected answer for most
    /// meetings: unnamed clusters make the recap authorless, which is honest,
    /// while a guessed name ships a lie into something the user shares.
    func nameSpeakers(
        in transcript: String,
        people: MeetingParticipants,
        clusters: [Int]
    ) async -> [String: SpeakerAttribution] {
        guard !transcript.isEmpty else { return [:] }
        let (system, user) = PromptLibrary.buildSpeakerNaming(
            transcript: transcript,
            participants: people.names
        )
        var named: [String: String] = [:]
        do {
            let response = try await llm.completeJSON(system: system, user: user, as: NamedSpeakers.self)
            named = Self.namedSpeakers(in: response.speakers)
        } catch {
            // Not a return: the arithmetic below can still name a 1:1 outright,
            // and it is the case this pass fails on most often anyway.
            Log.ui.error("speaker naming failed (non-fatal): \(error.localizedDescription)")
        }
        let closed = MeetingParticipants.closingTheGap(named, clusters: clusters, people: people)
        if closed.count > named.count {
            Log.stt.info("diarization: closed the last cluster by elimination")
        }
        Log.stt.info("diarization: named \(closed.count) cluster(s) from \(people.names.count) roster name(s)")
        // A cluster the model never mentioned can only have arrived by
        // elimination, and the two are worth different amounts: one read the
        // conversation, the other counted what was left over.
        return closed.reduce(into: [String: SpeakerAttribution]()) { result, pair in
            result[pair.key] = SpeakerAttribution(
                name: pair.value,
                decidedBy: named[pair.key] == nil ? .elimination : .llm
            )
        }
    }

    /// Cluster→name pairs worth persisting: a positive cluster number and a
    /// non-empty name. Models occasionally answer with `{"1": ""}` or key the
    /// map by a person's name instead of the number, and neither can render.
    private static func namedSpeakers(in speakers: [String: String]?) -> [String: String] {
        guard let speakers else { return [:] }
        return speakers.reduce(into: [String: String]()) { result, pair in
            let name = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cluster = Int(pair.key), cluster > 0, !name.isEmpty else { return }
            result["\(cluster)"] = name
        }
    }

    /// Rewrites the already-persisted transcript rows once a slow clustering
    /// pass finishes. Rows are upserted by the same ids, so this updates them in
    /// place rather than duplicating the transcript.
    func applyLateSpeakers(
        from task: Task<[UUID: Int], Never>,
        entries: [TranscriptEntry],
        meeting: Meeting,
        people: MeetingParticipants
    ) async {
        defer { meetingStore.finishResolvingSpeakers(id: meeting.id) }
        let speakers = await task.value
        guard !speakers.isEmpty else { return }

        let records = TranscriptSnapshot.records(from: entries, meeting: meeting, speakers: speakers)
        do {
            try await meetingStore.upsertTranscript(records)
            Log.stt.info("diarization: relabelled \(records.count) transcript row(s) after the join timeout")
        } catch {
            // The transcript is already saved and readable; only the speaker
            // labels are missing, so a failure here is not worth surfacing.
            Log.stt.error("diarization: late relabel failed — \(error.localizedDescription)")
        }

        // The recap for this meeting was already written from an unclustered
        // transcript, so it names nobody — but the chips can still carry names,
        // and this is the only pass that can put them there. Patched rather than
        // written with the row, which landed long before clustering finished.
        let attributions = await nameSpeakers(
            in: TranscriptSnapshot.context(from: entries, speakers: speakers),
            people: people,
            clusters: Array(Set(speakers.values))
        )
        guard !attributions.isEmpty else { return }
        do {
            try await meetingStore.updateSpeakerNames(attributions.names, for: meeting.id)
        } catch {
            Log.ui.error("speaker naming failed (non-fatal): \(error.localizedDescription)")
        }
        await meetingStore.recordSpeakers(attributions.rows(), for: meeting.id)
    }

    /// To-dos, entities for "Related", and the embeddings that make the meeting
    /// findable. Runs only once the meeting has durably landed on the server —
    /// with the parent row missing these would FK-fail, waste an LLM + embedding
    /// call, and never re-run.
    func run(
        for meeting: Meeting,
        transcript: String,
        recap: MeetingRecap,
        participants: [String],
        live: [LiveFinding],
        speakers: [String: SpeakerAttribution] = [:]
    ) async -> [ActionItem] {
        // Written here rather than with the meeting row: `meeting_speakers`
        // points at it, and the point of this method is that the row has
        // durably landed.
        await meetingStore.recordSpeakers(speakers.rows(), for: meeting.id)
        // Only kinds that carry personal to-dos (meeting / voice note) —
        // passive media has none.
        var saved: [ActionItem] = []
        if meeting.kind.extractsActionItems {
            saved = await actionItemStore.saveExtracted(
                recap.actionItems,
                live: live,
                meetingID: meeting.id,
                userID: meeting.userID
            )
        }
        await extractEntities(
            meetingID: meeting.id,
            userID: meeting.userID,
            transcript: transcript,
            summary: meeting.summary,
            participants: participants
        )
        // Detached, and only after entities: indexing runs gte-small embeddings
        // inside the edge worker and is CPU-heavy enough to trip
        // WORKER_RESOURCE_LIMIT (HTTP 546) when it shares a worker instance with
        // the entity call. Nothing waits on it — least of all the transcript's
        // speaker chips, which are final by now.
        Task { await knowledgeStore.index(meetingID: meeting.id, transcript: transcript) }
        return saved
    }

    private func extractEntities(
        meetingID: UUID,
        userID: UUID,
        transcript: String,
        summary: String,
        participants: [String]
    ) async {
        guard !transcript.isEmpty else { return }
        let (system, user) = PromptLibrary.buildEntityExtraction(
            transcript: transcript,
            summary: summary,
            participants: participants
        )
        do {
            let extracted = try await llm.completeJSON(system: system, user: user, as: ExtractedEntities.self)
            guard !extracted.isEmpty else { return }
            try await entityStore.saveExtraction(extracted, meetingID: meetingID, userID: userID)
        } catch {
            Log.ui.error("entity extraction failed (non-fatal): \(error.localizedDescription)")
        }
    }
}
