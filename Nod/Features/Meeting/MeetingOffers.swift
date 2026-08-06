import Combine
import Foundation

/// Why Nod thinks a meeting is happening.
///
/// Two sources answer that, and they are not interchangeable: the calendar knows
/// the meeting's name and who is in it before anything has started, and the Mac
/// knows a call is running only once the user has opened it themselves. The
/// calendar's answer is strictly richer wherever both are available.
enum MeetingOffer: Equatable {
    case scheduled(ScheduledMeeting)
    case detected(DetectedCall)

    /// Identity for the notch's transition machinery — a different meeting has
    /// to count as different content, or the second replaces the first in place
    /// with no animation.
    var identity: String {
        switch self {
        case let .scheduled(meeting): "scheduled.\(meeting.fingerprint)"
        case let .detected(call): "detected.\(call.app.rawValue)"
        }
    }

    /// Which is worth showing when both sources have something to say.
    var isRicher: Bool {
        if case .scheduled = self { return true }
        return false
    }
}

/// The single place that decides whether to ask the user to record.
///
/// Both sources used to raise their own offer, with their own sound, their own
/// expiry and their own memory of what had been answered. Nothing joined them,
/// so one meeting produced two: decline the calendar's card at 13:59, open the
/// call at 14:01, and the detector asks again as if nothing had happened.
///
/// They cannot be joined by identity — the calendar knows `title@start`, the
/// detector knows a bundle identifier, and neither can compute the other's key.
/// So the memory here is a *quiet period*: once a meeting has been answered,
/// nothing asks again until it would be over. That is the one thing both sources
/// can agree on without knowing anything about each other.
@MainActor
final class MeetingOffers: ObservableObject {
    /// What is being put to the user, if anything.
    @Published private(set) var current: MeetingOffer?

    private let detector: MeetingDetector
    private let schedule: ScheduledMeetingWatcher
    private let session: MeetingSession
    private let preference: MeetingDetectionPreference

    /// No offer is raised before this. Set whenever one is answered, however.
    private var quietUntil: Date?
    private var expiry: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// How long an unanswered offer stays up. Past this the user has seen it and
    /// chosen not to act; the notch's own Start is two clicks away, and a card
    /// that sits there for the whole call is clutter.
    private static let lifetime: TimeInterval = 45
    /// How long the quiet period runs when only the Mac told us — no invitation,
    /// so no end time to take it from.
    private static let unscheduledQuiet: TimeInterval = 10 * 60

    init(
        detector: MeetingDetector,
        schedule: ScheduledMeetingWatcher,
        session: MeetingSession,
        preference: MeetingDetectionPreference
    ) {
        self.detector = detector
        self.schedule = schedule
        self.session = session
        self.preference = preference

        Publishers.MergeMany(
            detector.$candidate.map { _ in () }.eraseToAnyPublisher(),
            schedule.$candidate.map { _ in () }.eraseToAnyPublisher(),
            session.$meeting.map { _ in () }.eraseToAnyPublisher()
        )
        // `@Published` fires in `willSet`, so the new value is not readable
        // until the next turn of the runloop — and this reads all three.
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.reconsider() }
        .store(in: &cancellables)
    }

    /// Record this meeting. Through `requestAutoStart` like every other entry
    /// point, so the subscription, consent and language gates all still run.
    func accept() {
        guard current != nil else { return }
        answer()
        session.requestAutoStart()
    }

    /// "Not now" — for this meeting, from either source.
    func decline() {
        guard current != nil else { return }
        answer()
    }

    /// "Never for Zoom". Only a detected call can say which app it is; a
    /// calendar entry linking to Zoom is muted by the same list, but through
    /// `ConferencingHost`.
    func mute(_ app: ConferencingApp) {
        preference.setMuted(true, bundleID: app.rawValue)
        answer()
    }

    /// The app to offer muting, when the offer names one. A meeting whose
    /// invitation links to a web-only product has no app to mute.
    var mutableApp: ConferencingApp? {
        switch current {
        case let .detected(call): call.app
        case let .scheduled(meeting): meeting.host.flatMap(ConferencingHost.nativeApp)
        case nil: nil
        }
    }

    private func answer() {
        guard let current else { return }
        quietUntil = Self.quietEnd(for: current)
        switch current {
        case let .scheduled(meeting): schedule.answered(meeting)
        case .detected: detector.answered()
        }
        clear()
    }

    /// Until the meeting would be over, when the calendar told us when that is.
    /// Otherwise a flat window — long enough that a call the user declined does
    /// not come back, short enough that the next meeting still can.
    private static func quietEnd(for offer: MeetingOffer) -> Date {
        switch offer {
        case let .scheduled(meeting): max(meeting.endsAt, Date())
        case .detected: Date().addingTimeInterval(unscheduledQuiet)
        }
    }

    private func clear() {
        expiry?.cancel()
        expiry = nil
        guard current != nil else { return }
        current = nil
    }

    private func reconsider() {
        // A recording answers everything: the user is in a meeting, whichever
        // one it is, and asking about it is noise.
        guard session.meeting == .idle else {
            if current != nil { answer() }
            return
        }
        guard let candidate = best() else { return clear() }

        // Already asking. A richer source arriving mid-offer upgrades the card
        // in place — the calendar knows the name and the people the window title
        // never had — but it is the same question, so it does not sound again.
        if let current {
            guard candidate.isRicher, !current.isRicher else { return }
            self.current = candidate
            return
        }

        if let quietUntil, Date() < quietUntil { return }
        raise(candidate)
    }

    /// The calendar first, whenever it has something: a window title is a
    /// lottery where an invitation is a name and a guest list.
    private func best() -> MeetingOffer? {
        if let scheduled = schedule.candidate, !isMuted(scheduled) {
            return .scheduled(scheduled)
        }
        if let detected = detector.candidate {
            return .detected(detected)
        }
        return nil
    }

    /// "Never for Zoom" reaches a calendar entry too, when its link names a
    /// product with a Mac app. A `meet.google.com` link names no app — nothing
    /// to mute, and nothing this can honestly suppress.
    private func isMuted(_ meeting: ScheduledMeeting) -> Bool {
        guard let app = meeting.host.flatMap(ConferencingHost.nativeApp) else { return false }
        return preference.mutedBundleIDs.contains(app.rawValue)
    }

    private func raise(_ offer: MeetingOffer) {
        Log.screen.info("offer: raised \(offer.isRicher ? "from the calendar" : "from a running call")")
        UISound.meetingDetected.play(recording: false)
        current = offer
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.lifetime * 1_000_000_000))
            guard let self, !Task.isCancelled, current != nil else { return }
            Log.screen.info("offer: timed out")
            answer()
        }
    }
}
