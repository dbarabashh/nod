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
    /// In-memory queue of meetings whose insert failed — retried by the
    /// toast button. v1 has no on-disk outbox; if the panel is torn down
    /// (sign-out) before the queue drains, the meetings are lost.
    @Published private(set) var pendingMeetingSaves: [Meeting] = []
    @Published private(set) var saveErrorToast: String?

    /// Wall-clock start of the current recording. Captured in beginRecording
    /// so we can stamp `started_at` accurately when we persist on summary.
    private var recordingStartedAt: Date?

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

    init(
        audioCapture: AudioCaptureService,
        store: TranscriptStore,
        llm: OpenRouterClient,
        meetingStore: MeetingStore,
        entityStore: EntityStore,
        knowledgeStore: KnowledgeStore,
        language: LanguagePreference,
        auth: AuthService,
        profileStore: ProfileStore
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
        recordingStartedAt = Date()
        // Don't clear pendingMeetingSaves here — a prior failed save would
        // be silently lost if the user starts a new meeting before
        // retrying. The toast stays visible (its content reflects whatever
        // unsaved meetings are still queued); a successful retry empties
        // the queue.
        Task {
            await store.start()
            await audioCapture.start(
                captureMic: selectedKind.capturesMic,
                captureSystem: selectedKind.capturesSystem
            )
        }
    }

    func endMeeting() {
        Log.ui.info("End Meeting — entries=\(store.entries.count)")
        store.stop()
        Task { await audioCapture.stop() }

        guard store.hasContent else {
            cleanupToIdle()
            return
        }
        guard let userID = auth.currentSupabaseSession?.user.id else {
            Log.ui.error("End Meeting skipped — no session")
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
        let langCode = lang.whisperCode
        let kind = selectedKind
        let profile = profileContext
        let generation = sessionGeneration

        Task {
            // Finalize in-flight transcription, then re-cluster speakers, so the
            // summary (and the entries snapshot persisted to `meeting_transcripts`)
            // read a complete, diarized dialogue — "Them 1/2/…" instead of an
            // unattributed wall of "Them".
            await store.flushPending()
            await store.refineSpeakers()

            // A new recording started during the flush/re-cluster window — the
            // store now belongs to it. Abandon this meeting's finalize rather
            // than snapshot the new transcript or clear the live recording.
            guard sessionGeneration == generation else {
                Log.ui.info("End Meeting finalize abandoned — newer session started")
                return
            }

            let context = store.fullContext
            let transcriptEntries = store.entries
            guard !context.isEmpty else {
                cleanupToIdle()
                return
            }

            // Build the draft up front so MeetingDetailView opens on a real
            // row with the timestamps + language populated and only the
            // summary / title visibly loading. The same id flows through the
            // server insert later — id is client-generated for idempotency.
            let draft = Meeting.newCompleted(
                userID: userID,
                startedAt: startedAt,
                endedAt: endedAt,
                summary: "",
                language: langCode,
                kind: kind,
                title: nil
            )
            meetingStore.beginGenerating(draft)

            NotificationCenter.default.post(
                name: .nodOpenMeetingDetail,
                object: nil,
                userInfo: [Notification.nodMeetingIDKey: draft.id]
            )

            // Panel returns to ready BEFORE the LLM call so a "Generating
            // summary…" placeholder doesn't double up — once in the small
            // panel card and once in the detail view. The user only sees
            // the detail-view loading state.
            cleanupToIdle()

            let draftID = draft.id
            let (system, user) = PromptLibrary.build(
                kind: .summary,
                transcript: context,
                language: lang,
                personalContext: profile,
                sessionKind: draft.kind
            )
            do {
                let recap = try await llm.completeJSON(system: system, user: user, as: MeetingRecap.self)
                let text = recap.toMarkdown()
                // Title is best-effort — failure here doesn't block
                // persistence; Meeting.displayTitle falls back to a
                // date label.
                let title = await generateMeetingTitle(from: text)
                let updated = draft.updating(title: title, summary: text, recap: recap)
                meetingStore.applyGenerated(updated)
                await persistMeeting(
                    meeting: updated,
                    transcriptEntries: transcriptEntries
                )
                // Enrichment (entities for "Related" + embeddings for
                // cross-session search) only runs once the meeting actually
                // landed on the server. If the save was queued for retry, the
                // parent row doesn't exist yet, so these would FK-fail, waste
                // an LLM + embedding call, and never re-run — same reasoning as
                // the transcript-insert guard in persistMeeting.
                //
                // Run indexing AFTER entities, not concurrently: indexing runs
                // gte-small embeddings *inside* the edge worker and is CPU-heavy
                // enough to trip WORKER_RESOURCE_LIMIT (HTTP 546). Serializing
                // keeps it from sharing a worker instance with the entity call —
                // the contention that pushed it over the CPU budget. It's all
                // background, so the extra latency is invisible to the user.
                if !pendingMeetingSaves.contains(where: { $0.id == updated.id }) {
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
                Log.ui.error("Meeting summary generation failed: \(error.localizedDescription)")
                meetingStore.markGenerationFailed(
                    id: draftID,
                    errorMessage: "⚠️ \(error.localizedDescription)"
                )
            }
        }
    }

    private func cleanupToIdle() {
        meeting = .idle
        response = .none
        elapsed = 0
        micMuted = false
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
                    try await llm.completeJSON(system: system, user: user, as: MeetingRecap.self).toMarkdown()
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

    // MARK: - Meeting persistence (issue #14)

    /// Fires the Supabase insert for a finalised meeting and best-effort
    /// follows with a transcript bulk-insert. On insert failure the row
    /// is cached in `pendingMeetingSaves` so the retry toast can re-fire
    /// it with the SAME id (idempotency — server allows the duplicate id
    /// because the client always pre-generates the UUID, never relying
    /// on `default gen_random_uuid()`).
    private func persistMeeting(
        meeting: Meeting,
        transcriptEntries: [TranscriptEntry]
    ) async {
        await attemptSave(meeting)
        // If attemptSave failed it queues `meeting` on pendingMeetingSaves —
        // inserting transcripts now would FK-fail (no parent row on the
        // server) and the records would be discarded by the catch below.
        // The retry queue handles the meeting row, but transcripts aren't
        // requeued; rather than silently losing them with a FK-violation
        // error in the log, skip the insert until the meeting actually
        // lands. Net behaviour: transcripts are absent when the very
        // first save fails; the summary (the more valuable artifact) is
        // preserved by the existing retry path.
        if pendingMeetingSaves.contains(where: { $0.id == meeting.id }) {
            Log.ui.info("insertTranscript skipped — meeting save still pending")
            return
        }
        // Transcript best-effort: the summary row is already saved, so a
        // transcript failure shouldn't surface a retry toast — log and
        // move on. The detail view degrades gracefully when transcripts
        // are missing (shows "No transcript saved for this meeting.").
        guard !transcriptEntries.isEmpty else { return }
        let records = transcriptEntries.enumerated().map { idx, entry in
            TranscriptRecord(
                id: entry.id,
                meetingID: meeting.id,
                userID: meeting.userID,
                createdAt: nil,
                source: entry.source.rawValue,
                text: entry.text,
                ts: entry.timestamp,
                idx: idx,
                speaker: entry.speaker
            )
        }
        do {
            try await meetingStore.insertTranscript(records)
        } catch {
            Log.ui.error("MeetingStore.insertTranscript failed (non-fatal) — \(error.localizedDescription)")
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

    private func attemptSave(_ meeting: Meeting) async {
        do {
            try await meetingStore.insert(meeting)
            pendingMeetingSaves.removeAll { $0.id == meeting.id }
            if pendingMeetingSaves.isEmpty {
                saveErrorToast = nil
            }
        } catch {
            Log.ui.error("MeetingStore.insert failed — \(error.localizedDescription)")
            // Queue the failed save so the retry toast can re-fire it.
            // The panel is always on screen (idle or recording) so the
            // toast is visible regardless of state — the previous
            // `meeting != .idle` gate silenced this branch once we
            // started running persistence after returning the panel to
            // idle for the open-detail handoff.
            if !pendingMeetingSaves.contains(where: { $0.id == meeting.id }) {
                pendingMeetingSaves.append(meeting)
            }
            saveErrorToast = "Couldn't save meeting — \(error.localizedDescription)"
        }
    }

    func retryPendingSaves() {
        let queued = pendingMeetingSaves
        Task {
            for meeting in queued {
                await attemptSave(meeting)
            }
        }
    }

    func dismissSaveError() {
        saveErrorToast = nil
        // Toast hidden; the queue itself stays so a future save error will
        // resurface the latest message. The toast re-appears the moment
        // `saveErrorToast` is set again by a fresh failure.
    }
}
