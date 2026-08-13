import CoreGraphics
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

/// Non-nil while the "still recording?" prompt is showing. `secondsRemaining`
/// counts down to an automatic, silence-trimmed end unless the user keeps
/// recording or ends it themselves.
struct AutoEndPrompt: Equatable {
    /// Why the meeting is about to end on its own. Both paths land on the same
    /// countdown and the same card — there is one way a recording auto-ends,
    /// and the user is told which of the two raised it.
    enum Reason: Equatable {
        /// Nothing has been said for a long stretch.
        case silence
        /// The conferencing app's call disappeared.
        case callEnded(app: String)
    }

    var secondsRemaining: Int
    var reason: Reason = .silence

    var title: String {
        switch reason {
        case .silence: "Still there?"
        case let .callEnded(app): "\(app) call ended"
        }
    }

    var icon: String {
        switch reason {
        case .silence: "nc-moon-stars"
        case .callEnded: "nc-phone"
        }
    }

    var detail: String {
        switch reason {
        case .silence: "No audio for a while — ending in \(clock)"
        case .callEnded: "Wrapping up and summarising in \(clock)"
        }
    }

    private var clock: String {
        let seconds = max(0, secondsRemaining)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Owns the recording lifecycle, mid-call generation, and end-of-meeting
/// persistence that used to live as @State + private funcs in ContentView.
/// One instance per floating panel — created in `showFloatingPanel` and
/// dropped with it, so session state dies on sign-out exactly like the old
/// view-local @State did.
@MainActor
final class MeetingSession: ObservableObject {
    /// What a start attempt did. `limitReached` is the allowance gate's cue;
    /// `blocked` is a recoverable in-app message (another recording is running).
    enum RecordingStartOutcome: Equatable {
        case started
        case limitReached
        case blocked(String)
        case failed(String)
    }

    @Published private(set) var meeting: MeetingState = .idle
    /// What the next recording will be. Chosen while idle; fixed for the
    /// duration of a recording so the recap framing + audio streams stay
    /// consistent from start to stop.
    @Published var selectedKind: SessionKind = .meeting
    @Published private(set) var elapsed: Int = 0
    @Published private(set) var micMuted: Bool = false
    /// Completed meetings still waiting to reach the server — drives the retry
    /// toast. Backed by the durable on-disk `MeetingOutbox`, so unlike the old
    /// in-memory queue these survive a quit / crash / app update and are
    /// replayed on the next launch; this array is just the UI mirror.
    @Published private(set) var pendingMeetingSaves: [Meeting] = []
    @Published private(set) var saveErrorToast: String?
    /// Drives the forgot-to-stop prompt; nil when no prompt is showing.
    @Published private(set) var autoEndPrompt: AutoEndPrompt?
    /// A start request is in flight (asking the server for a lease).
    @Published private(set) var isStartingRecording = false
    /// The previous meeting is still uploading its last chunks. A new recording
    /// stays blocked until this clears, or a fresh session would reset the shared
    /// transcribers underneath the finalize.
    @Published private(set) var isFinishingTranscription = false
    /// Non-nil when something outside the panel asked to start a meeting — the
    /// auto-detect card.
    ///
    /// Held as state rather than posted as a notification because the panel's
    /// SwiftUI content is not necessarily mounted at the moment the card is
    /// clicked (the panel is built at launch but only shown on request), and a
    /// notification posted then reaches nobody. `ContentView` consumes it
    /// whenever it next appears, so the request survives that gap.
    @Published private(set) var wantsAutoStart = false

    /// The meeting `endMeeting()` just handed to `meetingStore` for
    /// summarising, while that id is still worth showing the notch's own
    /// recap card for. `NotchModel` resolves it against `meetingStore`
    /// (generating → live partial → finished) and clears it back to nil once
    /// the user dismisses the card or starts recording again.
    @Published private(set) var justEndedMeetingID: UUID?

    /// The offer's own title (a calendar event or a detected call's window
    /// title), carried into the recording that started from it — nil for a
    /// manually-started recording, which has nothing to call itself yet. Real
    /// data captured at accept-time, not a live-generated title: nothing
    /// re-reads the transcript for this while the meeting is still running.
    @Published private(set) var liveTitle: String?
    /// Staged by `MeetingOffers.accept()` a moment before it clears `current` —
    /// `beginRecording()` claims it into `liveTitle` and empties this back out,
    /// so a manual Start right after a declined offer doesn't inherit its title.
    var pendingRecordingTitle: String?

    /// Inactivity-watchdog state. Silence is measured from the latest of
    /// `store.lastSpeechAt`, `inactivityResetAt` (a resume or a "keep recording"
    /// tap), and `recordingStartedAt`; `silenceBackoffMultiplier` grows on each
    /// "keep recording" so we nag less. While the prompt is up, `promptDeadline`
    /// is its wall-clock auto-end time and `speechAtPromptRaise` is the speech
    /// marker captured when it was raised — any change to it dismisses the prompt.
    private var inactivityResetAt: Date?
    private var promptDeadline: Date?
    private var speechAtPromptRaise: Date?
    /// Backoff factor on the silence threshold; doubles on each "keep recording"
    /// so repeat prompts get progressively rarer.
    private var silenceBackoffMultiplier: Double = 1
    /// Set when the user keeps a recording the *call* was said to have ended.
    /// Detection can flap — a conferencing window that reappears and goes again
    /// would otherwise re-raise the countdown every couple of minutes for the
    /// rest of the meeting. Cleared with the recording.
    private var autoFinishDeclined = false
    /// Silence needed to prompt when the user seems present (base) vs when
    /// they're idle at the keyboard/mouse — a strong "walked away" hint. A
    /// locked screen also stops delivering HID events, so idle subsumes lock;
    /// system sleep suspends the timer, so that silence accrues for free on wake.
    private static let autoEndBaseSilenceSeconds: TimeInterval = 600
    private static let autoEndAwaySilenceSeconds: TimeInterval = 180
    private static let autoEndMaxSilenceSeconds: TimeInterval = 2400
    private static let hidIdleAwaySeconds: TimeInterval = 300
    private static let maxSilenceBackoff: Double = 8
    private static let autoEndCountdownSeconds = 120
    /// Shorter than the silence countdown because the evidence is better: the
    /// call is demonstrably over, and the two minutes a silent stretch earns
    /// would just be two minutes of an empty room in the transcript.
    private static let callEndedCountdownSeconds = 30

    /// Wall-clock start of the current recording. Captured in beginRecording
    /// so we can stamp `started_at` accurately when we persist on summary.
    private var recordingStartedAt: Date?

    /// The lease this recording holds. Detached at End (so the finalize can
    /// close it after the last chunk) and released on every abandon path.
    private var activeMeetingLeaseID: UUID?

    /// The meeting currently being recorded — created at `beginRecording` so the
    /// live transcript can stream to the server under a stable id, then reused
    /// (same id) when the summary is stamped at End. nil while idle, or when no
    /// auth session existed at record time.
    ///
    /// Mirrored into `meetingStore.recordingMeetingID` on every change: the
    /// live draft syncs into `MeetingStore.meetings` within seconds of
    /// starting (looking identical to old, still-blank drafts), so Sessions
    /// needs this to tell them apart without importing `MeetingSession`
    /// itself, which `Core` must never depend on.
    private var recordingDraft: Meeting? {
        didSet { meetingStore.setRecordingMeetingID(recordingDraft?.id) }
    }

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
    ///
    /// Derived from `TranscriptStore.reorderHorizon` (+1s tick margin) so it
    /// stays strictly above it: streaming freezes an entry's positional `idx`,
    /// and reordering must have stopped first or that key corrupts.
    private static let streamSettleWindow: TimeInterval = TranscriptStore.reorderHorizon + 1
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
    private let actionItemStore: ActionItemStore
    private let language: LanguagePreference
    private let proactivity: ProactivityPreference
    private let auth: AuthService
    private let profileStore: ProfileStore
    private let outbox: MeetingOutbox
    private let modeStore: ModeStore
    private let screenExclusions: ScreenExclusions
    private let calendar: CalendarService
    private let analytics: ProductAnalytics
    private let recapGenerator: RecapGenerator
    private var captureID: UUID?

    /// What Nod hears while the meeting is still running. Built here rather than
    /// injected because its life is exactly this session's — like
    /// `recapGenerator` — and because the finalize below needs what it found.
    let analyst: LiveMeetingAnalyst

    init(
        audioCapture: AudioCaptureService,
        store: TranscriptStore,
        llm: LLMProxyClient,
        meetingStore: MeetingStore,
        entityStore: EntityStore,
        knowledgeStore: KnowledgeStore,
        actionItemStore: ActionItemStore,
        language: LanguagePreference,
        proactivity: ProactivityPreference,
        auth: AuthService,
        profileStore: ProfileStore,
        outbox: MeetingOutbox,
        modeStore: ModeStore,
        screenExclusions: ScreenExclusions,
        calendar: CalendarService,
        analytics: ProductAnalytics
    ) {
        self.audioCapture = audioCapture
        self.store = store
        self.llm = llm
        self.meetingStore = meetingStore
        self.entityStore = entityStore
        self.knowledgeStore = knowledgeStore
        self.actionItemStore = actionItemStore
        self.language = language
        self.proactivity = proactivity
        self.auth = auth
        self.profileStore = profileStore
        self.outbox = outbox
        self.modeStore = modeStore
        self.screenExclusions = screenExclusions
        self.calendar = calendar
        self.analytics = analytics
        recapGenerator = RecapGenerator(llm: llm)
        analyst = LiveMeetingAnalyst(llm: llm, store: store, proactivity: proactivity)
    }

    deinit {
        // A sign-out drops the session mid-recording; stop the streaming loop so
        // it doesn't outlive the panel. The WAL on disk keeps whatever streamed.
        streamTask?.cancel()
        rosterTask?.cancel()
    }

    /// Everyone a conferencing app has named on this call so far, used to tell
    /// diarization how many voices to expect. Accumulated across samples — see
    /// `MeetingRoster.merging`.
    private var roster: MeetingRoster?

    private var rosterTask: Task<Void, Never>?

    /// How often the participant list is re-read while recording.
    ///
    /// Sampling once at the start read the roster at the worst possible moment:
    /// recording begins as people are still joining and before anyone has opened
    /// the participant panel, so a five-person call routinely produced no count
    /// at all and clustering fell back to its length-sensitive threshold. Loose
    /// on purpose — a participant list changes a handful of times per call, and
    /// each sample is an accessibility walk of the app's windows.
    private static let rosterSampleInterval: TimeInterval = 15

    /// `media` stays opt-in until music-heavy audio is validated — soundtracks
    /// cluster into speakers that don't exist.
    private var shouldDiarize: Bool {
        guard selectedKind.supportsDiarization else { return false }
        return selectedKind != .media || DiarizationDefaults.includesMedia
    }

    /// Always-on personal context prepended to every LLM system prompt so
    /// recaps and live cards read as if Nod already knows the user. "" when
    /// the profile is empty.
    private var profileContext: String {
        profileStore.promptContext
    }

    func runSecondsTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if meeting == .recording { elapsed += 1 }
            tickInactivity()
        }
    }

    /// Once a second while recording: raise the forgot-to-stop prompt after a
    /// stretch of silence on both streams, count it down, and auto-end (trimmed
    /// to the last speech) if the user doesn't respond. A resumed conversation
    /// after the prompt dismisses it.
    private func tickInactivity() {
        guard meeting == .recording else {
            if autoEndPrompt != nil { clearAutoEndPrompt() }
            return
        }
        let now = Date()

        if autoEndPrompt != nil {
            // Any new confirmed speech since the prompt was raised means the
            // meeting is still live — dismiss, whichever reason raised it.
            // Comparing the whole timestamp (not onset-vs-raise) catches a chunk
            // that finalizes during the countdown even though its speech started
            // just before the prompt, so a continuous talker can't be auto-ended
            // mid-sentence. That looseness also lets a chunk from *during* the
            // call cancel a `.callEnded` countdown, which is the trade taken
            // deliberately: it costs a recording that runs to the silence
            // watchdog instead, where an onset-vs-raise comparison would cost a
            // meeting cut off in the middle of a sentence.
            if store.lastSpeechAt != speechAtPromptRaise {
                clearAutoEndPrompt()
                return
            }
            // Wall-clock deadline, not a tick count, so main-thread jitter can't
            // stretch "2:00" past two real minutes.
            let remaining = (promptDeadline ?? now).timeIntervalSince(now)
            if remaining <= 0 {
                clearAutoEndPrompt()
                Log.ui.info("auto-ending meeting after inactivity")
                endMeeting()
            } else {
                let secs = Int(remaining.rounded(.up))
                if autoEndPrompt?.secondsRemaining != secs {
                    autoEndPrompt?.secondsRemaining = secs
                }
            }
            return
        }

        let lastActivity = [store.lastSpeechAt, inactivityResetAt, recordingStartedAt]
            .compactMap { $0 }
            .max() ?? now
        let silence = now.timeIntervalSince(lastActivity)
        let away = hidIdleSeconds() >= Self.hidIdleAwaySeconds
        let base = away ? Self.autoEndAwaySilenceSeconds : Self.autoEndBaseSilenceSeconds
        let threshold = min(base * silenceBackoffMultiplier, Self.autoEndMaxSilenceSeconds)
        if silence >= threshold {
            promptDeadline = now.addingTimeInterval(TimeInterval(Self.autoEndCountdownSeconds))
            speechAtPromptRaise = store.lastSpeechAt
            autoEndPrompt = AutoEndPrompt(secondsRemaining: Self.autoEndCountdownSeconds)
            raisePanelForPrompt()
            Log.ui.info("inactivity prompt raised (silence \(Int(silence))s, away=\(away))")
        }
    }

    /// The countdown card lives inside the panel, and a hidden panel keeps its
    /// SwiftUI content mounted — so without this the clock runs, the recording
    /// ends, and the user is shown nothing but a sound they may not connect to
    /// anything. Nothing that can stop a recording may count down out of sight.
    private func raisePanelForPrompt() {
        UISound.actionRequired.play(recording: true)
        NotificationCenter.default.post(name: .nodShowPanel, object: nil)
    }

    private func clearAutoEndPrompt() {
        autoEndPrompt = nil
        promptDeadline = nil
        speechAtPromptRaise = nil
    }

    /// The call this recording was following has ended, per `MeetingDetector`.
    ///
    /// Raises the same countdown the silence watchdog uses rather than ending
    /// outright, and the countdown dies the moment anyone speaks: a call whose
    /// process is gone is still only evidence that the *call* ended, not that
    /// the conversation did. Thirty seconds with a keep button is the difference
    /// between "Nod wrapped up after the call" and "Nod cut me off".
    ///
    /// Only for `meeting` — a voice note that happened to be running while a
    /// call ended has nothing to do with that call.
    func callEnded(app: String) {
        guard meeting == .recording, selectedKind == .meeting, !autoFinishDeclined else { return }
        if case .callEnded = autoEndPrompt?.reason { return }
        let now = Date()
        promptDeadline = now.addingTimeInterval(TimeInterval(Self.callEndedCountdownSeconds))
        speechAtPromptRaise = store.lastSpeechAt
        autoEndPrompt = AutoEndPrompt(
            secondsRemaining: Self.callEndedCountdownSeconds,
            reason: .callEnded(app: app)
        )
        raisePanelForPrompt()
        Log.ui.info("\(app) call ended — finishing in \(Self.callEndedCountdownSeconds)s")
    }

    /// Seconds since the last keyboard/mouse event. A locked screen or a user
    /// who walked away both read as idle here, letting us shorten the
    /// silence-to-prompt wait.
    private func hidIdleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: - Recording lifecycle

    /// Ask the panel to start a meeting — the auto-detect card's only power.
    ///
    /// It deliberately stops one step short of recording: the subscription
    /// check, the consent disclaimer and the language confirm all live on the
    /// panel's Start path, and nothing may reach `beginRecording` around them.
    /// Raises the surface as well as setting the flag. The consent and language
    /// gates render *in* the notch, so a caller that asks for a recording
    /// without raising it sets the flag with nowhere for the gate to appear —
    /// an invariant two offer surfaces used to restate side by side.
    func requestAutoStart() {
        guard meeting == .idle else { return }
        NotificationCenter.default.post(name: .nodShowPanel, object: nil)
        selectedKind = .meeting
        wantsAutoStart = true
    }

    func clearAutoStartRequest() {
        wantsAutoStart = false
    }

    /// Asks the server to admit a new recording, then starts capture under the
    /// id it granted. The allowance is checked here, once — never per chunk — so
    /// a meeting already running is never cut off by it.
    func requestRecordingStart() async -> RecordingStartOutcome {
        guard isFinishingTranscription == false else {
            return .failed("The previous meeting is still finishing.")
        }
        guard meeting == .idle, !isStartingRecording else {
            return .failed("A meeting is already starting.")
        }
        guard let userID = auth.currentSupabaseSession?.user.id else {
            return .failed("Session expired, please sign in again.")
        }

        isStartingRecording = true
        defer { isStartingRecording = false }
        let meetingID = UUID()

        do {
            try await llm.startMeetingLease(meetingID: meetingID)
        } catch LLMProxyClient.ClientError.meetingLimitReached {
            return .limitReached
        } catch let LLMProxyClient.ClientError.meetingBlocked(reason) {
            return .blocked(reason)
        } catch {
            // The lease may have been granted before the response was lost, so
            // hand it back rather than leaving a slot held by nobody.
            Task { await llm.endMeetingLease(meetingID: meetingID) }
            return .failed(error.localizedDescription)
        }

        // The user may have cancelled, signed out, or started something else
        // while the round-trip was in flight.
        guard meeting == .idle,
              auth.currentSupabaseSession?.user.id == userID,
              !Task.isCancelled
        else {
            await llm.endMeetingLease(meetingID: meetingID)
            return .failed("Meeting start was cancelled.")
        }

        activeMeetingLeaseID = meetingID
        beginRecording(meetingID: meetingID, userID: userID)
        return .started
    }

    private func beginRecording(meetingID: UUID, userID: UUID) {
        Log.ui.info("Start Meeting")
        sessionGeneration += 1
        let captureID = UUID()
        self.captureID = captureID
        analytics.record(
            .captureStartRequested,
            captureID: captureID,
            properties: .init(
                sessionKind: selectedKind.rawValue,
                entryPoint: .floatingPanel,
                stage: .capture,
                surface: .capture
            )
        )
        meeting = .recording
        liveTitle = pendingRecordingTitle
        pendingRecordingTitle = nil
        // Only kinds that carry personal to-dos are worth listening to live —
        // the same gate the finalize applies before writing any of this down.
        analyst.reset()
        // The recall pass needs three things the analyst has no business
        // holding itself: which session to exclude from its own search, how to
        // turn a session id into something a person can read, and the output
        // language.
        analyst.currentMeetingID = recordingDraft?.id
        analyst.recallLanguage = language.current
        analyst.recallSourceLabel = { [weak meetingStore] id in
            guard let meeting = meetingStore?.meetings.first(where: { $0.id == id }) else { return nil }
            return meeting.displayTitle(dateFormatter: Meeting.listDateFormatter)
        }
        if selectedKind.extractsActionItems { analyst.start() }
        knowledgeStore.isCapturing = true
        elapsed = 0
        clearAutoEndPrompt()
        wantsAutoStart = false
        autoFinishDeclined = false
        inactivityResetAt = nil
        silenceBackoffMultiplier = 1
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
        let draft = Meeting.newCompleted(
            id: meetingID,
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

        if shouldDiarize {
            startRosterSampling()
        }
        Task {
            await store.start(meetingID: meetingID, diarizing: shouldDiarize)
            // The lease can be taken over while the models warm up; if this is no
            // longer the active recording, stop instead of capturing audio the
            // server will refuse.
            guard activeMeetingLeaseID == meetingID, meeting != .idle else {
                store.stop()
                return
            }
            await audioCapture.start(
                captureMic: selectedKind.capturesMic,
                captureSystem: selectedKind.capturesSystem
            )
            if audioCapture.lastError == nil {
                analytics.record(
                    .captureStarted,
                    captureID: captureID,
                    properties: .init(
                        sessionKind: selectedKind.rawValue,
                        entryPoint: .floatingPanel,
                        stage: .audio,
                        surface: .capture,
                        outcome: .success
                    )
                )
            } else {
                analytics.record(
                    .captureFailed,
                    captureID: captureID,
                    properties: .init(
                        sessionKind: selectedKind.rawValue,
                        entryPoint: .floatingPanel,
                        stage: .audio,
                        reasonCode: .audioStartFailed,
                        surface: .capture,
                        outcome: .failure
                    )
                )
            }
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

    /// Tail kept after the last detected speech when trimming trailing silence —
    /// covers Whisper latency plus the final in-flight VAD segment.
    private static let trailingSilenceTailSeconds: TimeInterval = 30

    /// End time clamped so a forgot-to-stop tail of dead air can't inflate the
    /// meeting's duration: `lastSpeech + tail`, bounded to `[startedAt, now]`.
    /// Falls back to `now` when there was no speech; a normal stop right after
    /// talking also lands on `now` because `lastSpeech + tail` exceeds it.
    private static func trimmedEndDate(startedAt: Date, lastSpeechAt: Date?) -> Date {
        let now = Date()
        guard let lastSpeechAt else { return now }
        let trimmed = lastSpeechAt.addingTimeInterval(trailingSilenceTailSeconds)
        return max(startedAt, min(now, trimmed))
    }

    func endMeeting() {
        // Idempotent: the auto-end tick, the prompt's End button, and the
        // capsule/StatusRow End can all race to call this; a second entry after
        // the first has reset to idle would mint a fresh id and double-persist.
        guard meeting != .idle else { return }
        Log.ui.info("End Meeting — entries=\(store.entries.count)")
        let endedCaptureID = captureID
        analytics.record(
            .captureStopped,
            captureID: endedCaptureID,
            properties: .init(
                sessionKind: selectedKind.rawValue,
                entryPoint: .floatingPanel,
                stage: .capture,
                surface: .capture,
                outcome: .success
            )
        )
        isFinishingTranscription = true
        store.stop()
        // Stopped, not reset: the finalize still has to write down what it
        // found, and that runs after the surface is back at rest.
        analyst.stop()
        Task { await audioCapture.stop() }
        let meetingLeaseID = detachActiveMeetingLease()
        streamTask?.cancel()
        streamTask = nil
        // Before the finalize below reads the count: the call is over, so no
        // later sample can add anything, and one landing mid-finalize would
        // race the read.
        stopRosterSampling()

        let recordingDraftID = recordingDraft?.id
        recordingDraft = nil

        guard store.hasContent else {
            analytics.record(
                .captureDiscarded,
                captureID: endedCaptureID,
                properties: .init(
                    sessionKind: selectedKind.rawValue,
                    entryPoint: .floatingPanel,
                    stage: .finalization,
                    reasonCode: .userCancelled,
                    surface: .capture,
                    outcome: .cancelled
                )
            )
            // Empty start→stop: drop the WAL entry so no orphan row is created.
            endMeetingLeaseNow(meetingLeaseID)
            if let id = recordingDraftID { Task { await outbox.discard(id) } }
            cleanupToIdle()
            return
        }
        guard let userID = auth.currentSupabaseSession?.user.id else {
            Log.ui.error("End Meeting skipped — no session")
            endMeetingLeaseNow(meetingLeaseID)
            if let id = recordingDraftID { Task { await outbox.discard(id) } }
            cleanupToIdle()
            return
        }

        // Snapshot the recording bookends + session config BEFORE the async
        // work — endedAt marks the user's stop, not the summary-ready instant,
        // and the kind/language shouldn't shift if the user reconfigures while
        // the summary generates.
        let startedAt = recordingStartedAt ?? Date()
        let endedAt = Self.trimmedEndDate(startedAt: startedAt, lastSpeechAt: store.lastSpeechAt)
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
            // The leased id, so the lease, every chunk, the WAL row and the
            // final meeting are all one identity.
            id: recordingDraftID ?? meetingLeaseID ?? UUID(),
            userID: userID,
            createdAt: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            title: nil,
            kind: kind,
            summary: "",
            recap: nil,
            language: langCode,
            speakerNames: nil,
            deletedAt: nil
        )
        meetingStore.beginGenerating(draft)
        // The notch picks this up and shows the recap card itself — see
        // `NotchModel.derived()` — so nothing opens the full window on its
        // own anymore; that's still one click away for anyone who wants it.
        justEndedMeetingID = draft.id
        resetPanelForIdle()

        let draftID = draft.id
        // Pin this meeting's transcript on the main thread, before any await: the
        // store + transcribers are shared and reused by the next recording, so a
        // meeting started while this one summarises (the recap stream takes many
        // seconds) would reset them out from under the finalize.
        let pinnedEntries = store.entries
        // Pinned for the same reason as the entries, and it was missed: the
        // roster field is shared with the next recording too. Read inside the
        // Task it would be whatever *that* meeting had accumulated by then —
        // an inflated speaker count here, and its participants' names in this
        // meeting's recap prompt.
        let pinnedRoster = consumeRoster()
        // And pinned for the third time for the same reason. `beginRecording`
        // resets the analyst, so a meeting started while this one summarises
        // would empty these — and worse, by the time `enrich` runs they would be
        // the *next* meeting's findings, written as this meeting's rows.
        let pinnedFindings = analyst.findings
        // Asked here rather than when the recording started, because the entry
        // often does not exist yet at that point — people create the invite two
        // minutes before, or halfway through. By now the span is final, so one
        // query answers "created before" and "created during" alike, and it
        // answers against what was actually captured instead of a guess made at
        // the first second.
        let scheduled = calendar.meetings(
            overlapping: DateInterval(start: draft.startedAt, end: max(draft.startedAt, draft.endedAt))
        ).first
        let people = MeetingParticipants.resolve(calendar: scheduled, roster: pinnedRoster)
        Log.stt.info("participants: \(people.names.count) name(s), \(people.expectedOtherVoices) other voice(s) — \(people.source)")
        if shouldDiarize { meetingStore.beginResolvingSpeakers(id: draft.id) }
        Task {
            // Every exit of this Task clears the "labels still resolving" flag —
            // unless clustering overran and `applyLateSpeakers` took ownership,
            // because that pass is what rewrites the labels next.
            var lateRelabelOwnsFlag = false
            defer {
                if !lateRelabelOwnsFlag { meetingStore.finishResolvingSpeakers(id: draftID) }
            }
            // Ensure a WAL entry exists even on the fallback path — idempotent,
            // so a streamed meeting keeps its progress.
            await outbox.begin(draft)

            await store.flushPending()
            isFinishingTranscription = false
            // Only now: every chunk has either landed or been given up on, so
            // closing the lease cannot refuse audio that is still in flight.
            if let meetingLeaseID {
                await llm.endMeetingLease(meetingID: meetingLeaseID)
            }

            // Clustering a long call costs minutes, and the recap prompt wants
            // the labels, so the finalize does wait here — but only for
            // `speakerJoinTimeout`. Past that the summary is generated from an
            // unlabelled transcript rather than making the user watch
            // "Generating…" for minutes, and a result that lands late relabels
            // the persisted rows in `applyLateSpeakers`.
            let expectedSpeakers = people.expectedOtherVoices
            let participants = people.names
            let speakerTask = Task { await store.resolveSpeakers(expectedSpeakerCount: expectedSpeakers) }
            let speakers = await Self.value(of: speakerTask, within: Self.speakerJoinTimeout) ?? [:]

            // Prefer the post-flush transcript (it includes the last in-flight
            // chunk) while this is still the active session; if a newer recording
            // took over the store during flush, fall back to the pinned snapshot
            // so this meeting is still persisted instead of silently dropped.
            let entriesSnapshot = sessionGeneration == generation ? store.entries : pinnedEntries
            let clustered = Self.transcriptContext(from: entriesSnapshot, speakers: speakers)
            guard !clustered.isEmpty else {
                if sessionGeneration == generation { store.clear() }
                await outbox.discard(draftID)
                meetingStore.markGenerationFailed(id: draftID, errorMessage: "⚠️ No transcript captured")
                return
            }

            // Names before the recap, not after it: the recap is the artefact
            // the user keeps and shares, and it can only write a name it was
            // handed one for. Resolved afterwards, the summary froze around
            // "Speaker 2" while the transcript chips underneath were relabelled
            // — one meeting, two views, permanently disagreeing.
            let speakerNames = speakers.isEmpty
                ? [:]
                : await nameSpeakers(
                    in: clustered,
                    people: people,
                    clusters: Array(Set(speakers.values))
                )
            let context = speakerNames.isEmpty
                ? clustered
                : Self.transcriptContext(from: entriesSnapshot, speakers: speakers, names: speakerNames)
            // Carried on the draft rather than patched in afterwards, so the
            // names land in the same INSERT as the meeting instead of needing
            // the row to exist first.
            var named = draft
            named.speakerNames = speakerNames.isEmpty ? nil : speakerNames

            let (system, user) = PromptLibrary.build(
                transcript: context,
                language: lang,
                personalContext: profile,
                sessionKind: draft.kind,
                summaryTemplate: framing.summary,
                modeFocus: framing.focus,
                meetingDate: PromptLibrary.sessionDateString(startedAt),
                participants: participants,
                liveNotes: LiveFinding.notes(from: pinnedFindings)
            )

            do {
                let recap = try await recapGenerator.streamedRecap(
                    system: system,
                    user: user,
                    transcript: context,
                    language: lang
                ) { [meetingStore] markdown in
                    meetingStore.updateStreamingSummary(id: draftID, markdown: markdown)
                }
                let text = recap.toMarkdown()
                // Title is best-effort — failure here doesn't block
                // persistence; Meeting.displayTitle falls back to a
                // date label.
                let title = await recapGenerator.title(from: text, language: lang)
                let updated = named.updating(title: title, summary: text, recap: recap)
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
                let records = transcriptRecords(from: entriesSnapshot, meeting: updated, speakers: speakers)
                await outbox.complete(updated, transcripts: records, for: updated.id)
                await drainOutbox()
                meetingStore.finishFinalizing(id: updated.id)
                // The recap can land a minute after the user stopped and walked
                // off. Only on the path where one was actually written — the
                // fallback below saves the transcript under a "summary failed"
                // note, which is not something to chime about.
                UISound.summaryReady.play(recording: meeting != .idle)

                // Detached on purpose: the relabel is best-effort, and awaiting
                // it here would hold entity extraction and embedding indexing —
                // what makes the meeting findable — behind the whole clustering
                // pass on exactly the long calls that overran the join timeout.
                if speakers.isEmpty {
                    lateRelabelOwnsFlag = true
                    Task {
                        await self.applyLateSpeakers(
                            from: speakerTask,
                            entries: entriesSnapshot,
                            meeting: updated,
                            people: people
                        )
                    }
                }

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
                    await enrich(
                        updated,
                        userID: userID,
                        transcript: context,
                        recap: recap,
                        participants: participants,
                        live: pinnedFindings
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
                let fallback = draft.updating(title: nil, summary: Meeting.summaryUnavailableNote)
                // Whatever the join timeout already produced, never
                // `speakerTask.value`: waiting out a multi-minute clustering
                // pass here would hold the WAL write hostage on precisely the
                // path where the summary already failed.
                let records = transcriptRecords(
                    from: entriesSnapshot,
                    meeting: fallback,
                    speakers: speakers
                )
                await outbox.complete(fallback, transcripts: records, for: draftID)
                await drainOutbox()
                if sessionGeneration == generation { store.clear() }
                Log.ui.error("Meeting summary generation failed: \(error.localizedDescription)")
                // The same note the WAL and the server row carry, not the raw
                // error: the detail view keys the "Generate summary" retry off
                // it, and a cache that reads differently from the persisted row
                // would hide that retry until the next refresh.
                meetingStore.markGenerationFailed(
                    id: draftID,
                    errorMessage: Meeting.summaryUnavailableNote
                )
            }
        }
    }

    /// Reset the panel to its ready state without touching the transcript —
    /// used when the post-meeting finalize still needs `store` to snapshot it.
    private func resetPanelForIdle() {
        meeting = .idle
        knowledgeStore.isCapturing = false
        elapsed = 0
        micMuted = false
        liveTitle = nil
        captureID = nil
        clearAutoEndPrompt()
    }

    /// The recap card's own close glyph. The meeting itself is untouched —
    /// this only stops the notch from showing it; `meetingStore`/History still
    /// have it.
    func dismissEndedMeeting() {
        justEndedMeetingID = nil
    }

    /// The recap card's Copy. Recorded here rather than from the card because
    /// this is where the analytics dependency already lives, and because the
    /// notch is not the meeting detail view: `recordMeetingInteraction` hard-
    /// codes `meetingDetail` for both entry point and surface, so calling it
    /// would file this under a screen the user never opened. Same
    /// `floatingPanel` / `capture` pair every other event from this surface
    /// carries.
    ///
    /// No `captureID`: `resetPanelForIdle` clears it on the line after the one
    /// that puts this card on screen, so it is always nil by the time anyone
    /// can press Copy. The detail view's copy event carries none either.
    func recordRecapCopied(kind: SessionKind) {
        analytics.record(
            .contentCopied,
            properties: .init(
                sessionKind: kind.rawValue,
                entryPoint: .floatingPanel,
                surface: .capture,
                contentType: .summary,
                outcome: .success
            )
        )
    }

    /// The allowance gate lives in the notch, which has no analytics of its own.
    /// One entry point keeps the recorder a private dependency.
    func recordAllowanceGate(
        _ event: ProductAnalytics.Event,
        outcome: ProductAnalytics.Outcome,
        plan: String? = nil,
        billing: String? = nil
    ) {
        analytics.record(
            event,
            properties: .init(
                entryPoint: .notch,
                stage: .entitlement,
                reasonCode: .hoursExhausted,
                surface: .capture,
                outcome: outcome,
                plan: plan,
                billing: billing
            )
        )
    }

    private func detachActiveMeetingLease() -> UUID? {
        let meetingID = activeMeetingLeaseID
        activeMeetingLeaseID = nil
        return meetingID
    }

    private func endMeetingLeaseNow(_ meetingID: UUID?) {
        guard let meetingID else { return }
        Task { await llm.endMeetingLease(meetingID: meetingID) }
    }

    private func cleanupToIdle() {
        isFinishingTranscription = false
        endMeetingLeaseNow(detachActiveMeetingLease())
        streamTask?.cancel()
        streamTask = nil
        stopRosterSampling()
        recordingDraft = nil
        wantsAutoStart = false
        autoFinishDeclined = false
        // Participant names are session-scoped by policy (privacy.md § 3.10):
        // they exist to size the clustering pass and must not outlive it.
        roster = nil
        resetPanelForIdle()
        store.clear()
        // The findings themselves outlive this — `enrich` has not necessarily
        // run yet — but nothing should still be showing one.
        analyst.dismissNotice()
    }

    func toggleRecording() {
        switch meeting {
        case .idle:
            break
        case .recording:
            Log.ui.info("Pause")
            meeting = .paused
            audioCapture.pause()
            // A paused recording hears nothing, so it must cost nothing.
            analyst.stop()
        case .paused:
            Log.ui.info("Resume")
            meeting = .recording
            if selectedKind.extractsActionItems { analyst.start() }
            // Measure post-resume silence from now, not from the last pre-pause
            // speech, so resuming doesn't instantly trip the inactivity prompt.
            inactivityResetAt = Date()
            Task { await audioCapture.resume() }
        }
    }

    /// User dismissed the forgot-to-stop prompt — keep recording, and back off
    /// the silence threshold (doubling, capped) so we don't nag on the next
    /// quiet stretch.
    func keepRecording() {
        if case .callEnded = autoEndPrompt?.reason {
            // They've told us the conversation outlived the call; rejoining and
            // leaving again must not raise this a second time for this recording.
            autoFinishDeclined = true
        }
        clearAutoEndPrompt()
        inactivityResetAt = Date()
        silenceBackoffMultiplier = min(silenceBackoffMultiplier * 2, Self.maxSilenceBackoff)
        Log.ui.info("user kept recording — silence backoff ×\(Int(silenceBackoffMultiplier))")
    }

    func toggleMic() {
        micMuted.toggle()
        audioCapture.setMicMuted(micMuted)
        Log.ui.info(micMuted ? "mic muted" : "mic unmuted")
    }

    // MARK: - Meeting persistence (issue #14)

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
    /// `names` maps a cluster number to the person behind it, so a transcript
    /// handed to the recap reads `[Them · Andy]` rather than `[Them · Speaker 3]`
    /// — the recap can only write a name it was given one for.
    private static func transcriptContext(
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
    private func transcriptRecords(
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

    /// How long the finalize waits for clustering before persisting without
    /// speakers. A short call lands well inside this; an hour-long one does not,
    /// and its rows are relabelled by `applyLateSpeakers` instead of making the
    /// user watch "Generating…" for minutes.
    private static let speakerJoinTimeout: TimeInterval = 30

    /// `task.value`, or nil if it hasn't finished within `timeout`. The task
    /// keeps running — the caller decides what to do with a late result.
    private static func value<T: Sendable>(of task: Task<T, Never>, within timeout: TimeInterval) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first.flatMap { $0 }
        }
    }

    /// Rewrites the already-persisted transcript rows once a slow clustering
    /// pass finishes. Rows are upserted by the same ids, so this updates them in
    /// place rather than duplicating the transcript.
    private func applyLateSpeakers(
        from task: Task<[UUID: Int], Never>,
        entries: [TranscriptEntry],
        meeting: Meeting,
        people: MeetingParticipants
    ) async {
        defer { meetingStore.finishResolvingSpeakers(id: meeting.id) }
        let speakers = await task.value
        guard !speakers.isEmpty else { return }

        let records = transcriptRecords(from: entries, meeting: meeting, speakers: speakers)
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
        let context = Self.transcriptContext(from: entries, speakers: speakers)
        let names = await nameSpeakers(
            in: context,
            people: people,
            clusters: Array(Set(speakers.values))
        )
        guard !names.isEmpty else { return }
        do {
            try await meetingStore.updateSpeakerNames(names, for: meeting.id)
        } catch {
            Log.ui.error("speaker naming failed (non-fatal): \(error.localizedDescription)")
        }
    }

    /// Re-reads the conferencing app's participant list off the main actor for
    /// as long as the recording runs, accumulating what it finds. Purely
    /// additive: no roster at all simply means diarization falls back to its
    /// distance threshold.
    private func startRosterSampling() {
        rosterTask?.cancel()
        rosterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rules = screenExclusions.rules
                let sampled = await Task.detached(priority: .utility) {
                    MeetingRosterReader(exclusions: rules).sample()
                }.value
                // A walk in flight when the meeting ended must not resurrect a
                // roster the finalize has already consumed.
                guard !Task.isCancelled else { return }
                if let sampled {
                    let before = roster?.speakerCount ?? 0
                    let merged = roster?.merging(sampled) ?? sampled
                    roster = merged
                    if merged.speakerCount != before {
                        Log.screen.info("roster: \(merged.app.displayName) — \(merged.speakerCount) participant(s) so far")
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.rosterSampleInterval * 1_000_000_000))
            }
        }
    }

    private func stopRosterSampling() {
        rosterTask?.cancel()
        rosterTask = nil
    }

    /// Hands this session's roster to its finalize and clears the field.
    ///
    /// Taken once and dropped: the names are session-scoped by policy
    /// (privacy.md § 3.10), and the next recording must start from nothing
    /// rather than merge into what this one left behind.
    private func consumeRoster() -> MeetingRoster? {
        defer { roster = nil }
        return roster
    }

    /// Best-effort entity extraction — links the saved session to the
    /// people / projects / topics it mentions so "Related sessions" can find
    /// it. Runs after persistence; a failure here never affects the meeting.
    /// Everything a meeting gets once it has durably landed: to-dos, entities,
    /// speaker names, and the embeddings that make it searchable. All
    /// best-effort — the meeting is already saved, and none of this can change
    /// what the user sees in the recap.
    private func enrich(
        _ meeting: Meeting,
        userID: UUID,
        transcript: String,
        recap: MeetingRecap,
        participants: [String],
        live: [LiveFinding]
    ) async {
        // Only kinds that carry personal to-dos (meeting / voice note) —
        // passive media has none.
        if meeting.kind.extractsActionItems {
            await actionItemStore.saveExtracted(
                recap.actionItems,
                live: live,
                meetingID: meeting.id,
                userID: userID
            )
        }
        await extractEntities(
            meetingID: meeting.id,
            userID: userID,
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

    /// Which diarized cluster is which person, from the transcript's own
    /// evidence plus whatever the conferencing app's roster named.
    ///
    /// Best-effort by design, and an empty map is the expected answer for most
    /// meetings: unnamed clusters make the recap authorless, which is honest,
    /// while a guessed name ships a lie into something the user shares.
    private func nameSpeakers(
        in transcript: String,
        people: MeetingParticipants,
        clusters: [Int]
    ) async -> [String: String] {
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
        return closed
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
