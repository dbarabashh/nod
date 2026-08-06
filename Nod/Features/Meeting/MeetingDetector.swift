import AppKit
import Combine
import CoreGraphics
import Foundation

/// What the system says about a call in progress, at one instant.
struct CallSignals: Equatable {
    /// Conferencing apps that are running, native ones first — a native app *is*
    /// the call, a browser merely contains one.
    var running: [ConferencingApp] = []
    /// Apps whose call is held up by a process that exists *only* while the call
    /// does. Narrower than `inCall` on purpose: a window title disappears for
    /// reasons that have nothing to do with the call ending — the user switched
    /// browser tab, minimised the window, or moved it to another Space — so it
    /// can start a recording but must never finish one. A process that is gone
    /// is gone.
    var helperBacked: Set<ConferencingApp> = []
    /// Candidate apps that are holding the microphone themselves, by name of the
    /// process — not "somebody on this Mac is recording".
    ///
    /// The distinction is the whole difference between a useful signal and a
    /// wrong one: Slack is open all day, so a global "the mic is busy" made
    /// every Google Meet call look like a Slack call.
    var micUsers: Set<ConferencingApp> = []
    /// The window title that put an app in a call, for the apps confirmed that
    /// way. Held for the length of one tick and never written anywhere — the
    /// notch reads it to recognise a call it has recorded before, entirely
    /// against sessions already on this Mac (`privacy.md` § 3.10(c)).
    var titles: [ConferencingApp: String] = [:]

    /// Apps a strong signal puts in a call right now: a window titled like one,
    /// or a helper process that exists only while a call is up.
    ///
    /// Derived, not stored. Held as its own set it had to be kept in step with
    /// `titles` by whoever built it — the same invariant-nothing-enforces that
    /// `DetectedCall` exists to kill one layer up, and the same failure: a new
    /// evidence source that adds to one and forgets the other reads as a call
    /// with no title, or a title for a call that isn't happening.
    var inCall: Set<ConferencingApp> {
        helperBacked.union(titles.keys)
    }
}

/// The rules that turn system signals into "a call is happening", and back out
/// again when it stops.
///
/// Free of AppKit, CoreAudio and CoreGraphics on purpose: the rules are the
/// whole feature, and they have to be testable without a real meeting running.
enum MeetingDetection {
    /// The app whose call is on, or nil.
    static func call(in signals: CallSignals) -> ConferencingApp? {
        if let confirmed = signals.running.first(where: signals.inCall.contains) { return confirmed }
        // Holding the microphone only counts for a native app: a browser doing
        // it is as likely to be a voice message as a call, and a browser has a
        // window title to prove itself with.
        return signals.running.first { !$0.isBrowser && signals.micUsers.contains($0) }
    }

    /// Whether a window title says a call is happening *right now*.
    ///
    /// Deliberately stricter than `MeetingRosterReader.isMeetingWindowTitle`,
    /// which only decides whether a window is safe to read: "Chat | Microsoft
    /// Teams" is a Teams window worth reading a roster from and is plainly not a
    /// call.
    static func namesActiveCall(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if substringMarkers.contains(where: { lowered.contains($0) }) { return true }
        return leadingMarkers.contains { lowered.hasPrefix($0) }
    }

    /// Titles that only exist mid-call. `meeting in ` is Teams' in-meeting
    /// window; the bare app window is "<something> | Microsoft Teams", which is
    /// why the product name itself is not a marker here.
    private static let substringMarkers = [
        "zoom meeting",
        "zoom webinar",
        "meet.google.com",
        "whereby.com",
        "jitsi meet",
        "meeting in "
    ]

    /// Google Meet's tab title is bare — "Meet – abc-defg-hij" — so the word has
    /// to open the title, and the dash variants are shared with the roster
    /// reader rather than re-typed.
    ///
    /// Slack huddles have no marker here on purpose: "Huddle" is as much a
    /// Notion document as a Slack window. A huddle is still offered — Slack plus
    /// a busy microphone — it just isn't confirmed by a title.
    private static let leadingMarkers = MeetingRosterReader.meetLeadingTokens
}

/// A call Nod is offering to record.
///
/// One value rather than an app and a loose title beside it: the title is only
/// meaningful for the call it came from, and held separately the two had to be
/// assigned and cleared in a particular order to stay in step — an invariant
/// nothing could enforce and no test could catch.
struct DetectedCall: Equatable {
    let app: ConferencingApp
    /// The window title that confirmed this call, when a title is what confirmed
    /// it — a call proved only by a helper process or a busy microphone has none.
    let title: String?
}

/// The detector's memory between ticks: how long a call has been visible, what
/// the user already answered, and whether the recording in progress is one we
/// can honestly say has ended.
struct MeetingDetectionState: Equatable {
    enum Event: Equatable {
        /// Offer to record `app`'s call.
        case invite(ConferencingApp)
        /// Take back an offer nobody answered — the call went away, or a
        /// recording started without it.
        case withdraw
        /// The call this recording was following is over.
        case callEnded(ConferencingApp)
    }

    /// Consecutive sightings before we speak up. A window title that flickers
    /// for one tick is not a meeting.
    static let sightingsToInvite = 2
    /// Consecutive misses before a call counts as over — higher than the invite
    /// threshold on purpose, because cutting a live meeting short is the worse
    /// of the two mistakes.
    static let missesToClear = 3

    private var tracked: ConferencingApp?
    private var sightings = 0
    private var misses = 0
    private var invited = false
    private var handled = false
    /// The call the current recording is following, set only while a signal that
    /// *dies with the call* holds it up. The microphone can't: our own recording
    /// holds it too. A window title can't either: it goes away when the user
    /// switches tab or Space, and a recording finished mid-conversation is a far
    /// worse outcome than one the user has to stop by hand.
    private var armed: ConferencingApp?

    mutating func advance(call: ConferencingApp?, armsAutoFinish: Bool, isRecording: Bool) -> Event? {
        guard let call else { return advanceWithoutCall(isRecording: isRecording) }

        if tracked != call {
            self = MeetingDetectionState()
            tracked = call
        }
        misses = 0
        sightings += 1

        guard !isRecording else {
            if armsAutoFinish { armed = call }
            // A recording under way is an answer, however it was started: the
            // user is not asked about this call again if they stop mid-way.
            handled = true
            guard invited else { return nil }
            invited = false
            return .withdraw
        }

        guard !handled, !invited, sightings >= Self.sightingsToInvite else { return nil }
        invited = true
        return .invite(call)
    }

    private mutating func advanceWithoutCall(isRecording: Bool) -> Event? {
        guard tracked != nil else { return nil }
        misses += 1
        guard misses >= Self.missesToClear else { return nil }

        let ended = armed
        let wasInvited = invited
        self = MeetingDetectionState()
        if isRecording, let ended { return .callEnded(ended) }
        return wasInvited ? .withdraw : nil
    }

    /// The user answered — started, dismissed, or let the card time out. The
    /// same call never asks twice.
    mutating func markHandled() {
        handled = true
        invited = false
    }
}

/// The user's switches for meeting detection: whether it runs at all, and the
/// apps it must stay quiet about.
///
/// One object rather than a defaults enum plus a published mirror, because two
/// surfaces bind to it live — the Settings toggle and the card's "Never for
/// Zoom" — and a second copy of a switch is a second copy that drifts.
@MainActor
final class MeetingDetectionPreference: ObservableObject {
    /// On by default, unlike ambient context. It reads a process list and the
    /// window titles of conferencing apps, stores nothing anywhere, and a
    /// detector the user has to go and find is a detector that isn't there when
    /// the meeting starts. Settings → General turns it off; see
    /// `docs/policies/privacy.md` § 3.10(c).
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Apps the user told us not to detect. Separate from `ScreenExclusions` on
    /// purpose: "don't offer to record my Discord calls" is a different wish
    /// from "never read this app's windows", and a blocklist entry already
    /// implies both.
    @Published private(set) var mutedBundleIDs: Set<String>

    private let defaults: UserDefaults
    private static let enabledKey = "meeting.detect.enabled"
    private static let mutedAppsKey = "meeting.detect.mutedApps"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        mutedBundleIDs = Set(defaults.stringArray(forKey: Self.mutedAppsKey) ?? [])
    }

    func setMuted(_ muted: Bool, bundleID: String) {
        if muted { mutedBundleIDs.insert(bundleID) } else { mutedBundleIDs.remove(bundleID) }
        defaults.set(mutedBundleIDs.sorted(), forKey: Self.mutedAppsKey)
    }

    /// The muted apps as something showable, so Settings can offer them back.
    var mutedApps: [ConferencingApp] {
        ConferencingApp.allCases.filter { mutedBundleIDs.contains($0.rawValue) }
    }
}

/// Notices that a call has started and offers to record it, then notices that
/// the same call has ended and hands that to the session.
///
/// Three properties keep this defensible, and all three are enforced here:
///
///  * **Nothing is stored.** A window title is matched in memory and dropped
///    with the offer it raised; no row, no file, nothing leaves the Mac.
///  * **The blocklist wins.** An excluded or muted app is dropped from the scan
///    before any window is looked at.
///  * **It cannot start a recording on its own.** Accepting the card raises the
///    panel and asks it to start, so the subscription, consent and language
///    gates all still run — see `MeetingSession.requestAutoStart`.
@MainActor
final class MeetingDetector: ObservableObject {
    /// The call being offered, if any.
    @Published private(set) var invitation: DetectedCall?

    private let session: MeetingSession
    private let exclusions: ScreenExclusions
    private let preference: MeetingDetectionPreference
    private var state = MeetingDetectionState()
    private var invitationRaisedAt: Date?
    private var timerTask: Task<Void, Never>?
    private var preferenceObserver: AnyCancellable?
    private var sleepObservers: [NSObjectProtocol] = []

    /// Sampling interval. Two sightings make an invitation, so a call is offered
    /// 10–15 seconds in — inside the "we're all here, let's start" minute, and
    /// slow enough that the window scan is not a background loop that never
    /// stops: every tick with a browser running costs an enumeration of every
    /// on-screen window on the machine.
    private static let interval: TimeInterval = 5

    /// How long an unanswered card stays up. Past this the user has seen it and
    /// chosen not to act; the panel's own Start button is two clicks away, and a
    /// card that sits there for the whole call is just clutter.
    private static let invitationLifetime: TimeInterval = 45

    init(session: MeetingSession, exclusions: ScreenExclusions, preference: MeetingDetectionPreference) {
        self.session = session
        self.exclusions = exclusions
        self.preference = preference
        // `dropFirst` because `@Published` replays the current value on
        // subscribe, and reacting to it here would run `start()` from inside
        // this initializer. The caller does that, once.
        preferenceObserver = preference.$isEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.start() } else { self?.stop() }
            }
        observeSleep()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers {
            center.removeObserver(observer)
        }
    }

    /// No call starts on a sleeping Mac, and a loop that keeps its schedule
    /// across sleep only wakes the machine to learn nothing. Display sleep is
    /// deliberately not watched: a call can outlive the display going dark, and
    /// suspending then would lose the end of it.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAfterWake() }
            }
        ]
    }

    private func refreshAfterWake() {
        guard preference.isEnabled else { return }
        start()
    }

    func start() {
        guard timerTask == nil, preference.isEnabled else { return }
        Log.screen.info("detect: meeting detection on (every \(Int(Self.interval))s)")
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        state = MeetingDetectionState()
        withdraw()
        Log.screen.info("detect: meeting detection off")
    }

    /// Start recording this call — through the panel, never around it.
    func accept() {
        guard let invitation else { return }
        Log.screen.info("detect: accepted \(invitation.app.displayName)")
        state.markHandled()
        withdraw()
        session.requestAutoStart()
        NotificationCenter.default.post(name: .nodShowPanel, object: nil)
    }

    /// "Not now" — this call is answered, and it won't ask again.
    func decline() {
        guard let invitation else { return }
        Log.screen.info("detect: declined \(invitation.app.displayName)")
        state.markHandled()
        withdraw()
    }

    /// "Never for Zoom" — every future call in that app goes unoffered.
    func mute(_ app: ConferencingApp) {
        Log.screen.info("detect: muted \(app.displayName)")
        preference.setMuted(true, bundleID: app.rawValue)
        state.markHandled()
        withdraw()
    }

    private func withdraw() {
        invitation = nil
        invitationRaisedAt = nil
    }

    private func tick() {
        guard preference.isEnabled else { return stop() }
        expireInvitation()

        let isRecording = session.meeting != .idle
        let signals = signals()
        let call = MeetingDetection.call(in: signals)
        // Only a call-only helper process arms the automatic finish. Neither the
        // microphone nor a window title can: the mic is held by our own
        // recording, and a title vanishes on a tab switch, a minimise or a Space
        // change — all of which happen mid-meeting, and all of which used to cut
        // the recording short.
        let armsAutoFinish = call.map(signals.helperBacked.contains) ?? false
        // Names the signal that actually confirmed the call, `helperBacked`
        // first: this is the one line covering the rule above, and "window" for
        // a call only a process proves is the answer to the wrong question when
        // someone reports that Nod didn't wrap up after their call.
        let evidence = call.map { app in
            if signals.helperBacked.contains(app) { return "helper" }
            return signals.inCall.contains(app) ? "window" : "microphone"
        } ?? "none"

        switch state.advance(call: call, armsAutoFinish: armsAutoFinish, isRecording: isRecording) {
        case let .invite(app):
            Log.screen.info("detect: \(app.displayName) call in progress (\(evidence)) — offering to record")
            // The card sits in a screen corner while the user is looking at the
            // call — unheard, it is only found by accident.
            UISound.meetingDetected.play(recording: isRecording)
            invitation = DetectedCall(app: app, title: signals.titles[app])
            invitationRaisedAt = Date()
        case .withdraw:
            withdraw()
        case let .callEnded(app):
            withdraw()
            session.callEnded(app: app.displayName)
        case nil:
            break
        }
    }

    private func expireInvitation() {
        guard let invitationRaisedAt,
              Date().timeIntervalSince(invitationRaisedAt) >= Self.invitationLifetime
        else { return }
        Log.screen.info("detect: invitation timed out")
        state.markHandled()
        withdraw()
    }

    private func signals() -> CallSignals {
        let rules = exclusions.rules
        let muted = preference.mutedBundleIDs
        let (allRunning, helpers) = ConferencingApp.running(excluding: rules)
        let candidates = allRunning.filter { !muted.contains($0.0.rawValue) }
        guard !candidates.isEmpty else { return CallSignals() }

        let present = Set(candidates.map(\.0))
        let pids = Dictionary(candidates, uniquingKeysWith: { first, _ in first })
        return CallSignals(
            running: candidates.map(\.0),
            helperBacked: helpers.intersection(present),
            micUsers: micUsers(among: present),
            titles: Self.appsShowingACall(pids: pids, rules: rules)
        )
    }

    /// Which candidates are holding the microphone.
    ///
    /// Skipped entirely unless a native app is up, because that is the only
    /// thing the answer is used for (`MeetingDetection.call`) — a browser needs
    /// a window title regardless. Without the guard, the walk runs on every tick
    /// of every day for anyone with a browser open, and it is not cheap: one HAL
    /// round trip to list the audio processes, then two more per process.
    private func micUsers(among candidates: Set<ConferencingApp>) -> Set<ConferencingApp> {
        guard candidates.contains(where: { !$0.isBrowser }) else { return [] }
        let recording = AudioProcessActivity.bundleIDsRecording(excluding: Bundle.main.bundleIdentifier)
        return candidates.filter { recording.contains($0.rawValue) }
    }

    /// Which candidate apps have a window whose title names a live call.
    ///
    /// The window *list*, not the focused window: during a call the user is
    /// usually reading something else, with the meeting window behind it. The
    /// blocklist is applied per window before the title is matched, and only
    /// titles of the candidate apps are ever looked at.
    ///
    /// `CGWindowListCopyWindowInfo` rather than `SCShareableContent`, which is
    /// what the other two window readers in the app use: those run once per
    /// recording, this one runs every few seconds for the life of the app, and
    /// the ScreenCaptureKit call is an XPC round trip into `replayd` that
    /// materialises a wrapper object per window. Measured inside the app:
    /// 0.11 ms here against a daemon hop there, for the same two fields. Window
    /// *names* need the same Screen Recording grant either way.
    private nonisolated static func appsShowingACall(
        pids: [ConferencingApp: pid_t],
        rules: ScreenExclusionRules
    ) -> [ConferencingApp: String] {
        // Never prompts: the grant is asked for where the user expects it.
        guard CGPreflightScreenCaptureAccess() else { return [:] }
        let byPID = Dictionary(pids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var found: [ConferencingApp: String] = [:]
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = byPID[pid],
                  found[app] == nil,
                  let title = window[kCGWindowName as String] as? String,
                  !rules.excludesWindow(title: title),
                  MeetingDetection.namesActiveCall(title)
            else { continue }
            found[app] = title
        }
        return found
    }
}
