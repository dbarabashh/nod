import AppKit
import Combine
import SwiftUI

/// Turns everything the notch reacts to — the session, the call detector, the
/// gates on the way into a recording — into a single `NotchPresentation`.
///
/// The view reads that one value and nothing else decides what is on screen, so
/// a detected call arriving mid-countdown, or a save failing while the controls
/// are open, resolves here rather than in a pile of overlapping overlays.
@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var presentation: NotchPresentation = .dormant
    @Published private(set) var geometry: NotchGeometry = .island
    /// What Nod already knows about the call being offered.
    ///
    /// Beside the presentation rather than inside it: the presentation is an
    /// identity, and a change to it folds the surface shut and expands it again.
    @Published private(set) var callContext: CallContext = .none
    /// Whether Start pauses on the language confirm. Bound by the checkbox in
    /// that confirm and mirrored by the Settings toggle, so both write the one
    /// defaults key rather than each keeping a copy that drifts.
    @Published var askLanguageEachTime: Bool {
        didSet { defaults.set(askLanguageEachTime, forKey: MeetingLanguagePromptDefaults.defaultsKey) }
    }

    /// A start request is waiting on the server's allowance answer, so Start
    /// shows a spinner rather than appearing to do nothing.
    @Published private(set) var isRequestingRecording = false
    /// Why the last start attempt didn't take. Shown under Start; cleared by the
    /// next attempt.
    @Published private(set) var recordingStartError: String?

    /// Drives the scripted landing-page demo. Only ever running when the demo
    /// is armed in Settings; the real capture path never sees it.
    let demo = DemoDirector()
    let playback: DemoPlayback
    let captureSurface: CaptureSurfacePreference
    let panelSharing: PanelSharingPreference

    let session: MeetingSession
    let offers: MeetingOffers
    let audioCapture: AudioCaptureService
    let rooms: RoomListenerService
    let calendar: CalendarService
    let language: LanguagePreference
    let updateGate: UpdateGate
    /// Owned by the allowance gate: it sells the top-up in place.
    let billing: BillingService

    /// Resolves `session.justEndedMeetingID` into a `RecapState` — the same
    /// generating/finished state `MeetingDetailView` already reads, just
    /// surfaced in the notch too instead of only in the full window.
    private let meetingStore: MeetingStore
    private let profiles: ProfileStore
    private let briefing: CallBriefing
    private let consent: ConsentPreference
    private let entitlements: EntitlementService
    private let defaults: UserDefaults
    /// The user pulled the surface open — by clicking it, by the hotkey, or from
    /// the menu bar. Everything else on screen is a consequence of state the app
    /// is already in.
    private var isOpened = false
    /// Which of the meeting bar's own panels is showing, and where its Ask box
    /// stands, while a meeting is active. Like `isOpened`, only `derived()`
    /// reads it — a plain var, reset whole at the start of every new recording
    /// so neither a Notes panel nor a previous meeting's answer carries over
    /// into the next.
    private var meetingBarPanel = MeetingBarPanel()
    /// Whether the meeting bar is tucked into the notch, following a swipe-up
    /// over it (`NotchGestureZone`). Only ever set while `geometry.hasCutout` —
    /// there is nothing to tuck into otherwise — so `derived()` doesn't need to
    /// re-check that itself.
    ///
    /// Tucking away is the clearest possible "I'm done looking" signal, so the
    /// `didSet` also folds the panel back to `.passive` — an expanded Ask/Notes
    /// panel left open underneath would otherwise silently block every future
    /// notice for the rest of the meeting, with nothing on screen hinting why.
    /// Living here, on the property itself, means any future path that tucks
    /// the bar away inherits the reset for free instead of depending on that
    /// caller remembering it too. A question still being answered survives it:
    /// folding the bar away is not cancelling the ask.
    private var meetingBarHidden = false {
        didSet {
            guard meetingBarHidden, !oldValue else { return }
            meetingBarPanel.expand(.passive)
        }
    }

    private var gate: Gate?
    private var pendingCaptureID: UUID?
    private var recordingStartTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// The fold-shut-then-expand swap between two opened states, and the state
    /// it is on its way to. Held so a third state arriving mid-swap replaces the
    /// target rather than queueing behind it.
    private var transition: Task<Void, Never>?
    private var pendingTarget: NotchPresentation?
    /// The Ask box's round trip. Held so the two things that make an answer
    /// stale — a newer question, and the bar changing hands to another meeting
    /// — can stop it rather than let it finish and be billed for an answer
    /// nobody will read.
    private var askTask: Task<Void, Never>?
    /// The session's once-a-second tick: the elapsed clock, and the silence
    /// watchdog that raises the forgot-to-stop countdown. Owned here rather than
    /// by a view's `.task` — it has to run for the whole session, and a view
    /// that isn't mounted is not a reason for a recording to stop counting.
    private var secondsTimer: Task<Void, Never>?

    /// A step that has to be answered before audio capture may begin.
    enum Gate {
        case language
        case consent
        /// The plan is healthy but this period's hours are gone — offer a top-up
        /// or Pro, never the full paywall.
        case allowance
    }

    init(
        session: MeetingSession,
        offers: MeetingOffers,
        audioCapture: AudioCaptureService,
        rooms: RoomListenerService,
        calendar: CalendarService,
        language: LanguagePreference,
        updateGate: UpdateGate,
        playback: DemoPlayback,
        captureSurface: CaptureSurfacePreference,
        panelSharing: PanelSharingPreference,
        profiles: ProfileStore,
        briefing: CallBriefing,
        consent: ConsentPreference,
        entitlements: EntitlementService,
        billing: BillingService,
        meetingStore: MeetingStore,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.offers = offers
        self.audioCapture = audioCapture
        self.rooms = rooms
        self.calendar = calendar
        self.language = language
        self.updateGate = updateGate
        self.playback = playback
        self.captureSurface = captureSurface
        self.panelSharing = panelSharing
        self.profiles = profiles
        self.briefing = briefing
        self.consent = consent
        self.entitlements = entitlements
        self.billing = billing
        self.meetingStore = meetingStore
        self.defaults = defaults
        askLanguageEachTime = defaults.object(forKey: MeetingLanguagePromptDefaults.defaultsKey) as? Bool
            ?? MeetingLanguagePromptDefaults.defaultValue

        observe()
        refresh()

        secondsTimer = Task { [session] in await session.runSecondsTimer() }
    }

    deinit {
        secondsTimer?.cancel()
    }

    // MARK: - Opening and closing

    func toggleOpen() {
        // During a take the hotkey is how you get out. Without this the demo
        // owns the surface to the last beat and the only way back to the real
        // notch is relaunching the app.
        if demo.isRunning {
            demo.stop()
            close()
            return
        }
        // Tucked is its own thing, not an `isOpened` state — the click that
        // reaches this (a stray tap on the tucked pill, the hotkey, the
        // menu-bar item) is always the user asking for the bar back, the same
        // as the swipe-down gesture does.
        if case .tucked = presentation {
            revealMeetingBar()
            return
        }
        // Delegates to `open()`/`close()` rather than toggling `isOpened`
        // directly, so whatever either of those already does on the way in or
        // out — dismissing the notice, forgetting a stale assist card — only
        // has to be correct in one place.
        if isOpened {
            close()
        } else {
            open()
        }
    }

    /// Whether a click elsewhere folds the surface away.
    ///
    /// Only the two states the user opened for themselves. An invitation has its
    /// own dismiss and an explicit "never again"; an alert is up because
    /// ignoring it ends or loses a recording; a gate is a half-finished start
    /// that a stray click must not silently abandon.
    var closesOnOutsideClick: Bool {
        switch presentation {
        // Except while a start is already in flight. Closing here cancels it
        // (`cancelPendingRecordingStart`), and clicking into the app you are
        // about to meet in is the most ordinary thing to do in the second after
        // pressing Start — losing the recording to it, silently, is not an
        // answer to anything the user asked. The hotkey and the menu-bar item
        // still cancel deliberately.
        case .launch: !isRequestingRecording && pendingCaptureID == nil
        // Only while a panel is actually expanded — the bar itself is always
        // visible during a meeting and a stray click must not hide it, only
        // fold an expanded Ask/Notes panel back to the passive row. And never
        // while an answer is still on its way: clicking into another app is
        // what people do while they wait, not them abandoning the question,
        // and the answer landing in a folded panel would go unseen.
        case let .meetingBar(_, panel): panel.expansion != .passive && !(panel.isAsk && panel.isAnswering)
        // The demo never closes on a click: a stray cursor must not cut a take.
        // A notice has its own dismiss and goes away on its own; a stray click
        // in another app is not the user answering it. The recap card is the
        // same shape as those two — it arrived on its own, not because the
        // user opened the surface, so a stray click elsewhere isn't them
        // dismissing it either. Its own close glyph is the only way out.
        // The room card is the same: it arrived on its own, and it has its own
        // "Not now".
        case .updateRequired, .dormant, .tucked, .offer, .liveRoom, .noticed, .recalled, .lookedUp, .recap,
             .languageConfirm, .consent, .alert, .demo: false
        }
    }

    /// Opening the surface is the user engaging with it, so the notice goes with
    /// it — left pending it would flash back for whatever is left of its
    /// lifetime the moment the transport is folded away again. Done on both
    /// paths because the click and the hotkey come through `toggleOpen`, and
    /// only `WindowCoordinator` reaches this one.
    func open() {
        guard !isOpened else { return }
        isOpened = true
        session.analyst.dismissNotice()
        session.analyst.dismissRecall()
        refresh()
    }

    /// Fold the surface back to whatever it should show unattended. During a
    /// meeting that only collapses an expanded Ask/Notes panel — the bar
    /// itself stays up until `hideMeetingBar` or the meeting ends. Also
    /// cancels a gate the user walked away from, so it isn't still pending
    /// next time the notch opens.
    func close() {
        if barRole != nil {
            meetingBarPanel.expand(.passive)
        } else {
            cancelPendingRecordingStart()
            isOpened = false
            gate = nil
        }
        refresh()
    }

    /// The notice's own dismiss glyph, tapped — the user answering the card,
    /// as opposed to it timing out or the panel opening for something else.
    /// See `LiveMeetingAnalyst.dismissNotice(userRejected:)`.
    func rejectNotice() {
        session.analyst.dismissNotice(userRejected: true)
    }

    func dismissRecall() {
        session.analyst.dismissRecall()
    }

    /// Takes the answer down. Its own method rather than the analyst's, so the
    /// card behaves like every other one here: the surface asks, the analyst
    /// forgets.
    func dismissLookup() {
        session.analyst.dismissLookup()
    }

    /// Opens the session the recall came from. Takes the card down first: it
    /// has been answered, and leaving it up over a window the user just asked
    /// for would be the interruption repeating itself.
    func openRecallSource(_ recall: LiveRecall) {
        session.analyst.dismissRecall()
        NotificationCenter.default.post(
            name: .nodOpenMeetingDetail,
            object: nil,
            userInfo: [Notification.nodMeetingIDKey: recall.sourceMeetingID]
        )
    }

    // MARK: - Starting a capture

    /// The one road into a recording. Every entry point — the Start button, an
    /// accepted invitation, the auto-start request — comes through here, so the
    /// subscription, consent and language checks cannot be skipped by any of them.
    func requestStart() {
        // Armed for a recording: Start plays the script instead of opening a
        // microphone. The whole point is a take that is identical every time.
        if let scenario = playback.armed {
            isOpened = false
            demo.start(scenario, pace: playback.pace)
            refresh()
            return
        }

        guard pendingCaptureID == nil else { return }
        let captureID = session.recordRecordingStartRequested()
        pendingCaptureID = captureID

        Task { @MainActor in
            // The proxy keeps serving `transcribe` on a lapsed plan so a live
            // meeting is never cut; this client check is the only thing that
            // blocks a NEW one. Refresh first so a lapse since the last sync
            // counts. An unresolved entitlement falls through — a paying user is
            // never blocked on a failed fetch.
            await entitlements.refresh()
            guard pendingCaptureID == captureID else { return }
            if entitlements.entitlement?.isActive == false {
                session.recordRecordingStartFailure(
                    meetingID: captureID,
                    stage: .entitlement,
                    reason: .entitlementRequired
                )
                pendingCaptureID = nil
                Log.ui.info("notch start blocked — entitlement not active; opening paywall")
                NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
                // Clear the request as well as closing: `wantsAutoStart` left
                // standing at true means the *next* auto-start publishes no
                // change, and a detected call would silently never offer again.
                session.clearAutoStartRequest()
                close()
                return
            }
            if askLanguageEachTime {
                enter(.language)
                return
            }
            proceedPastLanguage()
        }
    }

    func confirmLanguage() {
        proceedPastLanguage()
    }

    func acknowledgeConsent(persistGate: Bool) {
        consent.acknowledge(persistGate: persistGate)
        beginRecording()
    }

    func cancelGate() {
        cancelPendingRecordingStart()
        gate = nil
        isOpened = false
        session.clearAutoStartRequest()
        refresh()
    }

    private func cancelPendingRecordingStart() {
        guard let captureID = pendingCaptureID else { return }
        if let recordingStartTask {
            recordingStartTask.cancel()
            pendingCaptureID = nil
            return
        }
        session.recordRecordingStartFailure(
            meetingID: captureID,
            stage: .capture,
            reason: .userCancelled
        )
        pendingCaptureID = nil
    }

    private func proceedPastLanguage() {
        guard consent.isAccepted else {
            enter(.consent)
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        guard !isRequestingRecording else { return }
        guard let captureID = pendingCaptureID else { return }
        gate = nil
        resetMeetingBar()
        meetingBarHidden = false
        session.clearAutoStartRequest()
        recordingStartError = nil
        isRequestingRecording = true
        refresh()

        recordingStartTask = Task { @MainActor in
            let outcome = await session.requestRecordingStart(meetingID: captureID)
            isRequestingRecording = false
            pendingCaptureID = nil
            recordingStartTask = nil
            switch outcome {
            case .started:
                isOpened = false
            case .limitReached:
                // Refresh first: the gate's copy quotes the allowance, and the
                // server just told us it changed.
                await entitlements.refresh()
                billing.lastError = nil
                gate = .allowance
                isOpened = true
                session.recordAllowanceGate(.allowanceGateViewed, outcome: .viewed)
            case .roomAvailable:
                // Nothing to say and nothing to clear: `rooms.available` is now
                // set, and the resolver puts the room card above the offer, so
                // the surface changes its own mind without being told to.
                isOpened = true
            case let .blocked(message):
                recordingStartError = message
                isOpened = true
            case let .failed(failure):
                recordingStartError = failure.message
                isOpened = true
            }
            refresh()
        }
    }

    var shouldRecommendProUpgrade: Bool {
        // Someone who has already bought hours this period is telling us the
        // allowance does not fit them.
        entitlements.entitlement?.hasPurchasedTopUp == true
    }

    func dismissAllowanceGate() {
        session.recordAllowanceGate(.allowanceGateAction, outcome: .cancelled)
        cancelGate()
    }

    func openSubscriptionFromAllowanceGate() {
        session.recordAllowanceGate(.allowanceGateAction, outcome: .granted, plan: "pro")
        cancelGate()
        NotificationCenter.default.post(name: .nodOpenSubscription, object: nil)
    }

    func buyStarterTopUp() {
        Task { @MainActor in
            let outcome = await billing.startStarterTopUp()
            session.recordAllowanceGate(
                .allowanceGateAction,
                outcome: outcome == .opened ? .success : .failure,
                plan: "starter",
                billing: "one_time"
            )
            if outcome == .opened {
                cancelGate()
            }
        }
    }

    private func enter(_ gate: Gate) {
        self.gate = gate
        isOpened = true
        refresh()
    }

    // MARK: - The detected call

    func acceptOffer() {
        offers.accept()
    }

    func declineOffer() {
        offers.decline()
    }

    func muteOffer(_ app: ConferencingApp) {
        offers.mute(app)
    }

    /// What to call the user in the one card that speaks to them directly.
    var userName: String? {
        profiles.profile?.firstName
    }

    /// Pushed in by `NotchController`, which owns the window and therefore the
    /// question of which screen it is hanging on. The model never looks a screen
    /// up itself — two objects reacting to the same display change is how the
    /// surface ends up re-deriving and re-animating its geometry twice.
    func setGeometry(_ geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Derivation

    private func observe() {
        // `requestAutoStart` is how the detector's Accept and the main window's
        // Capture menu ask for a recording without reaching around the gates.
        session.$wantsAutoStart
            .removeDuplicates()
            .sink { [weak self] wants in
                guard wants else { return }
                self?.requestStart()
            }
            .store(in: &cancellables)

        // Switching scenario mid-take restarts on the new one rather than
        // waiting for a relaunch — a recording session is a dozen takes, and
        // quitting between each is the whole friction being removed here.
        playback.$scenario
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] scenario in
                guard let self, demo.isRunning else { return }
                demo.start(scenario, pace: playback.pace)
            }
            .store(in: &cancellables)

        playback.$isEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self, !enabled, demo.isRunning else { return }
                demo.stop()
                refresh()
            }
            .store(in: &cancellables)

        // Recomputed once per offer, not per derivation: `refresh()` runs on
        // every tick of the session clock, and this walks the library.
        //
        // No `receive(on:)`, unlike the derivation below: this reads only the
        // value the publisher hands it, so it is ready for the card's first
        // frame instead of appearing under it a moment later.
        offers.$current
            .removeDuplicates()
            .sink { [weak self] offer in
                guard let self else { return }
                callContext = offer.map { self.briefing.context(for: $0) } ?? .none
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            demo.$stage.map { _ in () }.eraseToAnyPublisher(),
            session.$meeting.map { _ in () }.eraseToAnyPublisher(),
            session.$autoEndPrompt.map { _ in () }.eraseToAnyPublisher(),
            session.$saveErrorToast.map { _ in () }.eraseToAnyPublisher(),
            offers.$current.map { _ in () }.eraseToAnyPublisher(),
            session.analyst.$notice.map { _ in () }.eraseToAnyPublisher(),
            session.analyst.$recall.map { _ in () }.eraseToAnyPublisher(),
            session.analyst.$lookup.map { _ in () }.eraseToAnyPublisher(),
            session.$justEndedMeetingID.map { _ in () }.eraseToAnyPublisher(),
            meetingStore.$meetings.map { _ in () }.eraseToAnyPublisher(),
            meetingStore.$generatingSummaryIDs.map { _ in () }.eraseToAnyPublisher(),
            // The greeting reads the profile, which loads after the notch is built.
            profiles.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            updateGate.$status.map { _ in () }.eraseToAnyPublisher()
        )
        // `@Published` fires in `willSet`, so the new value isn't readable until
        // the next turn of the runloop — and this derivation reads all four.
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.refresh() }
        .store(in: &cancellables)
    }

    private func refresh() {
        let next = derived()
        guard next != (pendingTarget ?? presentation) else { return }
        apply(next)
    }

    /// Swapping one opened state for another goes through the resting silhouette
    /// on the way — fold shut, pause, expand again — instead of resizing from
    /// one card straight into the next.
    ///
    /// This is the whole difference between the surface reading as a notch that
    /// morphs and a window that resizes. Anything arriving over the bare notch
    /// skips it and comes straight up; there is nothing to fold away first, and
    /// a deliberate pause before the *first* thing you see is just latency.
    private func apply(_ next: NotchPresentation) {
        transition?.cancel()
        transition = nil
        pendingTarget = nil

        // Switching the meeting bar's own panel (passive/notes/ask) is a
        // resize of the same surface, not a different surface arriving — it
        // reads as the bar expanding downward only if nothing folds shut
        // first.
        if case let .meetingBar(role, _) = presentation,
           case let .meetingBar(nextRole, _) = next,
           role == nextRole {
            presentation = next
            return
        }

        // Only a card has to be folded away first. A line replacing a line —
        // one spoken sentence after another — folding between each would read
        // as a stutter rather than as the notch thinking.
        guard presentation.occupiesCard, next.isOpen else {
            presentation = next
            return
        }

        pendingTarget = next
        presentation = resting
        transition = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchAnimation.hideShowDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            presentation = next
            pendingTarget = nil
            transition = nil
        }
    }

    /// What the surface collapses to mid-swap: whatever it would be showing if
    /// nobody had opened it.
    private var resting: NotchPresentation {
        guard let role = barRole else { return .dormant }
        return .tucked(role)
    }

    /// Handed to `NotchStateResolver`, which owns the ordering. This assembles
    /// the inputs and nothing else.
    private func derived() -> NotchPresentation {
        NotchStateResolver(
            demoStage: demo.stage,
            isUpdateRequired: updateGate.status == .required,
            gate: gate,
            session: session,
            offer: offers.current,
            liveRoom: rooms.available,
            joinedRoom: rooms.joined,
            meetingBarPanel: meetingBarPanel,
            isMeetingBarHidden: meetingBarHidden,
            recap: recapState,
            isOpened: isOpened
        ).resolve()
    }

    /// `session.justEndedMeetingID` resolved against `meetingStore`, or nil
    /// once nothing is worth showing — the id was dismissed, or a meeting
    /// this old session never actually persisted (sign-out mid-generation,
    /// `MeetingStore.clear()`) fell out of the cache.
    private var recapState: RecapState? {
        guard let id = session.justEndedMeetingID else { return nil }
        if meetingStore.generatingSummaryIDs.contains(id) {
            return .generating
        }
        guard let meeting = meetingStore.meetings.first(where: { $0.id == id }) else { return nil }
        return meeting.lacksRecap ? .failed(meeting.summary) : .ready(meeting)
    }
}

// MARK: - The meeting bar's own panel

/// Split out of the main class body (`private` still resolves — same file)
/// purely to keep `NotchModel`'s own body under the house size limit; this is
/// as much a part of the model as anything above.
extension NotchModel {
    /// The Ask row's own button: opens the box, or folds it back to the
    /// passive row if it's already open. Reopening lands on whatever the box
    /// was last showing — a question still being answered, or the answer —
    /// rather than an empty field: an answer takes seconds to come back, and
    /// looking at Notes or clicking away meanwhile must not cost the question.
    func toggleAsk() {
        meetingBarPanel.expand(meetingBarPanel.isAsk ? .passive : .ask)
        refresh()
    }

    /// The Notes row's own button — same toggle shape as `toggleAsk`.
    func toggleNotes() {
        meetingBarPanel.expand(meetingBarPanel.isNotes ? .passive : .notes)
        refresh()
    }

    /// Hands the bar to a new meeting: nothing the last one was showing, and no
    /// question still on its way to it, belongs to the next.
    private func resetMeetingBar() {
        askTask?.cancel()
        meetingBarPanel = MeetingBarPanel()
    }

    /// The Ask box's own free-text question. Blank input is a no-op rather
    /// than a round trip that would just come back empty.
    func submitAsk(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runAsk(question: trimmed) {
            self.isListening
                ? try await self.rooms.ask(trimmed, language: self.language.current)
                : try await self.session.analyst.ask(trimmed, language: self.language.current)
        }
    }

    /// Whether a question typed into the Ask box is about somebody else's
    /// meeting. Asked at the moment of asking rather than stored, because the
    /// two are exclusive by construction — joining a room and recording one are
    /// different answers to the same calendar entry — and a stored copy would be
    /// one more thing to keep true.
    private var isListening: Bool {
        barRole?.room != nil
    }

    /// Whose meeting bar belongs on screen right now, or nil for neither.
    ///
    /// One question asked in one place. Recording wins when both are somehow
    /// true, which they should not be — joining a room and recording it are
    /// different answers to the same calendar entry — but a surface that has to
    /// pick is better than one that renders both.
    private var barRole: MeetingBarRole? {
        if session.meeting != .idle { return .host }
        if let room = rooms.joined { return .listening(room) }
        return nil
    }

    /// The Ask box's "Summarize" chip — routed through the dedicated catch-up
    /// prompt (tuned for exactly this) rather than through `ask` with the
    /// literal word "Summarize" as the question.
    func askSummarize() {
        runAsk(question: "Summarize") {
            self.isListening
                ? try await self.rooms.catchMeUp(language: self.language.current)
                : try await self.session.analyst.catchUp(language: self.language.current)
        }
    }

    /// The shared shape behind every Ask-box request: show the loading state,
    /// run the one-shot call, land on its answer or a failure. Only a newer
    /// question, or the bar changing hands, supersedes it — what the bar
    /// happens to be showing when the answer arrives does not, so a panel the
    /// user folded away mid-flight still has the answer waiting in it when they
    /// come back.
    private func runAsk(question: String, call: @escaping () async throws -> String) {
        askTask?.cancel()
        meetingBarPanel.startAsking()
        refresh()
        askTask = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await call()
                guard !Task.isCancelled else { return }
                meetingBarPanel.land(.answered(question: question, answer: answer))
            } catch {
                guard !Task.isCancelled else { return }
                Log.llm.error("ask: \(question) failed — \(error.localizedDescription)")
                meetingBarPanel.land(.failed(question: question))
            }
            refresh()
        }
    }

    /// The meeting bar's door back to the main window, which lives outside
    /// the notch entirely — the same app-wide signal the status-bar menu
    /// reaches for, posted from the model rather than the view so every
    /// meeting-bar action keeps coming from this one place.
    /// Step into the room a colleague is recording. The identity comes from this
    /// Mac's own calendar, the same way it does when a recording starts — the
    /// card never carries a handle to somebody else's meeting.
    func joinLiveRoom() {
        Task { [weak self] in
            guard let self, let identity = calendar.currentRoomIdentity() else { return }
            resetMeetingBar()
            await rooms.join(identity)
            refresh()
        }
    }

    func openLibrary() {
        NotificationCenter.default.post(name: .nodOpenLibrary, object: nil)
    }

    /// The recap card's expand. Posted rather than calling `WindowCoordinator`
    /// directly because the notification has two independent observers —
    /// `NodApp` raises and focuses the window, `MainWindowView` pushes the
    /// detail view — and reaching the coordinator would only do the first.
    func openMeeting(_ id: UUID) {
        // Dismissed first: the recap moves to the main window, so leaving the
        // card up left the same summary in two places at once, with the notch
        // parked over the window the user was sent to.
        session.dismissEndedMeeting()
        NotificationCenter.default.post(
            name: .nodOpenMeetingDetail,
            object: nil,
            userInfo: [Notification.nodMeetingIDKey: id]
        )
    }

    /// Fold the meeting bar down to the resting shape — the swipe-up gesture
    /// (`NotchGestureZone`) and the bar's own glyph.
    ///
    /// No longer gated on a cut-out. It used to be, because without one there
    /// was nothing to tuck *into*; but the floating panel has the same resting
    /// pill to shrink to, and a bar you cannot get out of the way is worse on a
    /// surface the user has deliberately parked over their work.
    func hideMeetingBar() {
        guard barRole != nil else { return }
        meetingBarHidden = true
        refresh()
    }

    /// The notch-gesture's reveal, the other direction.
    func revealMeetingBar() {
        guard meetingBarHidden else { return }
        meetingBarHidden = false
        refresh()
    }
}
