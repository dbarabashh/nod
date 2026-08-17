import AppKit
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

/// What a start attempt did. `limitReached` is the allowance gate's cue;
/// `blocked` is a recoverable in-app message (another recording is running).
///
/// At file scope beside `MeetingState`, not nested in `MeetingSession`: it
/// carries none of the session's state, and the class sits on the
/// `type_body_length` ceiling that SwiftLint fails the build over.
enum RecordingStartOutcome: Equatable {
    case started
    case limitReached
    case blocked(String)
    case failed(Failure)
    /// A colleague turned out to be recording this meeting already. Not a
    /// failure and deliberately not an error message: nothing went wrong, and
    /// the surface has a better answer than a sentence. The room card is what
    /// the notch resolves to on its own once a room is known, and it keeps
    /// "record my own" one press away for the person who meant it.
    case roomAvailable

    enum Failure: Equatable {
        case finishing
        case startInProgress
        case authentication
        case lease(String)
        case cancelled

        var message: String {
            switch self {
            case .finishing: "The previous meeting is still finishing."
            case .startInProgress: "A meeting is already starting."
            case .authentication: "Session expired, please sign in again."
            case let .lease(message): message
            case .cancelled: "Meeting start was cancelled."
            }
        }

        var analyticsStage: ProductAnalytics.Stage {
            switch self {
            case .finishing: .finalization
            case .startInProgress, .cancelled: .capture
            case .authentication: .authentication
            case .lease: .entitlement
            }
        }

        var analyticsReason: ProductAnalytics.ReasonCode {
            switch self {
            case .finishing, .startInProgress: .interrupted
            case .authentication: .authenticationFailed
            case .lease: .unknown
            case .cancelled: .userCancelled
            }
        }
    }
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

    /// A colleague already recording this same meeting, when the server can tell.
    /// Purely informational — nothing about the recording changes because of it.
    @Published private(set) var concurrentRecording: ConcurrentRecording?

    /// The one way this is written, so the split-out identity code cannot become
    /// a second place that decides when it is shown.
    func setConcurrentRecording(_ value: ConcurrentRecording?) {
        concurrentRecording = value
    }

    var concurrentCheck: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?

    /// The recording under way, for the surfaces that have to ask the server
    /// about it. Nil whenever nothing is being recorded.
    /// Staged by `MeetingOffers.accept()` a moment before it clears `current` —
    /// `beginRecording()` claims it into `liveTitle` and empties this back out,
    /// so a manual Start right after a declined offer doesn't inherit its title.
    var pendingRecordingTitle: String?

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
    let meetingStore: MeetingStore
    private let knowledgeStore: KnowledgeStore
    private let language: LanguagePreference
    private let proactivity: ProactivityPreference
    private let auth: AuthService
    private let profileStore: ProfileStore
    private let outbox: MeetingOutbox
    private let modeStore: ModeStore
    let calendar: CalendarService
    private let analytics: ProductAnalytics
    private let recapGenerator: RecapGenerator
    /// Only ever asked one question: is anybody listening to this recording. The
    /// live pass's findings are mirrored for them and for nobody else.
    private let rooms: RoomListenerService
    private var captureID: UUID?

    /// The previous recording's audio teardown, so the next one can wait on it.
    ///
    /// `stop()` and `start()` were two unordered tasks against one capture
    /// service. Stopping and starting again inside a couple of minutes let the
    /// start overtake the stop, which then tore down the system-audio stream it
    /// had just brought up. The microphone survived — `AVAudioEngine` comes back
    /// — and `SCStream` did not, so the second recording transcribed an hour of
    /// two people as one voice with nothing on the remote side.
    private var audioTeardown: Task<Void, Never>?

    /// When the live room was last told this recording is still going.
    private var lastLeaseBeat = Date.distantPast

    /// The forgot-to-stop watchdog's timing state. It decides; this class acts.
    private var autoEnd = AutoEndWatchdog()
    private let rosterSampler: MeetingRosterSampler
    /// Everything a finished meeting gets once its recap exists.
    private let enrichment: MeetingEnrichment
    /// What the meeting is offering to do in the tools the user connected.
    private let proposalRaiser: ProposalRaiser

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
        analytics: ProductAnalytics,
        proposalRaiser: ProposalRaiser,
        rooms: RoomListenerService
    ) {
        self.audioCapture = audioCapture
        self.store = store
        self.llm = llm
        self.meetingStore = meetingStore
        self.knowledgeStore = knowledgeStore
        self.language = language
        self.proactivity = proactivity
        self.auth = auth
        self.profileStore = profileStore
        self.outbox = outbox
        self.modeStore = modeStore
        self.calendar = calendar
        self.analytics = analytics
        self.proposalRaiser = proposalRaiser
        self.rooms = rooms
        recapGenerator = RecapGenerator(llm: llm)
        rosterSampler = MeetingRosterSampler(exclusions: screenExclusions)
        enrichment = MeetingEnrichment(
            llm: llm,
            meetingStore: meetingStore,
            entityStore: entityStore,
            knowledgeStore: knowledgeStore,
            actionItemStore: actionItemStore
        )
        analyst = LiveMeetingAnalyst(llm: llm, store: store, proactivity: proactivity)
        observeSleep()
    }

    deinit {
        // A sign-out drops the session mid-recording; stop the streaming loop so
        // it doesn't outlive the panel. The WAL on disk keeps whatever streamed.
        streamTask?.cancel()
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
    }

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
            beatLeaseIfDue()
        }
    }

    /// Keeps the live room visible through a quiet stretch.
    ///
    /// Runs while paused as well as while recording: a paused recording is one
    /// the person intends to resume, and a colleague should be offered the room
    /// rather than told it ended. Stops when the lease is detached at End, which
    /// is what makes the room disappear on time.
    private func beatLeaseIfDue() {
        guard meeting != .idle, let meetingID = activeMeetingLeaseID else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLeaseBeat) >= Self.leaseBeatInterval else { return }
        lastLeaseBeat = now
        Task { [meetingStore] in await meetingStore.touchLease(meetingID: meetingID) }
    }

    /// Comfortably inside the 90 seconds `_live_lease_in_org` allows, so one
    /// dropped beat still leaves the room visible.
    private static let leaseBeatInterval: TimeInterval = 30

    /// Once a second while recording: raise the forgot-to-stop prompt after a
    /// stretch of silence on both streams, count it down, and auto-end (trimmed
    /// to the last speech) if the user doesn't respond. A resumed conversation
    /// after the prompt dismisses it.
    private func tickInactivity() {
        guard meeting == .recording else {
            if autoEndPrompt != nil { clearAutoEndPrompt() }
            return
        }
        switch autoEnd.tick(
            now: Date(),
            prompt: autoEndPrompt,
            lastSpeechAt: store.lastSpeechAt,
            recordingStartedAt: recordingStartedAt,
            hidIdleSeconds: hidIdleSeconds()
        ) {
        case .idle:
            break
        case .dismiss:
            autoEndPrompt = nil
        case let .countdown(seconds):
            autoEndPrompt?.secondsRemaining = seconds
        case let .raise(prompt, silence, away):
            autoEndPrompt = prompt
            raisePanelForPrompt()
            Log.ui.info("inactivity prompt raised (silence \(silence)s, away=\(away))")
        case .end:
            autoEndPrompt = nil
            Log.ui.info("auto-ending meeting after inactivity")
            endMeeting()
        }
    }

    /// The call this recording was following has ended, per `MeetingDetector`.
    /// Only for `meeting` — a voice note that happened to be running while a
    /// call ended has nothing to do with that call.
    func callEnded(app: String) {
        guard meeting == .recording, selectedKind == .meeting else { return }
        if case .callEnded = autoEndPrompt?.reason { return }
        guard let prompt = autoEnd.callEnded(app: app, now: Date(), lastSpeechAt: store.lastSpeechAt)
        else { return }
        autoEndPrompt = prompt
        raisePanelForPrompt()
        Log.ui.info("\(app) call ended — finishing shortly")
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
        autoEnd.clearPrompt()
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
    func recordRecordingStartRequested() -> UUID {
        let meetingID = UUID()
        analytics.record(
            .captureStartRequested,
            captureID: meetingID,
            properties: .init(
                sessionKind: selectedKind.rawValue,
                entryPoint: .floatingPanel,
                stage: .capture,
                surface: .capture
            )
        )
        return meetingID
    }

    func requestRecordingStart(meetingID: UUID) async -> RecordingStartOutcome {
        guard isFinishingTranscription == false else {
            return recordingStartFailed(.finishing, meetingID: meetingID)
        }
        guard meeting == .idle, !isStartingRecording else {
            return recordingStartFailed(.startInProgress, meetingID: meetingID)
        }
        guard let userID = auth.currentSupabaseSession?.user.id else {
            return recordingStartFailed(.authentication, meetingID: meetingID)
        }

        isStartingRecording = true
        defer { isStartingRecording = false }

        // Somebody may have started recording this same meeting seconds ago.
        // Both people are asked at once by design — at that moment nobody is
        // recording, and picking one of them in advance means the meeting goes
        // unrecorded whenever that one ignores the card. The cost of asking both
        // is this window: the calendar watcher only looks for a room every 20
        // seconds, so two people pressing Start inside it produced two
        // recordings of one conversation, two summaries, and two lots of hours
        // charged — with nothing but an after-the-fact line to say so.
        //
        // Asked here because Start already waits on the server for its
        // allowance, so this costs nothing anybody can feel, and asked *before*
        // the lease so a start that turns into a join never takes a slot.
        //
        // Skipped when a room is already known, which is the whole guard against
        // a loop: a room being known means the card offering it was on screen
        // and this person pressed "record my own" anyway. That is an answer, and
        // asking again would just put the same card back.
        if rooms.available == nil, let identity = calendar.currentRoomIdentity() {
            await rooms.lookForRoom(identity)
            if rooms.available != nil {
                Log.ui.info("start: somebody is already recording this — offering the room instead")
                return .roomAvailable
            }
        }

        do {
            try await llm.startMeetingLease(meetingID: meetingID)
        } catch LLMProxyClient.ClientError.meetingLimitReached {
            recordRecordingStartFailure(
                meetingID: meetingID,
                stage: .entitlement,
                reason: .hoursExhausted
            )
            return .limitReached
        } catch let LLMProxyClient.ClientError.meetingBlocked(reason) {
            recordRecordingStartFailure(
                meetingID: meetingID,
                stage: .entitlement,
                reason: .interrupted
            )
            return .blocked(reason)
        } catch {
            // The lease may have been granted before the response was lost, so
            // hand it back rather than leaving a slot held by nobody.
            Task { await llm.endMeetingLease(meetingID: meetingID) }
            return recordingStartFailed(.lease(error.localizedDescription), meetingID: meetingID)
        }

        // The user may have cancelled, signed out, or started something else
        // while the round-trip was in flight.
        guard meeting == .idle,
              auth.currentSupabaseSession?.user.id == userID,
              !Task.isCancelled
        else {
            await llm.endMeetingLease(meetingID: meetingID)
            return recordingStartFailed(.cancelled, meetingID: meetingID)
        }

        activeMeetingLeaseID = meetingID
        beginRecording(meetingID: meetingID, userID: userID)
        offerCalendarIdentity(meetingID)
        askWhoElseIsRecording(meetingID)
        return .started
    }

    private func beginRecording(meetingID: UUID, userID: UUID) {
        Log.ui.info("Start Meeting")
        sessionGeneration += 1
        let captureID = meetingID
        self.captureID = captureID
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
        // Only while somebody is actually listening. The live pass is promised
        // to keep what it finds in memory, and a recording nobody joined has no
        // reason to put any of it on a server — a solo voice note least of all.
        //
        // Somebody joining mid-meeting misses nothing for longer than one pass:
        // every mirror sends the whole list, so the next finding carries all the
        // earlier ones with it. That is the same property that makes a silently
        // failed write repair itself, bought twice.
        analyst.mirrorFindings = { [weak meetingStore, weak rooms] findings in
            guard rooms?.listeners.isEmpty == false else { return }
            Task { await meetingStore?.mirrorLiveFindings(findings) }
        }
        if selectedKind.extractsActionItems { analyst.start() }
        knowledgeStore.isCapturing = true
        elapsed = 0
        clearAutoEndPrompt()
        autoEnd.reset()
        lastLeaseBeat = .distantPast
        wantsAutoStart = false
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
            rosterSampler.start()
        }
        Task {
            // Before the store, not just before `start`: the previous recording's
            // teardown also resets shared transcriber state.
            await audioTeardown?.value
            audioTeardown = nil
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
            if audioCapture.activeCaptureError == nil {
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

    private func recordingStartFailed(
        _ failure: RecordingStartOutcome.Failure,
        meetingID: UUID
    ) -> RecordingStartOutcome {
        recordRecordingStartFailure(
            meetingID: meetingID,
            stage: failure.analyticsStage,
            reason: failure.analyticsReason
        )
        return .failed(failure)
    }

    func recordRecordingStartFailure(
        meetingID: UUID,
        stage: ProductAnalytics.Stage,
        reason: ProductAnalytics.ReasonCode
    ) {
        analytics.record(
            .captureFailed,
            captureID: meetingID,
            properties: .init(
                sessionKind: selectedKind.rawValue,
                entryPoint: .floatingPanel,
                stage: stage,
                reasonCode: reason,
                surface: .capture,
                outcome: .failure
            )
        )
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
        let records = TranscriptSnapshot.records(from: slice, meeting: draft, baseIdx: streamedCount)
        streamedCount = settledCount
        await outbox.record(records, for: draft.id)
        await outbox.flush(using: meetingStore, userID: draft.userID)
    }

    /// A closed lid ends the meeting.
    ///
    /// `willSleepNotification`, which is system sleep — the same signal
    /// `MeetingDetector` and `ScheduledMeetingWatcher` already watch, and
    /// deliberately not display sleep: a call outlives a dark screen, and ending
    /// then would throw away the rest of it.
    ///
    /// Ending rather than pausing, because a paused recording is a promise to
    /// come back to it. Nobody closing their laptop is coming back to the same
    /// conversation, and a recording that resumes hours later on a different
    /// call is worse than one that ended when the meeting did.
    ///
    /// macOS gives very little time here and none of it is guaranteed, so this
    /// leans on what is already durable: `endMeeting` stops capture and hands the
    /// meeting to the on-disk outbox, which replays it on the next launch or
    /// wake. The part that needs the network is allowed to fail.
    private func observeSleep() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.meeting != .idle else { return }
                Log.ui.info("sleep: ending the meeting")
                self.endMeeting()
            }
        }
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
        audioTeardown = Task { await audioCapture.stop() }
        let meetingLeaseID = detachActiveMeetingLease()
        streamTask?.cancel()
        streamTask = nil
        // Before the finalize below reads the count: the call is over, so no
        // later sample can add anything, and one landing mid-finalize would
        // race the read.
        rosterSampler.stop()

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
        let endedAt = AutoEndWatchdog.trimmedEndDate(
            startedAt: startedAt,
            lastSpeechAt: store.lastSpeechAt
        )
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
        let pinnedRoster = rosterSampler.consume()
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
            await finalize(
                Finalize(
                    draft: draft,
                    leaseID: meetingLeaseID,
                    entries: pinnedEntries,
                    people: people,
                    findings: pinnedFindings,
                    language: lang,
                    framing: framing,
                    profileContext: profile,
                    generation: generation
                )
            )
        }
    }

    /// What the finalize must read from the instant the user pressed End. The
    /// transcript store, the roster and the analyst are all shared with the next
    /// recording, so anything read inside the task would be that meeting's.
    private struct Finalize {
        let draft: Meeting
        let leaseID: UUID?
        let entries: [TranscriptEntry]
        let people: MeetingParticipants
        let findings: [LiveFinding]
        let language: AppLanguage
        let framing: MeetingFraming
        let profileContext: String
        /// Which recording this belonged to — see `sessionGeneration`.
        let generation: Int
    }

    /// Summarise, persist, enrich. Runs once the panel is already back at rest,
    /// against the snapshot above, so a recording started while this one
    /// summarises can neither be written into it nor wiped by it.
    private func finalize(_ pinned: Finalize) async {
        // Only what the body reads more than once — the rest is read off
        // `pinned` where it is used.
        let draft = pinned.draft
        let draftID = draft.id
        let pinnedEntries = pinned.entries
        let pinnedFindings = pinned.findings
        let people = pinned.people
        let generation = pinned.generation
        let lang = pinned.language

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
        if let leaseID = pinned.leaseID {
            await llm.endMeetingLease(meetingID: leaseID)
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
        let clustered = TranscriptSnapshot.context(from: entriesSnapshot, speakers: speakers)
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
        let attributions: [String: SpeakerAttribution] = speakers.isEmpty
            ? [:]
            : await enrichment.nameSpeakers(
                in: clustered,
                people: people,
                clusters: Array(Set(speakers.values))
            )
        let speakerNames = attributions.names
        let context = speakerNames.isEmpty
            ? clustered
            : TranscriptSnapshot.context(
                from: entriesSnapshot,
                speakers: speakers,
                names: speakerNames
            )
        // Carried on the draft rather than patched in afterwards, so the
        // names land in the same INSERT as the meeting instead of needing
        // the row to exist first.
        var named = draft
        named.speakerNames = speakerNames.isEmpty ? nil : speakerNames

        let (system, user) = PromptLibrary.build(
            transcript: context,
            language: lang,
            personalContext: pinned.profileContext,
            sessionKind: draft.kind,
            summaryTemplate: pinned.framing.summary,
            modeFocus: pinned.framing.focus,
            meetingDate: PromptLibrary.sessionDateString(draft.startedAt),
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
            let records = TranscriptSnapshot.records(
                from: entriesSnapshot,
                meeting: updated,
                speakers: speakers
            )
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
                    await self.enrichment.applyLateSpeakers(
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
                let saved = await enrichment.run(
                    for: updated,
                    transcript: context,
                    recap: recap,
                    participants: participants,
                    live: pinnedFindings,
                    speakers: attributions
                )
                // After the to-dos exist and not before: a proposal points at
                // the row it came from, and offering to file something the user
                // cannot yet see in their checklist is an offer about nothing.
                await proposalRaiser.raise(from: saved, recap: recap, for: updated)
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
            let records = TranscriptSnapshot.records(
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

    /// Reset the panel to its ready state without touching the transcript —
    /// used when the post-meeting finalize still needs `store` to snapshot it.
    private func resetPanelForIdle() {
        meeting = .idle
        knowledgeStore.isCapturing = false
        elapsed = 0
        micMuted = false
        liveTitle = nil
        captureID = nil
        concurrentCheck?.cancel()
        concurrentCheck = nil
        concurrentRecording = nil
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
        rosterSampler.stop()
        recordingDraft = nil
        wantsAutoStart = false
        autoEnd.reset()
        // Participant names are session-scoped by policy (privacy.md § 3.10):
        // they exist to size the clustering pass and must not outlive it.
        rosterSampler.clear()
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
            autoEnd.noteActivity(at: Date())
            Task { await audioCapture.resume() }
        }
    }

    /// User dismissed the forgot-to-stop prompt — keep recording, and back off
    /// the silence threshold (doubling, capped) so we don't nag on the next
    /// quiet stretch.
    func keepRecording() {
        let backoff = autoEnd.kept(reason: autoEndPrompt?.reason, now: Date())
        autoEndPrompt = nil
        Log.ui.info("user kept recording — silence backoff ×\(Int(backoff))")
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
