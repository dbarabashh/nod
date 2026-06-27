import Foundation
import SwiftUI

enum MeetingState: Equatable {
    case idle
    case recording
    case paused

    /// Header status word. While capturing it names what Nod is doing for the
    /// user — varying by `SessionKind` — rather than a stark "REC".
    func statusLabel(for kind: SessionKind) -> String {
        switch self {
        case .idle: "Ready"
        case .recording: kind.activeStatusLabel
        case .paused: "Paused"
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
    /// A streamed answer still in flight — `text` grows as deltas arrive. Only
    /// `.suggestReply` uses this; the other pills decode a JSON object in one
    /// shot and jump straight to `.ready`.
    case streaming(kind: GenerationKind, text: String)
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
    private let llm: LLMProxyClient
    private let meetingStore: MeetingStore
    private let entityStore: EntityStore
    private let knowledgeStore: KnowledgeStore
    private let language: LanguagePreference
    private let auth: AuthService
    private let profileStore: ProfileStore
    private let outbox: MeetingOutbox
    private let modeStore: ModeStore

    init(
        audioCapture: AudioCaptureService,
        store: TranscriptStore,
        llm: LLMProxyClient,
        meetingStore: MeetingStore,
        entityStore: EntityStore,
        knowledgeStore: KnowledgeStore,
        language: LanguagePreference,
        auth: AuthService,
        profileStore: ProfileStore,
        outbox: MeetingOutbox,
        modeStore: ModeStore
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
        self.modeStore = modeStore
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
        switch response {
        case let .generating(k), let .streaming(k, _): k == kind
        default: false
        }
    }

    /// Whether `response` is still the in-flight request for `kind` (generating
    /// or mid-stream). Used to drop late stream deltas after the user dismissed
    /// the card or fired a different pill. Same predicate as `isGenerating`; the
    /// name documents intent at the stream call sites.
    private func isActiveRequest(_ kind: GenerationKind) -> Bool {
        isGenerating(for: kind)
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
        // Modes apply to meetings only; `MeetingFraming` returns neutral framing
        // for voice notes / media so they never inherit the last meeting mode.
        let framing = MeetingFraming.active(for: kind, mode: modeStore.selected)

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
        // Pin this meeting's transcript on the main thread, before any await: the
        // store + transcribers are shared and reused by the next recording, so a
        // meeting started while this one summarises (the recap stream takes many
        // seconds) would reset them out from under the finalize.
        let pinnedEntries = store.entries
        Task {
            // Ensure a WAL entry exists even on the fallback path — idempotent,
            // so a streamed meeting keeps its progress.
            await outbox.begin(draft)

            await store.flushPending()

            // Prefer the post-flush transcript (it includes the last in-flight
            // chunk) while this is still the active session; if a newer recording
            // took over the store during flush, fall back to the pinned snapshot
            // so this meeting is still persisted instead of silently dropped.
            let entriesSnapshot = sessionGeneration == generation ? store.entries : pinnedEntries
            let context = Self.transcriptContext(from: entriesSnapshot)
            guard !context.isEmpty else {
                if sessionGeneration == generation { store.clear() }
                await outbox.discard(draftID)
                meetingStore.markGenerationFailed(id: draftID, errorMessage: "⚠️ No transcript captured")
                return
            }

            let (system, user) = PromptLibrary.build(
                kind: .summary,
                transcript: context,
                language: lang,
                personalContext: profile,
                sessionKind: draft.kind,
                summaryTemplate: framing.summary,
                modeFocus: framing.focus,
                meetingDate: PromptLibrary.sessionDateString(startedAt)
            )

            do {
                let recap = try await streamRecap(
                    system: system,
                    user: user,
                    transcript: context,
                    language: lang,
                    meetingID: draftID
                )
                let text = recap.toMarkdown()
                // Title is best-effort — failure here doesn't block
                // persistence; Meeting.displayTitle falls back to a
                // date label.
                let title = await generateMeetingTitle(from: text)
                let updated = draft.updating(title: title, summary: text, recap: recap)
                meetingStore.applyGenerated(updated)

                // Only clear the live store if it still belongs to THIS meeting —
                // a recording started during summary generation now owns it. The
                // transcript is already pinned in `entriesSnapshot`, so persist
                // either way: bailing here used to leave the meeting applied
                // locally but never written to the WAL/server, so it vanished on
                // the next launch.
                if sessionGeneration == generation { store.clear() }

                // Stamp the finished meeting + full transcript into the durable
                // WAL, THEN push. The recap is on disk before the network write,
                // so a quit / crash / app update can't lose it — launch replay
                // resends whatever didn't drain here.
                let records = transcriptRecords(from: entriesSnapshot, meeting: updated)
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
                // Summary failed, but the transcript is real work. Complete the
                // WAL entry with a fallback recap so it's a TERMINAL, drainable
                // `.completed` row (preserving the transcript) — not a phantom
                // `.recording` entry that would re-push forever and never reach a
                // terminal state. Persist even if a newer recording started: the
                // transcript is pinned in `entriesSnapshot`, and only the live
                // store clear is gated so the new recording isn't wiped.
                let fallback = draft.updating(title: nil, summary: Self.summaryFailedFallback)
                let records = transcriptRecords(from: entriesSnapshot, meeting: fallback)
                await outbox.complete(fallback, transcripts: records, for: draftID)
                await drainOutbox()
                if sessionGeneration == generation { store.clear() }
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
        // Snapshot the framing at the moment the user invoked this, so a mode
        // change between tap and generation can't re-frame the in-flight request
        // (and so it matches the recap path, which also freezes its framing).
        let framing = MeetingFraming.active(for: selectedKind, mode: modeStore.selected)
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
                replyContext: framing.reply,
                modeFocus: framing.focus,
                meetingDate: recordingStartedAt.map(PromptLibrary.sessionDateString) ?? ""
            )

            // Suggest reply streams its plain-text answer so the first words land
            // in ~1s instead of after the whole completion. The other pills emit a
            // structured JSON object that can't be rendered until it's complete.
            if promptKind == .suggestReply {
                await streamSuggestReply(system: system, user: user, requestedKind: requestedKind)
                return
            }

            do {
                // Every other pill's prompt emits a structured JSON object; decode
                // the matching type and render it to markdown the card already
                // knows how to show (`renderRecapMarkdown`).
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
                    // Unreachable: the early return above routes suggestReply to
                    // streamSuggestReply. Fail loudly if that guard is ever removed
                    // rather than silently rendering a blank card.
                    preconditionFailure("suggestReply must stream via streamSuggestReply, not the buffered switch")
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

    private static let suggestReplyEmptyFallback = "Not enough context yet — keep talking and try again."

    /// Streams the suggest-reply answer into `response`, updating `.streaming`
    /// per delta and finalizing `.ready`. Late deltas are dropped once the user
    /// dismisses the card or fires another pill (`isActiveRequest`). Any stream
    /// failure — whether before the first token or mid-stream — retries once via
    /// the one-shot path, which yields a guaranteed-complete answer: a truncated
    /// half-sentence must never be presented as a finished line the user reads
    /// aloud.
    private func streamSuggestReply(system: String, user: String, requestedKind: GenerationKind) async {
        var accumulated = ""
        var lastPublish = Date.distantPast
        do {
            for try await delta in llm.streamComplete(system: system, user: user) {
                guard isActiveRequest(requestedKind) else { return }
                accumulated += delta
                // Coalesce to ~20 updates/s. Publishing .streaming on every token
                // republished @Published response (and the card's onChange) several
                // times per frame — SwiftUI warns ("update multiple times per
                // frame") and it needlessly churns the main thread. The trailing
                // .ready below always carries the complete text, so throttling the
                // intermediate frames never drops the final words.
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= 0.05 {
                    response = .streaming(kind: requestedKind, text: accumulated)
                    lastPublish = now
                }
            }
            guard isActiveRequest(requestedKind) else { return }
            let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            response = .ready(kind: requestedKind, text: final.isEmpty ? Self.suggestReplyEmptyFallback : final)
            Log.ui.info("suggest reply ready (streamed)")
        } catch {
            guard isActiveRequest(requestedKind) else { return }
            Log.ui.error(
                "suggest reply stream failed (\(accumulated.isEmpty ? "before first token" : "mid-stream after \(accumulated.count) chars")) — retrying one-shot: \(error.localizedDescription)"
            )
            await oneShotSuggestReply(system: system, user: user, requestedKind: requestedKind)
        }
    }

    /// One-shot fallback for suggest reply (plain text, no JSON). Used whenever
    /// the stream fails, to recover a complete answer in a single request.
    private func oneShotSuggestReply(system: String, user: String, requestedKind: GenerationKind) async {
        do {
            let text = try await llm.complete(system: system, user: user).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isActiveRequest(requestedKind) else { return }
            response = .ready(kind: requestedKind, text: text.isEmpty ? Self.suggestReplyEmptyFallback : text)
        } catch {
            guard isActiveRequest(requestedKind) else { return }
            response = .ready(kind: requestedKind, text: "⚠️ \(error.localizedDescription)")
        }
    }

    /// Streams the end-of-meeting recap, publishing partial markdown to the
    /// store section-by-section so MeetingDetailView fills it in live instead of
    /// popping the whole recap in at the end. On a clean finish it parses the
    /// full JSON and runs the same bounded retry as the one-shot path. Any
    /// stream failure — or unparseable JSON — falls back to the buffered
    /// `generateRecap`, which yields a guaranteed-complete recap (a half-streamed
    /// recap must never be persisted as final).
    private func streamRecap(
        system: String,
        user: String,
        transcript: String,
        language: AppLanguage,
        meetingID: UUID
    ) async throws -> MeetingRecap {
        var accumulated = ""
        var lastPublish = Date.distantPast
        do {
            for try await delta in llm.streamComplete(system: system, user: user, jsonMode: true) {
                accumulated += delta
                // Re-parse + publish at ~6 fps. Each pass renders whatever
                // sections have fully closed so far; the trailing, still-
                // streaming section is ignored until it closes.
                let now = Date()
                if now.timeIntervalSince(lastPublish) >= 0.15 {
                    let sections = MeetingRecap.partialSections(fromStreamingJSON: accumulated)
                    if !sections.isEmpty {
                        meetingStore.updateStreamingSummary(id: meetingID, markdown: MeetingRecap.markdown(for: sections))
                    }
                    lastPublish = now
                }
            }
        } catch {
            Log.llm.error("recap stream failed after \(accumulated.count) chars — falling back to one-shot: \(error.localizedDescription)")
            return try await generateRecap(system: system, user: user, transcript: transcript, language: language)
        }

        let cleaned = LLMProxyClient.extractJSON(accumulated)
        guard let data = cleaned.data(using: .utf8),
              let recap = try? JSONDecoder().decode(MeetingRecap.self, from: data)
        else {
            Log.llm.error("recap stream produced unparseable JSON — falling back to one-shot")
            return try await generateRecap(system: system, user: user, transcript: transcript, language: language)
        }
        Log.llm.info("recap stream done — \(recap.sections.count) sections")
        // Settle the live view on the finished recap before any retry runs.
        meetingStore.updateStreamingSummary(id: meetingID, markdown: recap.toMarkdown())
        return try await refineRecapIfNeeded(recap, system: system, user: user, transcript: transcript, language: language)
    }

    /// Buffered one-shot recap — used for the rare mid-call `.summary` path and
    /// as `streamRecap`'s fallback. Shares the bounded retry below.
    private func generateRecap(system: String, user: String, transcript: String, language: AppLanguage) async throws -> MeetingRecap {
        let recap = try await llm.completeJSON(system: system, user: user, as: MeetingRecap.self)
        return try await refineRecapIfNeeded(recap, system: system, user: user, transcript: transcript, language: language)
    }

    /// One bounded retry that addresses whatever the first pass got wrong, shared
    /// by the streamed and one-shot recap paths. Two deterministic failure modes
    /// trigger it: (1) the model returned the "too short / unclear" fallback — or
    /// nothing grounded at all — on a substantive transcript; (2) the model
    /// ignored the language directive and wrote the recap in the wrong language
    /// (Gemini in JSON mode has been seen emitting Chinese for a Russian-selected,
    /// Russian-spoken meeting). Both are checked against the output, not trusted
    /// to the prompt. Returns the original recap when nothing needs fixing.
    private func refineRecapIfNeeded(
        _ recap: MeetingRecap,
        system: String,
        user: String,
        transcript: String,
        language: AppLanguage
    ) async throws -> MeetingRecap {
        var overrides: [String] = []

        if recap.isPlaceholderFallback || recap.isEmpty, transcriptHasSubstance(transcript) {
            Log.llm.info("summary empty/placeholder on substantive transcript — will retry")
            overrides.append("""
            RETRY OVERRIDE — EMPTY/FALLBACK:
            Your previous response \(
                recap.isEmpty ? "contained no grounded content" : "used the \"Transcript too short or unclear\" fallback"
            ), but this transcript has enough intelligible content to recap.
            Do NOT return an empty or fallback recap. Produce at least one section with 2-4 grounded bullets, translating non-English content into the requested output language.
            """)
        }

        if let got = Self.recapLanguageMismatch(recap, expected: language) {
            Log.llm.info("recap language mismatch got=\(got) expected=\(language.rawValue) — will retry")
            overrides.append("""
            RETRY OVERRIDE — LANGUAGE:
            Your previous response was written in the WRONG language (it came out in \(got)). Write EVERY string value — section titles and bullet text — in \(
                language.promptName
            ), and nothing else. Leave verbatim `quote` values exactly as spoken; JSON keys stay in English.
            """)
        }

        guard !overrides.isEmpty else { return recap }
        let retrySystem = system + "\n\n" + overrides.joined(separator: "\n\n")
        return try await llm.completeJSON(system: retrySystem, user: user, as: MeetingRecap.self)
    }

    /// Detects whether the recap's PROSE (section titles + bullet text, NOT the
    /// verbatim `quote` values, which stay in the spoken language) was written in
    /// a language other than the one the user selected. Returns the offending
    /// language code, or nil when it matches / is too short to call confidently.
    private static func recapLanguageMismatch(_ recap: MeetingRecap, expected: AppLanguage) -> String? {
        let prose = recap.sections.flatMap { section in
            [section.title] + section.bullets.map(\.text)
        }
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

    /// Array-based counterpart to `TranscriptStore.fullContext` so finalize can
    /// read a pinned snapshot, not the shared live store the next recording resets.
    private static func transcriptContext(from entries: [TranscriptEntry]) -> String {
        entries.map { "[\($0.source.label)]: \($0.text)" }.joined(separator: "\n")
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
            Log.ui.info("title rejected (empty or too long): len=\(line.count)")
            Log.ui.sensitive("title rejected: '\(line.prefix(40))…'")
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
