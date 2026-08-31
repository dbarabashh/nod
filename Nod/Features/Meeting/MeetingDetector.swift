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
    /// Whether a call is running, or **nil when this tick could not tell**.
    ///
    /// Saying no requires having looked, and two things stop a tick from
    /// having looked. A FaceTime or Telegram call is outside `ConferencingApp`
    /// entirely, so "nothing to scan" is not evidence of a quiet room; and
    /// without the Screen Recording grant the window scan comes back empty,
    /// which a busy desktop and an idle one both do.
    static func callVerdict(
        evidence: DetectedEvidence?,
        sawCandidates: Bool,
        hasScreenAccess: Bool
    ) -> Bool? {
        if evidence != nil { return true }
        return sawCandidates && hasScreenAccess ? false : nil
    }

    /// The app whose call is on, or nil.
    static func call(in signals: CallSignals) -> DetectedEvidence? {
        if let app = signals.running.first(where: signals.helperBacked.contains) {
            return DetectedEvidence(app: app, kind: .helper)
        }
        if let app = signals.running.first(where: signals.titles.keys.contains) {
            return DetectedEvidence(app: app, kind: .window)
        }
        if let app = signals.running.first(where: { !$0.isBrowser && signals.micUsers.contains($0) }) {
            return DetectedEvidence(app: app, kind: .microphone)
        }
        // A browser holding the microphone is the only thing left that can see
        // a call in a background tab: the window title belongs to whichever tab
        // is in front, so a Meet call the user has tabbed away from proves
        // itself no other way. It is also the weakest signal here — a voice
        // message and a dictation box hold the microphone too — which is why it
        // carries its own, much longer confirmation.
        return signals.running.first { $0.isBrowser && signals.micUsers.contains($0) }
            .map { DetectedEvidence(app: $0, kind: .browserMicrophone) }
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

/// What put an app in a call, and how much confirmation that is worth.
///
/// The threshold belongs to the evidence rather than to the state machine: a
/// window titled "Zoom Meeting" is worth believing in ten seconds, a browser
/// holding the microphone is not worth believing until it has held it for a
/// minute.
struct DetectedEvidence: Equatable {
    enum Kind: Equatable {
        /// A process that exists only while the call does.
        case helper
        /// A window whose title names a live call.
        case window
        /// A native conferencing app holding the microphone.
        case microphone
        /// A browser holding the microphone, with no title to confirm it.
        case browserMicrophone

        /// Sightings before Nod speaks up. `MeetingDetector.interval` is the
        /// tick, so these are multiples of five seconds.
        var sightingsToInvite: Int {
            self == .browserMicrophone ? 12 : 2
        }

        /// Whether this evidence can end a recording on its own. Only a process
        /// that dies with the call: a title vanishes on a tab switch, and every
        /// microphone signal is confounded by our own recording holding it.
        var armsAutoFinish: Bool {
            self == .helper
        }

        var name: String {
            switch self {
            case .helper: "helper"
            case .window: "window"
            case .microphone: "microphone"
            case .browserMicrophone: "browser-microphone"
            }
        }
    }

    let app: ConferencingApp
    let kind: Kind
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

    /// Misses before a call counts as over — higher than any invite
    /// threshold on purpose, because cutting a live meeting short is the worse
    /// of the two mistakes.
    static let missesToClear = 3

    private var tracked: ConferencingApp?
    /// Sightings of `tracked`, not necessarily consecutive: a miss increments
    /// `misses` and leaves this alone, so a title that blinks out for a tick
    /// still accumulates. Only `missesToClear` in a row wipes it.
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

    mutating func advance(evidence: DetectedEvidence?, isRecording: Bool) -> Event? {
        guard let evidence else { return advanceWithoutCall(isRecording: isRecording) }
        let call = evidence.app

        if tracked != call {
            self = MeetingDetectionState()
            tracked = call
        }
        misses = 0
        sightings += 1

        guard !isRecording else {
            if evidence.kind.armsAutoFinish { armed = call }
            // A recording under way is an answer, however it was started: the
            // user is not asked about this call again if they stop mid-way.
            handled = true
            guard invited else { return nil }
            invited = false
            return .withdraw
        }

        guard !handled, !invited, sightings >= evidence.kind.sightingsToInvite else { return nil }
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
    /// One entry per muted product, not per bundle id — otherwise muting Teams
    /// counts as two.
    var mutedApps: [ConferencingApp] {
        ConferencingApp.products.filter { app in
            app.bundleIDs.contains { mutedBundleIDs.contains($0) }
        }
    }

    func setMuted(_ muted: Bool, app: ConferencingApp) {
        for bundleID in app.bundleIDs {
            setMuted(muted, bundleID: bundleID)
        }
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
    /// A call this Mac says is running, if any.
    ///
    /// A *candidate*, never an offer: whether the user is asked, with what sound
    /// and how often, belongs to `MeetingOffers` — the one place that can see
    /// this source and the calendar at the same time. Two objects each deciding
    /// to ask is how one meeting gets offered twice.
    @Published private(set) var candidate: DetectedCall?

    /// Whether a call is running, or nil while that cannot be established.
    /// Read by the live lookup's room gate — see `MeetingDetection.callVerdict`.
    @Published private(set) var callInProgress: Bool?

    private let session: MeetingSession
    private let exclusions: ScreenExclusions
    private let preference: MeetingDetectionPreference
    /// nil until the first tick, so the first answer is always reported.
    private var hadScreenAccess: Bool?
    private var tickCount = 0
    private var lastMicUsers: Set<ConferencingApp> = []
    private var state = MeetingDetectionState()
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
    /// Shared with `ScheduledMeetingWatcher`: both surfaces ask the same
    /// question and an offer that lingers longer on one than the other is a
    /// difference nobody chose.
    static let offerLifetime: TimeInterval = 45

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
                await tick()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        state = MeetingDetectionState()
        withdraw()
        // A detector that has stopped ticking still holds whatever it last
        // saw, and a stale `false` would leave the room gate open through a
        // real call for anyone who switched detection off.
        callInProgress = nil
        Log.screen.info("detect: meeting detection off")
    }

    /// The offer for this candidate has been answered — however. The call is not
    /// raised again, however long it runs.
    func answered() {
        state.markHandled()
        withdraw()
    }

    private func withdraw() {
        guard candidate != nil else { return }
        candidate = nil
    }

    private func tick() async {
        guard preference.isEnabled else { return stop() }

        tickCount += 1
        let isRecording = session.meeting != .idle
        let (signals, seen) = await signals()
        let call = MeetingDetection.call(in: signals)

        callInProgress = MeetingDetection.callVerdict(
            evidence: call,
            sawCandidates: !signals.running.isEmpty,
            hasScreenAccess: hadScreenAccess == true
        )

        // Per tick, so one reproduction answers "did it see the call at all?".
        // Split by what it carries, not by verbosity: app names and counts are
        // ours, window titles are the user's, and `sensitive` is the channel
        // that keeps the second out of a release build's unified log.
        Log.screen.debug(
            "detect: running=\(signals.running.map(\.displayName).joined(separator: ",")) "
                + "windows=\(seen.count) call=\(call?.app.displayName ?? "none") "
                + "evidence=\(call?.kind.name ?? "none")"
        )
        Log.screen.sensitive("detect: windows=[\(seen.joined(separator: " | "))]")

        switch state.advance(evidence: call, isRecording: isRecording) {
        case let .invite(app):
            Log.screen.info(
                "detect: \(app.displayName) call in progress (\(call?.kind.name ?? "?")) — offering to record"
            )
            // The card sits in a screen corner while the user is looking at the
            // call — unheard, it is only found by accident.
            candidate = DetectedCall(app: app, title: signals.titles[app])
        case .withdraw:
            withdraw()
        case let .callEnded(app):
            withdraw()
            session.callEnded(app: app.displayName)
        case nil:
            break
        }
    }

    /// Window *titles* need the Screen Recording grant, and without it the scan
    /// sees nothing — no error, no empty result to notice, just a detector that
    /// never speaks again. That is the failure this reports: a development build
    /// loses the grant on every rebuild, and a shipped one loses it whenever
    /// macOS decides the binary changed.
    private func noteScreenAccess(granted: Bool) {
        defer { hadScreenAccess = granted }
        guard granted != hadScreenAccess else { return }
        if granted {
            Log.screen.info("detect: screen recording granted — window titles readable again")
        } else {
            Log.screen.error("detect: no screen recording grant — window titles are invisible, so no call can be detected")
        }
    }

    /// The signals, and every candidate-app window the scan looked at. The
    /// second is only for the tick log, which is why it rides alongside rather
    /// than inside `CallSignals` — nothing decides anything from it.
    ///
    /// The window read happens off the main actor. Measured: the grant check is
    /// a ~9 ms round trip to `tccd` with no in-process cache, and the window
    /// list another ~2 ms — twenty-odd milliseconds every five seconds, which
    /// on the main thread is a dropped frame in whatever was animating.
    private func signals() async -> (CallSignals, seen: [String]) {
        let rules = exclusions.rules
        let muted = preference.mutedBundleIDs
        let (allRunning, helpers) = ConferencingApp.running(excluding: rules)
        let candidates = allRunning.filter { !muted.contains($0.0.rawValue) }
        guard !candidates.isEmpty else { return (CallSignals(), []) }

        let present = Set(candidates.map(\.0))
        let pids = Dictionary(candidates, uniquingKeysWith: { first, _ in first })
        let scan = await Task.detached(priority: .utility) {
            // One grant check, not two: `scan` used to preflight for itself.
            guard CGPreflightScreenCaptureAccess() else {
                return (granted: false, matched: [ConferencingApp: String](), seen: [String]())
            }
            let read = Self.scan(pids: pids, rules: rules)
            return (granted: true, matched: read.matched, seen: read.seen)
        }.value
        noteScreenAccess(granted: scan.granted)
        return (CallSignals(
            running: candidates.map(\.0),
            helperBacked: helpers.intersection(present),
            micUsers: micUsers(among: present),
            titles: scan.matched
        ), scan.seen)
    }

    /// Which candidates are holding the microphone.
    ///
    /// Skipped entirely unless a native app is up, because that is the only
    /// thing the answer is used for (`MeetingDetection.call`) — a browser needs
    /// a window title regardless. Without the guard, the walk runs on every tick
    /// of every day for anyone with a browser open, and it is not cheap: one HAL
    /// round trip to list the audio processes, then two more per process.
    private func micUsers(among candidates: Set<ConferencingApp>) -> Set<ConferencingApp> {
        // A native app is asked every tick — it is the signal that survives a
        // user who joined muted with the window behind something else. A browser
        // is asked one tick in four: it only matters after a minute of holding
        // the microphone anyway, and the query is a round trip into CoreAudio
        // that a browser being open should not buy every five seconds.
        let hasNative = candidates.contains { !$0.isBrowser }
        guard hasNative || tickCount.isMultiple(of: Self.browserMicEvery) else { return lastMicUsers }
        let recording = AudioProcessActivity.bundleIDsRecording(excluding: Bundle.main.bundleIdentifier)
        lastMicUsers = candidates.filter { recording.contains($0.rawValue) }
        return lastMicUsers
    }

    /// How often a browser-only tick asks CoreAudio. `browserMicrophone` needs
    /// twelve sightings, so a fresh answer every fourth is more than enough.
    private static let browserMicEvery = 4

    /// Which candidate apps have a window whose title names a live call, and —
    /// for the tick log only — every candidate window the scan looked at.
    ///
    /// The rejected titles are what separates "the window was never in the
    /// list" from "the list had it and the markers missed it"; from the outside
    /// those two are identical, and both read as no card.
    ///
    /// The window *list*, not the focused window: during a call the user is
    /// usually reading something else, with the meeting window behind it. The
    /// blocklist is applied per window before the title is read, and only
    /// windows of the candidate apps are ever looked at.
    ///
    /// `.optionAll`, not `.optionOnScreenOnly`: the latter drops every window
    /// that is not on the Space in front of you, so a call left running while
    /// you work somewhere else was seen for exactly one tick and then lost —
    /// and one sighting is below `sightingsToInvite`, so nothing was ever
    /// offered. Measured on a real Meet call: the on-screen list named only
    /// whichever browser window happened to be frontmost, and a different one
    /// every five seconds.
    ///
    /// `CGWindowListCopyWindowInfo` rather than `SCShareableContent`, which is
    /// what the other two window readers in the app use: those run once per
    /// recording, this one runs every few seconds for the life of the app, and
    /// the ScreenCaptureKit call is an XPC round trip into `replayd` that
    /// materialises a wrapper object per window. Measured inside the app:
    /// 2.3 ms here against a daemon hop there, for the same two fields. Window
    /// *names* need the same Screen Recording grant either way.
    private nonisolated static func scan(
        pids: [ConferencingApp: pid_t],
        rules: ScreenExclusionRules
    ) -> (matched: [ConferencingApp: String], seen: [String]) {
        let byPID = Dictionary(pids.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })

        let windows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        var found: [ConferencingApp: String] = [:]
        var seen: [String] = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let app = byPID[pid]
            else { continue }
            guard let title = window[kCGWindowName as String] as? String, !title.isEmpty else {
                seen.append("\(app.displayName):<unnamed>")
                continue
            }
            // The blocklist first, and before the title is recorded anywhere:
            // an excluded window must not reach the diagnostic either, or the
            // promise in this type's own doc — and in `privacy.md` § 3.8 — is
            // only true of the matching, not of the reading.
            guard !rules.excludesWindow(title: title) else {
                seen.append("\(app.displayName):<excluded>")
                continue
            }
            seen.append("\(app.displayName):\(title)")
            guard found[app] == nil, MeetingDetection.namesActiveCall(title) else { continue }
            found[app] = title
        }
        return (found, seen)
    }
}
