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

    /// Drives the scripted landing-page demo. Only ever running when the demo
    /// is armed in Settings; the real capture path never sees it.
    let demo = DemoDirector()
    let playback: DemoPlayback

    let session: MeetingSession
    let offers: MeetingOffers
    let audioCapture: AudioCaptureService
    let language: LanguagePreference
    let updateGate: UpdateGate

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
    /// Which of the meeting bar's own panels is showing, while a meeting is
    /// active. Like `isOpened`, only `derived()` reads it — a plain var, reset
    /// to `.passive` at the start of every new recording so a Notes panel left
    /// open from a previous meeting doesn't carry over into the next.
    private var meetingBarPanel: MeetingBarPanel = .passive
    /// Whether the meeting bar is tucked into the notch, following a swipe-up
    /// over it (`NotchGestureZone`). Only ever set while `geometry.hasCutout` —
    /// there is nothing to tuck into otherwise — so `derived()` doesn't need to
    /// re-check that itself.
    private var meetingBarHidden = false
    private var gate: Gate?
    private var cancellables = Set<AnyCancellable>()
    /// The fold-shut-then-expand swap between two opened states, and the state
    /// it is on its way to. Held so a third state arriving mid-swap replaces the
    /// target rather than queueing behind it.
    private var transition: Task<Void, Never>?
    private var pendingTarget: NotchPresentation?
    /// The session's once-a-second tick: the elapsed clock, and the silence
    /// watchdog that raises the forgot-to-stop countdown. Owned here rather than
    /// by a view's `.task` — it has to run for the whole session, and a view
    /// that isn't mounted is not a reason for a recording to stop counting.
    private var secondsTimer: Task<Void, Never>?

    /// A step that has to be answered before audio capture may begin.
    private enum Gate {
        case language
        case consent
    }

    init(
        session: MeetingSession,
        offers: MeetingOffers,
        audioCapture: AudioCaptureService,
        language: LanguagePreference,
        updateGate: UpdateGate,
        playback: DemoPlayback,
        profiles: ProfileStore,
        briefing: CallBriefing,
        consent: ConsentPreference,
        entitlements: EntitlementService,
        meetingStore: MeetingStore,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.offers = offers
        self.audioCapture = audioCapture
        self.language = language
        self.updateGate = updateGate
        self.playback = playback
        self.profiles = profiles
        self.briefing = briefing
        self.consent = consent
        self.entitlements = entitlements
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
        case .launch: true
        // Only while a panel is actually expanded — the bar itself is always
        // visible during a meeting and a stray click must not hide it, only
        // fold an expanded Ask/Notes panel back to the passive row.
        case let .meetingBar(panel): panel != .passive
        // The demo never closes on a click: a stray cursor must not cut a take.
        // A notice has its own dismiss and goes away on its own; a stray click
        // in another app is not the user answering it. The recap card is the
        // same shape as those two — it arrived on its own, not because the
        // user opened the surface, so a stray click elsewhere isn't them
        // dismissing it either. Its own close glyph is the only way out.
        case .updateRequired, .dormant, .tucked, .offer, .noticed, .recap,
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
        refresh()
    }

    /// Fold the surface back to whatever it should show unattended. During a
    /// meeting that only collapses an expanded Ask/Notes panel — the bar
    /// itself stays up until `hideMeetingBar` or the meeting ends. Also
    /// cancels a gate the user walked away from, so it isn't still pending
    /// next time the notch opens.
    func close() {
        if session.meeting != .idle {
            meetingBarPanel = .passive
        } else {
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

        Task { @MainActor in
            // The proxy keeps serving `transcribe` on a lapsed plan so a live
            // meeting is never cut; this client check is the only thing that
            // blocks a NEW one. Refresh first so a lapse since the last sync
            // counts. An unresolved entitlement falls through — a paying user is
            // never blocked on a failed fetch.
            await entitlements.refresh()
            if entitlements.entitlement?.isActive == false {
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
        gate = nil
        isOpened = false
        session.clearAutoStartRequest()
        refresh()
    }

    private func proceedPastLanguage() {
        guard consent.isAccepted else {
            enter(.consent)
            return
        }
        beginRecording()
    }

    private func beginRecording() {
        gate = nil
        isOpened = false
        meetingBarPanel = .passive
        meetingBarHidden = false
        session.clearAutoStartRequest()
        session.beginRecording()
        refresh()
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
        if case .meetingBar = presentation, case .meetingBar = next {
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
        session.meeting == .idle ? .dormant : .tucked
    }

    /// Priority order, most urgent first. A gate outranks everything because it
    /// is the user's own half-finished action; an alert outranks the ambient
    /// states because ignoring it ends or loses a recording.
    private func derived() -> NotchPresentation {
        // The demo owns the surface outright while it runs — it is a recording
        // of a scripted story, and a real alert cutting into it would ruin the
        // take.
        if let stage = demo.stage {
            return .demo(stage)
        }

        if updateGate.status == .required {
            return .updateRequired
        }

        switch gate {
        case .language: return .languageConfirm
        case .consent: return .consent
        case nil: break
        }

        if let prompt = session.autoEndPrompt {
            return .alert(.autoEnd(prompt))
        }
        if let message = session.saveErrorToast, !session.pendingMeetingSaves.isEmpty {
            return .alert(.saveFailed(message))
        }
        if let offer = offers.current {
            return .offer(offer)
        }
        if session.meeting != .idle {
            // The user's own swipe wins over everything else here — a notice
            // arriving is not them asking to see the bar again.
            if meetingBarHidden {
                return .tucked
            }
            // Never over an expanded panel. Ask/Notes are open because the
            // user opened them, and taking that away to say something they
            // did not ask for is the difference between proactive and rude.
            if let notice = session.analyst.notice, meetingBarPanel == .passive {
                return .noticed(notice)
            }
            return .meetingBar(meetingBarPanel)
        }
        if let recap = recapState {
            return .recap(recap)
        }
        return isOpened ? .launch : .dormant
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
    /// passive row if it's already open. Always starts fresh, not a restore —
    /// the box is for a new question, not a scrollback.
    func toggleAsk() {
        if case .ask = meetingBarPanel {
            meetingBarPanel = .passive
        } else {
            meetingBarPanel = .ask(.composing)
        }
        refresh()
    }

    /// The Notes row's own button — same toggle shape as `toggleAsk`.
    func toggleNotes() {
        meetingBarPanel = meetingBarPanel == .notes ? .passive : .notes
        refresh()
    }

    /// The Ask box's own free-text question. Blank input is a no-op rather
    /// than a round trip that would just come back empty.
    func submitAsk(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runAsk(question: trimmed) {
            try await self.session.analyst.ask(trimmed, language: self.language.current)
        }
    }

    /// The Ask box's "Summarize" chip — routed through the dedicated catch-up
    /// prompt (tuned for exactly this) rather than through `ask` with the
    /// literal word "Summarize" as the question.
    func askSummarize() {
        runAsk(question: "Summarize") {
            try await self.session.analyst.catchUp(language: self.language.current)
        }
    }

    /// The shared shape behind every Ask-box request: show the loading state,
    /// run the one-shot call, land on its answer or a failure — unless the
    /// user has already moved on (closed the panel, or fired another ask) by
    /// the time it comes back, in which case the answer is stale and dropped.
    private func runAsk(question: String, call: @escaping () async throws -> String) {
        meetingBarPanel = .ask(.loading)
        refresh()
        Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await call()
                guard meetingBarPanel == .ask(.loading) else { return }
                meetingBarPanel = .ask(.answered(question: question, answer: answer))
            } catch {
                Log.llm.error("ask: \(question) failed — \(error.localizedDescription)")
                guard meetingBarPanel == .ask(.loading) else { return }
                meetingBarPanel = .ask(.failed(question: question))
            }
            refresh()
        }
    }

    /// The notch-gesture's hide — see `NotchGestureZone`. A no-op off a
    /// notched display or outside a meeting: nothing to tuck into, or nothing
    /// worth tucking.
    func hideMeetingBar() {
        guard geometry.hasCutout, session.meeting != .idle else { return }
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
