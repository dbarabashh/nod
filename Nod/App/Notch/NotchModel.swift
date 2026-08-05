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
    /// Whether Start pauses on the language confirm. Bound by the checkbox in
    /// that confirm and mirrored by the Settings toggle, so both write the one
    /// defaults key rather than each keeping a copy that drifts.
    @Published var askLanguageEachTime: Bool {
        didSet { defaults.set(askLanguageEachTime, forKey: MeetingLanguagePromptDefaults.defaultsKey) }
    }

    let session: MeetingSession
    let detector: MeetingDetector
    let audioCapture: AudioCaptureService
    let language: LanguagePreference
    let updateGate: UpdateGate

    private let consent: ConsentPreference
    private let entitlements: EntitlementService
    private let defaults: UserDefaults
    /// The user pulled the surface open — by clicking it, by the hotkey, or from
    /// the menu bar. Everything else on screen is a consequence of state the app
    /// is already in.
    private var isOpened = false
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
        detector: MeetingDetector,
        audioCapture: AudioCaptureService,
        language: LanguagePreference,
        updateGate: UpdateGate,
        consent: ConsentPreference,
        entitlements: EntitlementService,
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.detector = detector
        self.audioCapture = audioCapture
        self.language = language
        self.updateGate = updateGate
        self.consent = consent
        self.entitlements = entitlements
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
        isOpened.toggle()
        refresh()
    }

    /// Whether a click elsewhere folds the surface away.
    ///
    /// Only the two states the user opened for themselves. An invitation has its
    /// own dismiss and an explicit "never again"; an alert is up because
    /// ignoring it ends or loses a recording; a gate is a half-finished start
    /// that a stray click must not silently abandon.
    var closesOnOutsideClick: Bool {
        switch presentation {
        case .launch, .controls: true
        case .updateRequired, .dormant, .capturing, .invitation, .languageConfirm, .consent, .alert: false
        }
    }

    func open() {
        guard !isOpened else { return }
        isOpened = true
        refresh()
    }

    /// Fold the surface back to whatever it should show unattended. Also cancels
    /// a gate the user walked away from: a half-answered consent prompt must not
    /// still be pending the next time the notch opens.
    func close() {
        isOpened = false
        gate = nil
        refresh()
    }

    // MARK: - Starting a capture

    /// The one road into a recording. Every entry point — the Start button, an
    /// accepted invitation, the auto-start request — comes through here, so the
    /// subscription, consent and language checks cannot be skipped by any of them.
    func requestStart() {
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

    func acceptInvitation() {
        detector.accept()
    }

    func declineInvitation() {
        detector.decline()
    }

    func muteInvitation(_ app: ConferencingApp) {
        detector.mute(app)
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

        Publishers.MergeMany(
            session.$meeting.map { _ in () }.eraseToAnyPublisher(),
            session.$autoEndPrompt.map { _ in () }.eraseToAnyPublisher(),
            session.$saveErrorToast.map { _ in () }.eraseToAnyPublisher(),
            detector.$invitation.map { _ in () }.eraseToAnyPublisher(),
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

        guard presentation.isOpen, next.isOpen else {
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
        session.meeting == .idle ? .dormant : .capturing
    }

    /// Priority order, most urgent first. A gate outranks everything because it
    /// is the user's own half-finished action; an alert outranks the ambient
    /// states because ignoring it ends or loses a recording.
    private func derived() -> NotchPresentation {
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
        if let invitation = detector.invitation {
            return .invitation(invitation)
        }
        if session.meeting != .idle {
            return isOpened ? .controls : .capturing
        }
        return isOpened ? .launch : .dormant
    }
}
