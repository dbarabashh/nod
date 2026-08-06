import AppKit
import Combine
import Foundation

/// A meeting the calendar says is starting, raised before anything is running.
///
/// The other offer Nod makes — `DetectedCall` — waits for a conferencing app to
/// give itself away, which means it arrives after the user has already opened
/// the call and therefore already knows about it. This one arrives first, from
/// an invitation that landed while they were working, possibly while they were
/// not looking. That is the whole difference between a recorder and an
/// assistant, and it is the only moment Nod can tell someone something they did
/// not already know.
struct ScheduledMeeting: Equatable {
    let title: String
    let startsAt: Date
    /// When the invitation says it is over — the natural end of the quiet
    /// period after the user has answered for this meeting.
    let endsAt: Date
    /// The conferencing product the invitation links to, so a meeting in an app
    /// the user muted can be left alone the same way a detected call is.
    let host: ConferencingHost?
    /// Everyone invited except the user.
    let others: [String]

    /// Identity across ticks. Two occurrences of a recurring meeting are
    /// different meetings; the same one seen a second time is not.
    var fingerprint: String {
        "\(title)@\(startsAt.timeIntervalSince1970)"
    }
}

extension ScheduledMeeting {
    init(_ occurrence: CalendarOccurrence) {
        title = occurrence.title
        startsAt = occurrence.startsAt
        endsAt = occurrence.endsAt
        host = occurrence.host
        // Through the rule that owns "who is this meeting with", not a second
        // copy of it — the same reason `CallBriefing.context` routes here.
        others = MeetingParticipants.resolve(calendar: occurrence, roster: nil).names
    }

    /// Whether a meeting starting then is worth speaking up about now.
    ///
    /// A narrow window on purpose. Earlier than this is a reminder, which the
    /// calendar already sends and Nod has no business repeating; later than this
    /// the user is in the room and the conferencing detector has it. What is
    /// left is the few minutes where someone is still at their desk and the
    /// meeting has begun without them noticing.
    static func isStarting(_ startsAt: Date, at now: Date) -> Bool {
        now >= startsAt.addingTimeInterval(-lead) && now <= startsAt.addingTimeInterval(grace)
    }

    func isStarting(at now: Date) -> Bool {
        Self.isStarting(startsAt, at: now)
    }

    /// How far ahead of the hour the offer appears.
    static let lead: TimeInterval = 60
    /// How long after the start it is still worth raising. Past this, either the
    /// user joined — and the call detector answers — or they are not coming.
    static let grace: TimeInterval = 3 * 60
}

/// Watches the calendar for a meeting about to start.
///
/// Reports a *candidate*, never an offer: whether the user is actually asked,
/// with what sound and how often, belongs to `MeetingOffers`, which is the one
/// place that can see this source and the call detector at the same time. Two
/// objects each deciding to ask is how the same meeting gets offered twice.
///
/// Separate from `MeetingDetector` because the trigger is different in kind: one
/// reads what is running on the Mac, this reads what the user agreed to attend.
@MainActor
final class ScheduledMeetingWatcher: ObservableObject {
    /// A meeting whose start time has arrived, if any.
    @Published private(set) var candidate: ScheduledMeeting?

    private let calendar: CalendarService
    private let session: MeetingSession
    /// Meetings already put to the user, by fingerprint. Asking twice about the
    /// same meeting is what makes a proactive app feel like a nagging one.
    private var answered: Set<String> = []
    private var timer: Task<Void, Never>?
    private var switchObserver: AnyCancellable?
    private var sleepObservers: [NSObjectProtocol] = []

    /// Slow on purpose. The window this has to land inside is minutes wide, and
    /// every tick is a calendar query — the detector runs at 5 seconds because a
    /// call can start at any instant, where a meeting starts at a time both
    /// sides already agreed on.
    private static let interval: TimeInterval = 20

    init(calendar: CalendarService, session: MeetingSession) {
        self.calendar = calendar
        self.session = session

        // The switch owns the loop, not just the query inside it. Left running
        // against a `calendar.isReadable` guard the timer would keep waking a
        // sleeping Mac to learn nothing — and `privacy.md` § 3.11 promises the
        // timer stops when the switch does, which a guard does not deliver.
        switchObserver = calendar.$isEnabled
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

    func start() {
        guard timer == nil, calendar.isEnabled else { return }
        Log.screen.info("scheduled: watching the calendar (every \(Int(Self.interval))s)")
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() {
        guard timer != nil else { return }
        timer?.cancel()
        timer = nil
        clear()
        Log.screen.info("scheduled: stopped watching the calendar")
    }

    /// The offer for this candidate has been answered — however. The meeting is
    /// remembered so it is never raised again this session.
    func answered(_ meeting: ScheduledMeeting) {
        answered.insert(meeting.fingerprint)
        clear()
    }

    private func clear() {
        // Guarded: `@Published` has no equality check, and this runs on every
        // tick that finds nothing — an unguarded nil→nil would push the notch
        // through a derivation three times a minute for the life of the app.
        guard candidate != nil else { return }
        candidate = nil
    }

    private func tick() {
        guard calendar.isReadable else { return clear() }
        let now = Date()

        // A recording under way answers every candidate: the user is in a
        // meeting, whichever one it is.
        guard session.meeting == .idle else {
            if let candidate { answered.insert(candidate.fingerprint) }
            return clear()
        }
        guard candidate == nil else {
            // Stop offering once its window has passed, even if nobody answered.
            if let candidate, !candidate.isStarting(at: now) { answered(candidate) }
            return
        }

        let starting = calendar
            .meetingsStarting(at: now)
            .first { ScheduledMeeting.isStarting($0.startsAt, at: now) && !answered.contains(Self.key($0)) }
        guard let starting else { return }

        Log.screen.info("scheduled: \(starting.title) starts now")
        candidate = ScheduledMeeting(starting)
    }

    /// The fingerprint of an entry that has not been turned into a
    /// `ScheduledMeeting` yet — checked before the attendee names are read, so a
    /// meeting already answered costs nothing to skip.
    private static func key(_ occurrence: CalendarOccurrence) -> String {
        "\(occurrence.title)@\(occurrence.startsAt.timeIntervalSince1970)"
    }

    /// No meeting starts on a sleeping Mac, and a loop that keeps its schedule
    /// across sleep only wakes the machine to learn nothing.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        ]
    }
}
