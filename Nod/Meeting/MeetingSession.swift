import Foundation
import SwiftUI

enum MeetingState: Equatable {
    case idle
    case recording
    case paused

    var statusLabel: String {
        switch self {
        case .idle: "READY"
        case .recording: "REC"
        case .paused: "PAUSED"
        }
    }

    /// Tint for the status label. Paused is the only state that diverges —
    /// the warning (amber) slot so "stopped, not recording" reads at a glance,
    /// matching the menu-bar paused dot. Recording/idle use the muted default.
    var statusTint: Color {
        self == .paused ? Theme.Palette.warning : .white.opacity(0.82)
    }
}

/// The mid-call generation actions the panel offers. Raw values are the
/// historical kind strings — ResponseCard's header label and the tap log
/// lines key off them, so they must not change.
enum GenerationKind: String {
    case hero
    case suggestReply = "Suggest reply"
    case keyPoints = "Key points"
    case followUp = "Suggest follow-up questions"

    var promptKind: PromptKind {
        switch self {
        case .hero: .hero
        case .suggestReply: .suggestReply
        case .keyPoints: .smartReply
        case .followUp: .followUp
        }
    }
}

enum AIResponse: Equatable {
    case none
    case generating(kind: GenerationKind)
    case ready(kind: GenerationKind, text: String)
}

/// Owns the recording lifecycle, mid-call generation, and end-of-meeting
/// persistence that used to live as @State + private funcs in ContentView.
/// One instance per floating panel — created in `showFloatingPanel` and
/// dropped with it, so session state dies on sign-out exactly like the old
/// view-local @State did.
@MainActor
final class MeetingSession: ObservableObject {
    @Published private(set) var meeting: MeetingState = .idle
    /// What the next recording will be. Chosen while idle; fixed for the
    /// duration of a recording so the recap framing + audio streams stay
    /// consistent from start to stop.
    @Published var selectedKind: SessionKind = .meeting
    @Published private(set) var response: AIResponse = .none
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var micMuted: Bool = false
    /// Completed meetings still waiting to reach the server — drives the retry
    /// toast. Backed by the durable on-disk `MeetingOutbox`, so unlike the old
    /// in-memory queue these survive a quit / crash / app update and are
    /// replayed on the next launch; this array is just the UI mirror.
    @Published private(set) var pendingMeetingSaves: [Meeting] = []
    @Published private(set) var saveErrorToast: String?

    /// Wall-clock start of the current recording. Captured in beginRecording
    /// so we can stamp `started_at` accurately when we persist on summary.
    private var recordingStartedAt: Date?

    /// The meeting currently being recorded — created at `beginRecording` so the
    /// live transcript can stream to the server under a stable id, then reused
    /// (same id) when the summary is stamped at End. nil while idle, or when no
    /// auth session existed at record time.
    private var recordingDraft: Meeting?

    /// Live transcript streaming loop — pushes settled entries to the WAL +
    /// server every few seconds during a recording. Cancelled at End / cleanup.
    private var streamTask: Task<Void, Never>?

    /// How many leading `store.entries` have already been streamed to the WAL,
    /// so each tick only forwards the new settled tail.
    private var streamedCount = 0

    /// Only entries older than this are streamed: cross-source dedup can
    /// retroactively replace a `.me` entry with a cleaner `.them` one within
    /// `TranscriptStore`'s 8s window, so streaming sooner would leave a stale
    /// echo row on the server. Past this margin an entry's id is final.
    private static let streamSettleWindow: TimeInterval = 11
    private static let streamInterval: TimeInterval = 5

    /// Bumped each time a recording starts. `endMeeting`'s deferred finalize
    /// captures the value and bails if it changed — otherwise a meeting started
    /// during the post-meeting flush/re-cluster window would have its fresh
    /// transcript snapshotted into the old summary and then wiped by the old
    /// meeting's `cleanupToIdle()`.
    private var sessionGeneration = 0

    private let audioCapture: AudioCaptureService
    private let store: TranscriptStore
    private let llm: OpenRouterClient
    private let meetingStore: MeetingStore
    private let entityStore: EntityStore
    private let knowledgeStore: KnowledgeStore
    private let language: LanguagePreference
    private let auth: AuthService
    private let profileStore: ProfileStore
    private let outbox: MeetingOutbox

    init(
        audioCapture: AudioCaptureService,
        store: TranscriptStore,
        llm: OpenRouterClient,
        meetingStore: MeetingStore,
        entityStore: EntityStore,
        knowledgeStore: KnowledgeStore,
        language: LanguagePreference,
        auth: AuthService,
        profileStore: ProfileStore,
        outbox: MeetingOutbox
    ) {
        self.audioCapture = audioCapture
        self.store = store
        self.llm = llm
        self.meetingStore = meetingStore
        self.entityStore = entityStore
        self.knowledgeStore = knowledgeStore
        self.language = language
        self.auth = auth
        self.profileStore = profileStore
        self.outbox = outbox
    }

    deinit {
        // A sign-out drops the session mid-recording; stop the streaming loop so
        // it doesn't outlive the panel. The WAL on disk keeps whatever streamed.
        streamTask?.cancel()
    }

    /// Always-on personal context prepended to every LLM system prompt so
    /// recaps and live cards read as if Nod already knows the user. "" when
    /// the profile is empty.
    private var profileContext: String {
        profileStore.promptContext
    }

    func isGenerating(for kind: GenerationKind) -> Bool {
        if case let .generating(k) = response, k == kind { return true }
        return false
    }

    func dismissResponse() {
        response = .none
    }

    func runSecondsTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if meeting == .recording { elapsed += 1 }
        }
    }

    // MARK: - Recording lifecycle

    func beginRecording() {
        Log.ui.info("Start Meeting")
        sessionGeneration += 1
        meeting = .recording
        elapsed = 0
        response = .none
        // Stamp the wall-clock so the persisted row carries an accurate
        // `started_at` instead of using the summary-ready instant.
        let startedAt = Date()
        recordingStartedAt = startedAt
        // Don't clear pendingMeetingSaves here — a prior failed save would
        // be silently lost if the user starts a new meeting before
        // retrying. The toast stays visible (its content reflects whatever
        // unsaved meetings are still queued); a successful retry empties
        // the queue.

        // Open the durable WAL for this recording NOW, under a stable id, so the
        // transcript streams to disk + server as it's captured. `ended_at` is
        // seeded to `started_at` and corrected at End (the column is NOT NULL).
        // No auth session → no streaming; End still persists best-effort.
        streamTask?.cancel()
        streamTask = nil
        streamedCount = 0
        recordingDraft = nil
        if let userID = auth.currentSupabaseSession?.user.id {
            let draft = Meeting.newCompleted(
                userID: userID,
                startedAt: startedAt,
                endedAt: startedAt,
                summary: "",
                language: language.current.rawValue,
                kind: selectedKind
            )
            recordingDraft = draft
            Task { await outbox.begin(draft) }
            startStreamLoop(draft: draft, generation: sessionGeneration)
        }

        Task {
            await store.start()
            await audioCapture.start(
                captureMic: selectedKind.capturesMic,
                captureSystem: selectedKind.capturesSystem
            )
        }
    }

    /// Periodically forward newly-settled transcript entries to the WAL + server
    /// so an interrupted meeting is recoverable and the end-of-meeting save is a
    /// cheap delta, not a bulk insert that races the app shutting down.
    private func startStreamLoop(draft: Meeting, generation: Int) {
        streamTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.streamInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.streamSettledTranscript(draft: draft, generation: generation)
            }
        }
    }

    /// Push the leading run of entries old enough to be past the dedup window.
    /// Guarded on the captured `(draft, generation)` so a tick that straddles an
    /// End → new-recording transition can't stream the wrong meeting's entries
    /// (or under a stale id).
    private func streamSettledTranscript(draft: Meeting, generation: Int) async {
        guard sessionGeneration == generation, recordingDraft?.id == draft.id else { return }
        let cutoff = Date().addingTimeInterval(-Self.streamSettleWindow)
        let entries = store.entries
        var settledCount = 0
        for entry in entries {
            if entry.timestamp < cutoff { settledCount += 1 } else { break }
        }
        guard settledCount > streamedCount else { return }
        let slice = Array(entries[streamedCount ..< settledCount])
        let records = transcriptRecords(from: slice, meeting: draft, baseIdx: streamedCount)
        streamedCount = settledCount
        await outbox.record(records, for: draft.id)
        await outbox.flush(using: meetingStore, userID: draft.userID)
    }

    func endMeeting() {
        Log.ui.info("End Meeting — entries=\(store.entries.count)")
        store.stop()
        Task { await audioCapture.stop() }
        streamTask?.cancel()
        streamTask = nil

        let recordingDraftID = recordingDraft?.id
        recordingDraft = nil

        guard store.hasContent else {
            // Empty start→stop: drop the WAL entry so no orphan row is created.
            if let id = recordingDraftID { Task { await outbox.discard(id) } }
            cleanupToIdle()
            return
        }
        guard let userID = auth.currentSupabaseSession?.user.id else {
            Log.ui.error("End Meeting skipped — no session")
            if let id = recordingDraftID { Task { await outbox.discard(id) } }
            cleanupToIdle()
            return
        }

        // Snapshot the recording bookends + session config BEFORE the async
        // work — endedAt marks the user's stop, not the summary-ready instant,
        // and the kind/language shouldn't shift if the user reconfigures while
        // the summary generates.
        let startedAt = recordingStartedAt ?? Date()
        let endedAt = Date()
        let lang = language.current
        let langCode = lang.rawValue
        let kind = selectedKind
        let profile = profileContext
        let generation = sessionGeneration

        // Open the detail view and reset the panel IMMEDIATELY — the summary
        // pass can take many seconds on a long call, so it must not block the
        // user. The detail view shows its "Generating…" state meanwhile. The
        // transcript stays in the store until the background task snapshots it
        // below.
        //
        // Reuse the streaming draft's id so the rows already streamed under it
        // are updated, not duplicated. Built fresh so the bookends are accurate
        // even on the no-streaming fallback path (no auth at record time, or a
        // meeting shorter than one stream tick).
        let draft = Meeting(
            id: recordingDraftID ?? UUID(),
            userID: userID,
            createdAt: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            title: nil,
            kind: kind,
            summary: "",
            recap: nil,
            language: langCode,
            deletedAt: nil
        )
        meetingStore.beginGenerating(draft)
        NotificationCenter.default.post(
            name: .nodOpenMeetingDetail,
            object: nil,
            userInfo: [Notification.nodMeetingIDKey: draft.id]
        )
        resetPanelForIdle()

        let draftID = draft.id
        Task {
            // Ensure a WAL entry exists even on the fallback path — idempotent,
            // so a streamed meeting keeps its progress.
            await outbox.begin(draft)

            await store.flushPending()

            // A new recording started during the flush window — the store now
            // belongs to it. Abandon this meeting's finalize rather than
            // summarize/snapshot the new transcript or clear the live recording.
            guard sessionGeneration == generation else {
                Log.ui.info("End Meeting finalize abandoned — newer session started")
                return
            }

            // Snapshot the transcript for the summary up front.
            let context = store.fullContext
            guard !context.isEmpty else {
                store.clear()
                await outbox.discard(draftID)
                meetingStore.markGenerationFailed(id: draftID, errorMessage: "⚠️ No transcript captured")
                return
            }

            let (system, user) = PromptLibrary.build(
                kind: .summary,
                transcript: context,
                language: lang,
                personalContext: profile,
                sessionKind: draft.kind
            )

            do {
                let recap = try await generateRecap(system: system, user: user, transcript: context, language: lang)
                let text = recap.toMarkdown()
                // Title is best-effort — failure here doesn't block
                // persistence; Meeting.displayTitle falls back to a
                // date label.
                let title = await generateMeetingTitle(from: text)
                let updated = draft.updating(title: title, summary: text, recap: recap)
                meetingStore.applyGenerated(updated)

                let entries = store.entries
                guard sessionGeneration == generation else {
                    Log.ui.info("End Meeting finalize abandoned — newer session started")
                    meetingStore.finishFinalizing(id: updated.id)
                    return
                }
                store.clear()

                // Stamp the finished meeting + full transcript into the durable
                // WAL, THEN push. The recap is on disk before the network write,
                // so a quit / crash / app update can't lose it — launch replay
                // resends whatever didn't drain here.
                let records = transcriptRecords(from: entries, meeting: updated)
                await outbox.complete(updated, transcripts: records, for: updated.id)
                await drainOutbox()
                meetingStore.finishFinalizing(id: updated.id)

                // Enrichment (entities for "Related" + embeddings for
                // cross-session search) only runs once the meeting actually
                // landed on the server. If the save is still queued for retry,
                // the parent row doesn't exist yet, so these would FK-fail,
                // waste an LLM + embedding call, and never re-run.
                //
                // Run indexing AFTER entities, not concurrently: indexing runs
                // gte-small embeddings *inside* the edge worker and is CPU-heavy
                // enough to trip WORKER_RESOURCE_LIMIT (HTTP 546). Serializing
                // keeps it from sharing a worker instance with the entity call —
                // the contention that pushed it over the CPU budget. It's all
                // background, so the extra latency is invisible to the user.
                let landed = await outbox.isPending(updated.id) == false
                if landed {
                    await extractEntities(
                        meetingID: updated.id,
                        userID: userID,
                        transcript: context,
                        summary: text
                    )
                    await knowledgeStore.index(
                        meetingID: updated.id,
                        transcript: context
                    )
                }
            } catch {
                if sessionGeneration == generation {
                    // Summary failed, but the transcript is real work. Complete
                    // the WAL entry with a fallback recap so it's a TERMINAL,
                    // drainable `.completed` row (preserving the transcript) —
                    // not a phantom `.recording` entry that would re-push forever
                    // and never reach a terminal state.
                    let fallback = draft.updating(title: nil, summary: Self.summaryFailedFallback)
                    let records = transcriptRecords(from: store.entries, meeting: fallback)
                    await outbox.complete(fallback, transcripts: records, for: draftID)
                    await drainOutbox()
                    store.clear()
                } else {
                    Log.ui.info("End Meeting transcript clear skipped — newer session started")
                }
                Log.ui.error("Meeting summary generation failed: \(error.localizedDescription)")
                meetingStore.markGenerationFailed(
                    id: draftID,
                    errorMessage: "⚠️ \(error.localizedDescription)"
                )
            }
        }
    }

    /// Reset the panel to its ready state without touching the transcript —
    /// used when the post-meeting finalize still needs `store` to snapshot it.
    private func resetPanelForIdle() {
        meeting = .idle
        response = .none
        elapsed = 0
        micMuted = false
    }

    private func cleanupToIdle() {
        streamTask?.cancel()
        streamTask = nil
        recordingDraft = nil
        resetPanelForIdle()
        store.clear()
    }

    func toggleRecording() {
        switch meeting {
        case .idle:
            break
        case .recording:
            print("→ Pause")
            meeting = .paused
            audioCapture.pause()
        case .paused:
            print("→ Resume")
            meeting = .recording
            Task { await audioCapture.resume() }
        }
    }

    func toggleMic() {
        micMuted.toggle()
        audioCapture.setMicMuted(micMuted)
        Log.ui.info(micMuted ? "mic muted" : "mic unmuted")
    }

    // MARK: - Mid-call generation

    func generate(kind: GenerationKind) {
        Log.ui.info("user tapped '\(kind.rawValue)' — context.len=\(store.fullContext.count) entries=\(store.entries.count)")
        response = .generating(kind: kind)
        let requestedKind = kind
        let promptKind = kind.promptKind
        Task {
            // Suggest reply is real-time — force the latest chunk into the
            // transcript before reading context. Other pills tolerate the 5s
            // staleness.
            if promptKind == .suggestReply {
                await store.flushPending()
            }
            let context = store.recentContext(maxEntries: promptKind.contextWindow ?? .max)
            if context.isEmpty {
                Log.ui.info("⚠️ context is EMPTY — LLM will get only the system prompt")
            }
            let (system, user) = PromptLibrary.build(
                kind: promptKind,
                transcript: context,
                language: language.current,
                personalContext: profileContext,
                sessionKind: selectedKind,
                replyContext: ReplyContext.current
            )
            do {
                // Every pill's prompt emits a structured JSON object; decode the
                // matching type and render it to markdown the card already knows
                // how to show (`renderRecapMarkdown`).
                let text: String = switch promptKind {
                case .hero:
                    try await llm.completeJSON(system: system, user: user, as: CatchUp.self).toMarkdown()
                case .smartReply:
                    try await llm.completeJSON(system: system, user: user, as: KeyPoints.self).toMarkdown()
                case .followUp:
                    try await llm.completeJSON(system: system, user: user, as: FollowUpQuestions.self).toMarkdown()
                case .summary:
                    try await generateRecap(system: system, user: user, transcript: context, language: language.current).toMarkdown()
                case .suggestReply:
                    try await llm.completeJSON(system: system, user: user, as: SuggestedReply.self).toMarkdown()
                }
                if case let .generating(k) = response, k == requestedKind {
                    response = .ready(kind: requestedKind, text: text)
                    print("→ \(requestedKind.rawValue) — ready")
                }
            } catch {
                if case let .generating(k) = response, k == requestedKind {
                    response = .ready(kind: requestedKind, text: "⚠️ \(error.localizedDescription)")
                    print("→ \(requestedKind.rawValue) — failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func generateRecap(system: String, user: String, transcript: String, language: AppLanguage) async throws -> MeetingRecap {
        let recap = try await llm.completeJSON(system: system, user: user, as: MeetingRecap.self)

        // One bounded retry that addresses whatever the first pass got wrong.
        // Two independent failure modes share it: (1) the model used the
        // "too short / unclear" fallback on a substantive transcript; (2) the
        // model ignored the language directive and wrote the recap in the wrong
        // language (Gemini in JSON mode has been seen emitting Chinese for a
        // Russian-selected, Russian-spoken meeting). Both are deterministic to
        // detect, so we don't rely on the prompt alone — we check the output.
        var overrides: [String] = []

        if recap.isPlaceholderFallback, transcriptHasSubstance(transcript) {
            Log.llm.info("summary placeholder on substantive transcript — will retry")
            overrides.append("""
            RETRY OVERRIDE — FALLBACK:
            Your previous response used the "Transcript too short or unclear" fallback, but this transcript has enough intelligible content to recap.
            Do NOT use the fallback on this retry. Extract 2-4 grounded topics from the transcript, translating non-English content into the requested output language. Decisions/actions/open questions may still be empty.
            """)
        }

        if let got = Self.recapLanguageMismatch(recap, expected: language) {
            Log.llm.info("recap language mismatch got=\(got) expected=\(language.rawValue) — will retry")
            overrides.append("""
            RETRY OVERRIDE — LANGUAGE:
            Your previous response was written in the WRONG language (it came out in \(got)). Write EVERY string value — topics, decisions, actions, open questions — in \(
                language.promptName
            ), and nothing else. Leave verbatim `quote` values exactly as spoken; JSON keys stay in English.
            """)
        }

        guard !overrides.isEmpty else { return recap }
        let retrySystem = system + "\n\n" + overrides.joined(separator: "\n\n")
        return try await llm.completeJSON(system: retrySystem, user: user, as: MeetingRecap.self)
    }

    /// Detects whether the recap's PROSE (not the verbatim `quote` values, which
    /// stay in the spoken language) was written in a language other than the one
    /// the user selected. Returns the offending language code, or nil when it
    /// matches / is too short to call confidently. The quotes are excluded so a
    /// recap correctly written in the target language isn't flagged just because
    /// it embeds an original-language quote.
    private static func recapLanguageMismatch(_ recap: MeetingRecap, expected: AppLanguage) -> String? {
        var prose: [String] = recap.topics.map(\.text)
        prose += recap.decisions.flatMap { [$0.text, $0.why].compactMap { $0 } }
        prose += recap.actions.flatMap { [$0.owner, $0.task, $0.when].compactMap { $0 } }
        prose += recap.openQuestions.map(\.text)
        let joined = prose.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count >= 12, let detected = AppLanguage.detect(from: joined) else { return nil }
        if detected == expected { return nil }
        // NLLanguageRecognizer routinely confuses Ukrainian and Russian (both
        // Cyrillic, closely related) — the founder's home-market pair. A uk↔ru
        // "mismatch" is almost always a misdetection of a correct recap, so
        // don't burn a full re-generation on it (and re-prompting wouldn't
        // reliably flip uk↔ru anyway). Real wrong-language cases here are
        // cross-script (e.g. Chinese), which this still catches.
        let cyrillicPair: Set<AppLanguage> = [.russian, .ukrainian]
        if cyrillicPair.contains(expected), cyrillicPair.contains(detected) { return nil }
        return detected.rawValue
    }

    private func transcriptHasSubstance(_ transcript: String) -> Bool {
        let words = transcript
            .split { $0.isWhitespace || $0.isNewline }
            .filter { $0.contains { $0.isLetter } }
        return words.count >= 40
    }

    // MARK: - Meeting persistence (issue #14)

    /// Fallback recap stamped when summary generation fails outright — keeps the
    /// transcript a terminal, drainable `.completed` entry instead of a phantom
    /// `.recording` one that re-pushes forever.
    private static let summaryFailedFallback =
        "A summary couldn't be generated automatically for this meeting. The transcript was saved."

    /// Pushes the durable outbox to the server and refreshes the retry-toast
    /// mirror. The outbox is idempotent (upsert by id) and survives restarts,
    /// so a failure here just leaves the work on disk for the next drain
    /// (launch, app-focus, or the manual retry button).
    private func drainOutbox() async {
        guard let userID = auth.currentSupabaseSession?.user.id else { return }
        await outbox.flush(using: meetingStore, userID: userID)
        let stuck = await outbox.pendingCompletedMeetings(for: userID)
        pendingMeetingSaves = stuck
        // Keep the library/detail in sync with the WAL: the local recap stays
        // authoritative (un-clobbered by a stale server row) and rows surface a
        // "Not synced" indicator until the push lands.
        meetingStore.setUnsyncedMeetings(stuck)
        saveErrorToast = stuck.isEmpty ? nil : "Couldn't sync meeting — tap to retry."
    }

    /// `baseIdx` offsets the row `idx` so a streamed tail (entries
    /// `baseIdx..<n`) keeps the same global positions as the final full snapshot
    /// (`baseIdx: 0`), letting the two paths upsert the same rows by id.
    private func transcriptRecords(
        from entries: [TranscriptEntry],
        meeting: Meeting,
        baseIdx: Int = 0
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
                speaker: nil
            )
        }
    }

    /// Best-effort entity extraction — links the saved session to the
    /// people / projects / topics it mentions so "Related sessions" can find
    /// it. Runs after persistence; a failure here never affects the meeting.
    private func extractEntities(
        meetingID: UUID,
        userID: UUID,
        transcript: String,
        summary: String
    ) async {
        guard !transcript.isEmpty else { return }
        let (system, user) = PromptLibrary.buildEntityExtraction(transcript: transcript, summary: summary)
        do {
            let extracted = try await llm.completeJSON(system: system, user: user, as: ExtractedEntities.self)
            guard !extracted.isEmpty else { return }
            try await entityStore.saveExtraction(extracted, meetingID: meetingID, userID: userID)
        } catch {
            Log.ui.error("entity extraction failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Best-effort LLM call to produce a short event-style title. Returns
    /// nil on failure (Meeting.displayTitle falls back to a date label).
    private func generateMeetingTitle(from summary: String) async -> String? {
        let (system, user) = PromptLibrary.buildTitle(
            summary: summary,
            language: language.current
        )
        do {
            let raw = try await llm.complete(system: system, user: user)
            return Self.sanitizeTitle(raw)
        } catch {
            Log.ui.error("title generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Models occasionally wrap titles in **bold**, prefix them with
    /// "Title: ", or echo quotes around them despite the prompt's
    /// instructions. Strip the common artefacts before storing.
    private static func sanitizeTitle(_ raw: String) -> String? {
        // 1. Whitespace + first-line only — models sometimes follow with a
        //    blank line + explanation.
        var line = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        // 2. Surrounding quotes / backticks.
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))

        // 3. Surrounding `**bold**` markers — the LLM sometimes emits the
        //    title in bold despite the no-markdown rule.
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
            line.removeFirst(2)
            line.removeLast(2)
            line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 4. Leading "Title:" / "Заголовок:" / "Тема:" / "Назва:" prefixes
        //    (case-insensitive).
        for prefix in ["title:", "заголовок:", "тема:", "назва:"] {
            if line.lowercased().hasPrefix(prefix) {
                line = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 5. Trailing punctuation that doesn't belong in a title.
        while let last = line.last, ".!?;,".contains(last) {
            line.removeLast()
        }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cap at 120 chars — enough headroom for Ukrainian/Russian/Polish
        // 7-word titles whose roots are longer than English equivalents.
        guard !line.isEmpty, line.count <= 120 else {
            Log.ui.info("title rejected (empty or too long): \(line.prefix(40))…")
            return nil
        }
        return line
    }

    func retryPendingSaves() {
        Task { await drainOutbox() }
    }

    func dismissSaveError() {
        saveErrorToast = nil
        // Toast hidden; the queue itself stays so a future save error will
        // resurface the latest message. The toast re-appears the moment
        // `saveErrorToast` is set again by a fresh failure.
    }
}
