import AppKit
import EventKit
import Foundation

/// Reads the user's calendar so Nod can tell *which* meeting is happening, and
/// who is in it.
///
/// A window title is the only other thing available at that moment, and it is a
/// lottery: Teams names the meeting, Zoom says "Zoom Meeting" and Meet often
/// says nothing but a room code. The calendar names it every time, and it names
/// the same meeting the same way next week — which is what turns "you have
/// discussed this before" from a guess into a fact.
///
/// Deliberately **not** an integration. No account is connected, no OAuth, no
/// Google or Microsoft API, nothing on our servers: this is `EventKit` reading
/// the accounts already set up in the user's own Calendar app, on the device.
/// Off until the user switches it on, and read-only for the life of the app —
/// Nod never writes an event.
@MainActor
final class CalendarService: ObservableObject {
    /// The user's switch, independent of the system grant. Both have to be on:
    /// a grant cannot be handed back from inside the app, so turning this off is
    /// how someone stops Nod reading a calendar macOS still says it may.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.defaultsKey)
            Log.ui.info("calendar: \(isEnabled ? "on" : "off")")
            // Both, and in this order: `ensureAccess` returns immediately when
            // the grant already exists — switched off and back on, or granted in
            // an earlier launch — and that is exactly the path where the store
            // has never been warmed and the first brief would pay the cold
            // query on the frame the card appears.
            warm()
            Task { await ensureAccess() }
        }
    }

    @Published private(set) var status: PermissionStatus

    static let defaultsKey = "calendar.isEnabled"

    /// Held rather than made per read: a fresh `EKEventStore` re-opens the
    /// calendar database, and this is asked on every detected call.
    ///
    /// Built off the main thread, not here. The process's first `EKEventStore()`
    /// loads the framework and opens a daemon connection — ~2.5 ms, against
    /// ~0.1 ms for every one after — and this object is constructed inside
    /// `applicationDidFinishLaunching`, so building it here charged that to
    /// launch for everyone, including the majority who never switch the feature
    /// on. Nil until the same detached task that resolves the grant has made it.
    private var store: EKEventStore?
    private let defaults: UserDefaults
    private var activationObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
        // Assumed, not asked. The first `authorizationStatus` of the process is
        // a ~25 ms XPC round trip to `tccd` — every one after it is free — and
        // this initializer runs inside `applicationDidFinishLaunching`, so
        // asking here puts that on the critical launch path for every user,
        // including everyone who never turns the switch on. Resolved below, off
        // the main thread, long before anything reads it: the earliest consumer
        // is a detected call, tens of seconds away.
        status = .notDetermined

        // The grant can only be given or taken away outside this app, so coming
        // back to it is the one moment the answer can have changed. Without
        // this, a user who follows our own "Open Settings" button, allows
        // access, and switches back is still looking at "macOS is blocking
        // calendar access" with nothing in the app able to clear it.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        openStoreOffMainThread()
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Whether Nod may actually read anything right now.
    var isReadable: Bool {
        isEnabled && status == .authorized
    }

    private func refresh() {
        adopt(Self.currentStatus())
    }

    /// The launch-path variant: the first read is the expensive one, so it is
    /// made where nothing is waiting on it.
    private func openStoreOffMainThread() {
        Task.detached(priority: .utility) { [weak self] in
            let opened = EKEventStore()
            let resolved = Self.currentStatus()
            await MainActor.run {
                self?.store = opened
                self?.adopt(resolved)
            }
        }
    }

    private func adopt(_ next: PermissionStatus) {
        // Guarded: `@Published` has no equality check of its own, and this runs
        // on every app activation — an unchanged status would still invalidate
        // the settings row's body each time.
        guard next != status else { return }
        status = next
        // Guaranteed a transition by the guard, so this is the moment access was
        // gained and never a repeat of it.
        if next == .authorized { warm() }
    }

    /// Ask macOS for the grant, if it has never been asked.
    ///
    /// **Only ever call this from something the user just did**, with a window
    /// on screen — the Settings switch, or the button beside it. Never at launch.
    ///
    /// Nod launches as an accessory with no window (`LSUIElement`), and a TCC
    /// prompt raised in that state has nowhere to appear: EventKit returns
    /// `false` immediately, throws nothing, and leaves the authorization status
    /// `notDetermined` — and every later request in the same process then does
    /// the same, so the button beside the switch stops working too. Reconciling
    /// the grant at launch, which is the obvious way to heal a switch that says
    /// "on" against a macOS that was never asked, burns the one request the
    /// process gets before the user can see anything.
    ///
    /// The switch and the grant still go out of step for ordinary reasons — turn
    /// it on, quit before answering. That is repaired by the settings row
    /// offering to ask again, not by asking on its own.
    func ensureAccess() async {
        guard isEnabled, status == .notDetermined else { return }
        // The rule above, enforced rather than described. A prompt raised with
        // no window on screen is not refused — it is never shown, and it spends
        // the one request the process gets, so the button in Settings silently
        // stops working for the rest of the session. Cheap to check, and it
        // turns an hour of "EventKit returns false and throws nothing" into one
        // log line naming the cause.
        guard let store else { return }
        guard NSApp.keyWindow != nil else {
            Log.ui.error("calendar: access requested with no window on screen — refusing, macOS would not prompt")
            return
        }

        do {
            if #available(macOS 14.0, *) {
                _ = try await store.requestFullAccessToEvents()
            } else {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    store.requestAccess(to: .event) { _, error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
            }
        } catch {
            // Never swallowed: EventKit refusing to prompt at all looks
            // identical to a refusal from the outside, and the difference is the
            // whole diagnosis.
            Log.ui.error("calendar: access request failed — \(error.localizedDescription)")
        }
        // Read the answer back rather than trusting the call's `Bool`: a request
        // that never reached a prompt returns false too, and recording that as a
        // refusal would leave the user looking at "macOS is blocking calendar
        // access" for a question nobody was ever asked.
        refresh()
        Log.ui.info("calendar: access \(status == .authorized ? "granted" : "not granted")")
    }

    func openSystemSettings() {
        SystemSettings.open(privacyPane: "Privacy_Calendars")
    }

    /// The calendar entry the call now on screen belongs to, or nil.
    ///
    /// Synchronous on purpose. It is asked once per detected call — not once per
    /// detector tick — and after `warm()` a query costs a fraction of a
    /// millisecond, so the answer is ready for the offer's first frame instead
    /// of appearing under it a moment later.
    /// Every calendar entry the recording could belong to, best first.
    ///
    /// Asked more than once for the same recording, on purpose. The entry is not
    /// settled when a call starts — it gets created two minutes before, or
    /// halfway through, or once everyone has hung up — so the same question is
    /// put again while the recording runs and once more when it ends, each time
    /// against the whole span captured so far. `app` narrows the answer when a
    /// conferencing app is what started this; a recording begun by hand, for a
    /// meeting held across a table, passes none and is answered on time alone.
    func meetings(overlapping span: DateInterval, app: ConferencingApp? = nil) -> [CalendarOccurrence] {
        guard isReadable, let store else { return [] }
        let occurrences = store.events(matching: predicate(around: span, in: store)).compactMap(Self.occurrence)
        return CalendarOccurrence.ranked(occurrences, overlapping: span, app: app)
    }

    /// The moment a call is noticed, as a span of its own: everything before it
    /// has not been recorded yet.
    func meetingsNow(app: ConferencingApp) -> [CalendarOccurrence] {
        let now = Date()
        return meetings(overlapping: DateInterval(start: now, duration: 0), app: app)
    }

    /// The meeting happening now, but only if it can identify itself.
    ///
    /// Three callers used to spell this — stamping a lease with its identity,
    /// looking for a colleague's live room, and joining one — and each also
    /// repeated the "has an invitation id or a join link" guard. They must agree:
    /// if lease-stamping and discovery pick different occurrences, the feature
    /// silently stops matching and looks exactly like nobody else recording.
    func currentRoomIdentity() -> RoomIdentity? {
        guard let occurrence = meetings(overlapping: DateInterval(start: Date(), duration: 0)).first,
              occurrence.externalID != nil || occurrence.conferenceURL != nil
        else { return nil }
        return RoomIdentity(icalUID: occurrence.externalID, conferenceURL: occurrence.conferenceURL)
    }

    /// Entries whose *start* is near enough to now to be announced.
    ///
    /// A window of its own, an order of magnitude narrower than the one a
    /// finalize needs: that caller has to reach back for an entry the recording
    /// began inside, this one only wants the next few minutes. Asked on a timer,
    /// so every event the wider window returned would be decoded — notes
    /// lowercased, attendees read and name-parsed — and then thrown away.
    func meetingsStarting(at now: Date) -> [CalendarOccurrence] {
        guard isReadable, let store else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-ScheduledMeeting.grace),
            end: now.addingTimeInterval(ScheduledMeeting.lead),
            calendars: nil
        )
        return store.events(matching: predicate).compactMap(Self.occurrence)
    }

    /// Pays the event store's first-query cost somewhere the user is not
    /// watching.
    ///
    /// A store's *first* `events(matching:)` takes ~35 ms — the database is
    /// opened and the calendars are attached on demand — where every query after
    /// it is under a quarter of a millisecond. That cost is per store instance,
    /// so warming a throwaway one does nothing; it has to be this one. Landing
    /// on the frame the offer appears, it was two dropped frames in front of the
    /// user; landing here it is on a background thread nobody is waiting for.
    /// The bare query, not the real one: nothing here reads the events. What is
    /// being paid for is the store opening its database, which happens on any
    /// first query and on no later one.
    private func warm() {
        guard isReadable, let store else { return }
        let predicate = predicate(around: DateInterval(start: Date(), duration: 0), in: store)
        Task.detached(priority: .utility) {
            _ = store.events(matching: predicate)
        }
    }

    /// Widened on both sides of the span: an entry that started well before the
    /// recording did, or runs well past where it stopped, is still the meeting.
    private func predicate(around span: DateInterval, in store: EKEventStore) -> NSPredicate {
        store.predicateForEvents(
            withStart: span.start.addingTimeInterval(-Self.lookBehind),
            end: span.end.addingTimeInterval(Self.lookAhead),
            calendars: nil
        )
    }

    /// An `EKEvent` reduced to the four things the decision needs, or nil when
    /// it is not a meeting anyone is in.
    private static func occurrence(from event: EKEvent) -> CalendarOccurrence? {
        // Read once: `EKEvent.attendees` is a fresh bridged array of wrappers on
        // every access, and this used to ask for it twice per event.
        let invited = event.attendees ?? []
        guard !event.isAllDay,
              event.status != .canceled,
              let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty,
              let startsAt = event.startDate,
              let endsAt = event.endDate,
              !invited.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined })
        else { return nil }

        let text = [event.url?.absoluteString, event.location, event.notes]
            .compactMap { $0 }
            .joined(separator: " ")

        return CalendarOccurrence(
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            host: ConferencingHost.named(in: text),
            attendees: people(among: invited),
            externalID: event.calendarItemExternalIdentifier,
            conferenceURL: joinLink(in: text)
        )
    }

    /// The first link in an invitation that points at a conferencing product we
    /// recognise. Anything else — a doc, a ticket, an agenda — is not where the
    /// meeting happens, and handing it over as one would invent a room key that
    /// two colleagues could accidentally share.
    /// Built once. The detector is immutable and loading the data-detection
    /// engine is not free, and this runs for every event of every calendar read.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    private static func joinLink(in text: String) -> URL? {
        guard let detector = linkDetector else { return nil }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let host = url.host?.lowercased() else { continue }
            if ConferencingHost.allCases.contains(where: { $0.markers.contains(where: host.contains) }) {
                return url
            }
        }
        return nil
    }

    /// The people on an invitation.
    ///
    /// Rooms and equipment are invited the same way people are, and counting a
    /// conference room as a voice would tell diarization to find one more
    /// speaker than the recording holds. Anyone who declined is dropped for the
    /// same reason — they are on the invitation and not in the room.
    private static func people(among invited: [EKParticipant]) -> [CalendarAttendee] {
        invited.compactMap { participant in
            guard participant.participantType == .person,
                  participant.participantStatus != .declined,
                  let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else { return nil }
            return CalendarAttendee(
                display: CalendarAttendee.display(from: name),
                isSelf: participant.isCurrentUser
            )
        }
    }

    /// `nonisolated` so the launch path can pay the first, expensive read off
    /// the main thread. `EKEventStore.authorizationStatus` is a class method
    /// with no shared state of ours behind it.
    private nonisolated static func currentStatus() -> PermissionStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        // `.fullAccess` is the macOS 14 name for the same case `.authorized`
        // names on 13, and they share a raw value — matching both keeps one
        // branch working on each without a version check that reads as though
        // the two were different states.
        case .fullAccess: .authorized
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    /// A call that started before Nod noticed it still belongs to the event it
    /// started in, and the offer can stand for 45 seconds after that.
    private static let lookBehind: TimeInterval = 30 * 60
    private static let lookAhead: TimeInterval = 15 * 60
}
