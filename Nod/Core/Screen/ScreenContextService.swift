import AppKit
import Combine
import Foundation
import Supabase

/// Ambient screen context: periodically reads the frontmost window as text and
/// stores it, so "Ask Nod" can answer from what you were looking at and not
/// only from what was said out loud.
///
/// Three properties make this defensible, and all three are enforced here
/// rather than promised in a policy:
///
///  * **Off by default.** `ScreenContextDefaults.isEnabled` gates every tick.
///  * **The blocklist wins.** An excluded app or window is never read, and the
///    check happens before the traversal, not after.
///  * **Bounded retention.** Every row carries an `expires_at`; nothing is kept
///    indefinitely, and a cron job deletes past it server-side.
@MainActor
final class ScreenContextService: ObservableObject {
    /// The user's ambient switch, observable. The stored value lives in a file
    /// (`ScreenContextDefaults`) that nothing can publish, so every surface
    /// showing the switch used to keep its own `@State` mirror and re-read the
    /// disk to stay honest. This is the one copy they all bind to.
    @Published private(set) var isAmbientEnabled = ScreenContextDefaults.isEnabled
    /// When a temporary pause runs out, or nil when nothing is paused.
    ///
    /// Distinct from switching the feature off: a pause is "not for the next few
    /// minutes", and it restores itself, so the user who wanted privacy for one
    /// call doesn't have to remember to turn ambient context back on afterwards
    /// — forgetting is how a feature quietly stops being used.
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var isRunning = false
    /// What the last deletion did, held briefly so a surface can say so.
    ///
    /// The deletion is server-side and there is no list on screen to visibly
    /// shrink, so without this the button looks like it did nothing. It lives on
    /// the service rather than in a view because the menu that triggers it is
    /// gone by the time the delete returns.
    @Published private(set) var lastDeletion: DeletionOutcome?
    /// Switched on but blocked on the Accessibility grant. A toggle that says
    /// "on" while nothing happens is worse than one that refuses to move, so
    /// the UI reads this and says what is missing.
    @Published private(set) var needsAccessibility = false

    private let supabase: SupabaseClient?
    private let exclusions: ScreenExclusions
    private let analytics: ProductAnalytics?
    private let reader: AccessibilityReader
    private var timerTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var trustWatchTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    /// When each screen state was last written, so an unchanged screen isn't
    /// re-sent on every tick. Not a plain "seen" set: the row's `observed_at` is
    /// where the digest reads how long a window was up from, and the dedup index
    /// means a static screen is one row — never re-sending it would leave that
    /// column stamped with the first sighting and report a three-hour Slack
    /// session as an instant.
    private var lastStoredAt: [String: Date] = [:]

    /// Sampling interval. Tight enough to catch a screen the user only glances
    /// at, loose enough that the AX walk isn't running constantly — each tick
    /// costs a tree traversal (bounded at 2000 nodes / 200 ms per message).
    /// Unchanged screens cost nothing downstream: the content hash collapses
    /// them before they reach the database.
    ///
    /// Stated in `privacy.md` § 3.10(b) — changing it changes a published
    /// claim, not just a constant.
    static let interval: TimeInterval = 5

    /// Floor between two pixel reads. Recognition costs real CPU, and the apps
    /// that need it are the ones the user sits in all day — without this it
    /// would run on nearly every tick.
    ///
    /// Stated in `privacy.md` § 3.10(b) alongside the sampling interval.
    private static let recognitionInterval: TimeInterval = 20
    private var lastRecognitionAt: Date?

    /// How often an unchanged screen is written again to move its `observed_at`
    /// forward. Far above the sampling interval — the point is a usable span,
    /// not a precise one, and every refresh is a round trip.
    private static let refreshInterval: TimeInterval = 60

    /// One page of the index read. Must stay at or below the project's
    /// PostgREST `max-rows`: a page trimmed server-side comes back short, and a
    /// short page is how the loop below decides it has reached the end.
    private static let indexPageSize = 1000

    /// Where the index read gives up. A busy day of a dozen apps lands well
    /// inside this; past it the oldest part of the window is dropped, and
    /// `observationIndex` says so rather than returning a quietly short answer.
    private static let maximumIndexRows = 6000

    /// How many matching rows the crossing ranks over. Wide enough that a noisy
    /// app can't crowd out the relevant window on recency alone, bounded because
    /// every row carries up to `maximumCharacters` of text.
    private static let linkedPoolSize = 40

    /// Content hashes per body request. They go in the query string — 64 hex
    /// characters each — so the chunk keeps the URL clear of proxy limits.
    private static let bodyChunkSize = 48

    init(
        supabase: SupabaseClient?,
        exclusions: ScreenExclusions,
        reader: AccessibilityReader = AccessibilityReader(),
        analytics: ProductAnalytics? = nil
    ) {
        self.supabase = supabase
        self.exclusions = exclusions
        self.reader = reader
        self.analytics = analytics
        observeWake()
    }

    /// Reports the switch moving, and nothing else.
    ///
    /// Never what was read, which app it came from, or what is on the blocklist
    /// — `privacy.md` § 3.8 rules those out by name, and they are the most
    /// tempting numbers in the product. Adoption and intensity come from
    /// `screen_observations`, the feature's own records, per the § 3.5 rule that
    /// what has a domain record is measured from it.
    private func report(_ outcome: ProductAnalytics.Outcome) {
        analytics?.record(.ambientContextToggled, properties: .init(surface: .settings, outcome: outcome))
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Whether the plan grants ambient capture. Pushed in from the composition
    /// root rather than resolved here, so `Core/Screen` stays unaware of how
    /// entitlements are fetched.
    ///
    /// Starts `true` and so fails OPEN, matching `EntitlementService.mayUse`: a
    /// subscriber whose entitlement fetch hiccupped must not silently lose
    /// capture, and the `screen_observations` RLS policy is the real gate
    /// regardless of what this says.
    @Published private(set) var isEntitled = true

    /// Re-runs the switch through `refresh()` so losing the feature stops an
    /// already-running capture loop, not just future ones.
    func setEntitled(_ entitled: Bool) {
        guard isEntitled != entitled else { return }
        isEntitled = entitled
        Log.screen.info("context: ambient entitlement \(entitled ? "granted" : "revoked")")
        refresh()
    }

    func start() {
        guard !isRunning, isEntitled, ScreenContextDefaults.isEnabled else { return }
        guard AccessibilityAccess.isTrusted else {
            needsAccessibility = true
            watchForTrust()
            Log.screen.info("context: accessibility not granted — ambient capture stays off")
            return
        }
        needsAccessibility = false
        trustWatchTask?.cancel()
        trustWatchTask = nil
        isRunning = true
        Log.screen.info("context: ambient capture on (every \(Int(Self.interval))s)")
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                await captureOnce()
            }
        }
    }

    /// Notices the Accessibility grant, which arrives with no notification of any
    /// kind: the user leaves for System Settings and comes back to a toggle that
    /// says "Needs access" forever. Re-reading on `didBecomeActive` — how
    /// `PermissionManager` handles mic and screen recording — is not enough here,
    /// because the panel is non-activating and the app can go a whole session
    /// without ever becoming active. So poll, but only while actually blocked, and
    /// stop the moment the answer arrives.
    private func watchForTrust() {
        trustWatchTask?.cancel()
        trustWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, ScreenContextDefaults.isEnabled else { return }
                guard AccessibilityAccess.isTrusted else { continue }
                Log.screen.info("context: accessibility granted — starting capture")
                trustWatchTask = nil
                refresh()
                return
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        trustWatchTask?.cancel()
        trustWatchTask = nil
        isRunning = false
        needsAccessibility = false
        lastStoredAt.removeAll()
        Log.screen.info("context: ambient capture off")
    }

    /// Re-reads the switch and the pause, then starts or stops accordingly.
    /// Called on launch, and whenever something outside this service wrote
    /// either of them.
    func refresh() {
        isAmbientEnabled = ScreenContextDefaults.isEnabled
        pausedUntil = ScreenContextDefaults.resolvePause(deadline: ScreenContextDefaults.pausedUntil, now: Date())
        pauseTask?.cancel()
        pauseTask = nil

        guard isEntitled, isAmbientEnabled else { return stop() }
        guard let until = pausedUntil else { return start() }
        stop()
        scheduleResume(at: until)
    }

    /// Re-resolves the pause after the Mac wakes.
    ///
    /// `scheduleResume` is a single sleeping task, and a timer that was due
    /// while the lid was shut cannot be relied on to fire the moment it opens.
    /// Without this a pause taken before closing the lid could outlive its own
    /// deadline until the next launch — which `privacy.md` § 3.10(b) says it
    /// never does.
    ///
    /// Subscribed in `init` rather than by the composition root: a second
    /// bootstrap call is a step someone forgets, and forgetting it silently
    /// reinstates the case this exists for.
    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Flip the switch: persist it, then start or stop. Every surface that
    /// offers the toggle goes through here, so none of them has to remember
    /// both halves.
    ///
    /// Switching on clears any pause — the user just asked for capture, and
    /// leaving a stale deadline in place would make the toggle do nothing.
    func setAmbientEnabled(_ enabled: Bool) {
        ScreenContextDefaults.setEnabled(enabled)
        report(enabled ? .enabled : .disabled)
        if enabled {
            ScreenContextDefaults.setPausedUntil(nil)
            // Asked here, not inside `start()`: this is the one moment the
            // system prompt is expected, because it follows the user's own
            // click. `start()` also runs at launch and on wake, where an
            // unexplained permission dialog is just noise.
            if !AccessibilityAccess.isTrusted { AccessibilityAccess.requestTrust() }
        }
        refresh()
    }

    /// Suspend capture for `duration`, then resume on its own.
    func pause(for duration: TimeInterval) {
        ScreenContextDefaults.setPausedUntil(Date().addingTimeInterval(duration))
        refresh()
        report(.paused)
        Log.screen.info("context: paused for \(Int(duration / 60)) min")
    }

    func resume() {
        ScreenContextDefaults.setPausedUntil(nil)
        refresh()
        Log.screen.info("context: resumed")
    }

    var isPaused: Bool {
        pausedUntil != nil
    }

    /// How long a capture is kept. Exposed so the consent disclosure can state
    /// the figure the user is actually on — it is selectable (7/14/30), and a
    /// sentence that always said "14 days" was untrue for everyone else at the
    /// exact moment they were agreeing to it.
    var retentionDays: Int {
        ScreenContextDefaults.retentionDays
    }

    /// Whether reading the screen is allowed *right now*.
    ///
    /// One predicate rather than a pause check bolted on at each step: cancelling
    /// the tick cannot abort an accessibility walk or an OCR pass already in
    /// flight, and that is equally true of switching the feature off — which
    /// `privacy.md` § 3.10(b) calls the one that "stops capture immediately".
    /// The switch is re-read from disk because another surface may have written
    /// it since the tick began.
    private var isCaptureAllowed: Bool {
        isEntitled && ScreenContextDefaults.isEnabled && !isPaused
    }

    /// The one place the four states are derived, so the sidebar row, the menu
    /// and Settings can't disagree about what "on" means.
    /// Entitlement outranks the switch: a Starter user who had capture on before
    /// the feature moved behind the plan should read "Pro only", not "On".
    var activityState: ActivityState {
        guard isEntitled else { return .notEntitled }
        guard isAmbientEnabled else { return .off }
        if let pausedUntil { return .paused(until: pausedUntil) }
        return needsAccessibility ? .needsAccessibility : .on
    }

    enum ActivityState: Equatable {
        case off
        case notEntitled
        case needsAccessibility
        case paused(until: Date)
        case on

        /// What the status column says. A paused state carries how long is
        /// left: "Paused" alone leaves the user with no idea whether capture
        /// comes back in a minute or at midnight, and the answer is the only
        /// reason to look at the row.
        func label(now: Date = Date()) -> String {
            switch self {
            case .off: "Off"
            case .notEntitled: "Pro only"
            case .needsAccessibility: "Needs access"
            case let .paused(until): "Paused \(Self.remaining(until: until, from: now))"
            case .on: "On"
            }
        }

        /// "42m" / "3h" — coarse on purpose, and short enough for a 232pt row.
        /// A ticking counter invites watching it, and a pause is not that
        /// precise.
        static func remaining(until date: Date, from now: Date = Date()) -> String {
            let minutes = Int(max(0, date.timeIntervalSince(now)) / 60)
            if minutes < 1 { return "<1m" }
            guard minutes >= 60 else { return "\(minutes)m" }
            return "\(minutes / 60)h"
        }
    }

    /// What a deletion did. A count, not a sentence: the wording and how long it
    /// stays on screen are the surface's business, and a `Core/` service that
    /// owns English can't be re-worded or localized per surface.
    enum DeletionOutcome: Equatable {
        /// `appName` is nil for a time-window delete, set for a per-app one —
        /// `AmbientContextSidebarRow`'s time-window menu and
        /// `ScreenPrivacySection`'s per-app menu both render whichever of
        /// these last fired (they share this one published property and can
        /// be on screen together), so the message has to name its own scope
        /// rather than read as whatever the OTHER surface would have said.
        case deleted(count: Int, appName: String?)
        case failed
    }

    /// Delete captured context observed since `cutoff` — nil clears all of it —
    /// and/or from one `sourceApp` — nil clears every app. The result reaches
    /// the UI through `lastDeletion`, because the menu that triggered this is
    /// already gone by the time it returns.
    ///
    /// The policy promises deletion is as easy as capture was
    /// (`privacy.md` § 3.10(b)); this is the code that makes that true —
    /// including the narrower promise the table's own migration comment
    /// makes: a user who excludes an app afterwards can find and delete what
    /// was already captured from it specifically, not just by time window.
    func deleteObservations(since cutoff: Date?, app sourceApp: String? = nil) async {
        guard let supabase else { return announce(.failed) }
        do {
            // `.minimal` + an exact count: the number comes back in a header
            // instead of as a body of every deleted row's UUID, which for
            // "Everything" over a 14-day index is thousands of ids parsed and
            // thrown away.
            let table = supabase.from("screen_observations").delete(returning: .minimal, count: .exact)
            // RLS already scopes the delete to the caller, so the remaining
            // filters are only the ones the user chose.
            let byTime = cutoff.map { table.gte("observed_at", value: $0) } ?? table
            let filtered = sourceApp.map { byTime.eq("source_app", value: $0) } ?? byTime
            let deleted = try await filtered.execute().count ?? 0
            // `lastStoredAt` is deliberately NOT cleared. It is what stops the
            // window still on screen from being re-sent on the next 5s tick, and
            // clearing it — as this once did — handed the user a delete that
            // undid itself within one interval, for the exact window they were
            // looking at when they reached for it.
            Log.screen.info("context: deleted \(deleted) observation(s)")
            let appName = sourceApp.map { AppDirectory.identity(forBundleID: $0).name }
            announce(.deleted(count: deleted, appName: appName))
        } catch {
            Log.screen.error("context: delete failed — \(error.localizedDescription)")
            announce(.failed)
        }
    }

    private func announce(_ outcome: DeletionOutcome) {
        lastDeletion = outcome
        announceTask?.cancel()
        announceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.announceDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.lastDeletion = nil
        }
    }

    private static let announceDuration: TimeInterval = 5

    private func scheduleResume(at date: Date) {
        pauseTask = Task { [weak self] in
            let seconds = date.timeIntervalSinceNow
            if seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            self?.resume()
        }
    }

    /// Accessibility describes a native window well and an Electron or
    /// canvas-drawn one barely at all — a Slack channel comes back as its own
    /// sidebar, the conversation missing. When the walk returns too little to
    /// answer from, the window is read off the pixels instead.
    ///
    /// Bounded on purpose: only when accessibility came up short, only for a
    /// window the blocklist has cleared, and not more often than
    /// `recognitionInterval` — recognition is CPU-bound in a way a tree walk
    /// isn't, and it must never become the steady state.
    private func recognizedIfAccessibilityIsThin(
        _ read: (title: String, text: String?),
        pid: pid_t,
        rules: ScreenExclusionRules
    ) async -> (title: String, text: String)? {
        // Whatever accessibility did return stays the answer whenever the pixel
        // read can't happen or comes back empty — a thin capture beats none.
        let asRead = read.text.map { (title: read.title, text: $0) }
        // Distinct content, not raw length: a repetitive sidebar now survives
        // line dedup, and counting it would clear the bar with no conversation.
        if let asRead,
           ScreenObservationBuilder.informativeLength(of: asRead.text) >= ScreenObservationBuilder.thinCharacters {
            return asRead
        }
        guard ScreenTextRecognizer.isAvailable else { return asRead }
        // The accessibility walk that got us here is long enough for the user to
        // pause or switch off during it, and this step is the one that grabs
        // pixels.
        guard isCaptureAllowed else { return nil }
        if let last = lastRecognitionAt, Date().timeIntervalSince(last) < Self.recognitionInterval { return asRead }

        lastRecognitionAt = Date()
        guard let recognized = await ScreenTextRecognizer.read(
            forProcessID: pid,
            matching: read.title,
            isAllowed: { !rules.excludesWindow(title: $0) }
        ), let text = ScreenObservationBuilder.text(from: recognized.texts) else { return asRead }

        let title = read.title.isEmpty ? recognized.title : read.title
        Log.screen.info("context: accessibility thin — read \(text.count) chars from pixels")
        return (title, text)
    }

    /// Every Nod on this Mac, not only this one.
    ///
    /// The sandbox build carries its own bundle id and installs beside the
    /// release app, so a guard that only skipped `Bundle.main` left each of them
    /// reading the other's window: the chat's own sidebar came back later as
    /// something "seen on your screen", and an address the user had typed into
    /// Nod was answered as if Nod had found it out.
    private static let ownBundleIDs: Set<String> = {
        let shipped: Set = ["com.example.nod", "com.example.nod.sandbox"]
        let base = (Bundle.main.bundleIdentifier ?? "").replacingOccurrences(of: ".sandbox", with: "")
        guard !base.isEmpty else { return shipped }
        return shipped.union([base, base + ".sandbox"])
    }()

    private func captureOnce() async {
        guard ScreenContextDefaults.isEnabled else { return stop() }
        guard isCaptureAllowed else { return }
        guard let supabase, let userID = supabase.auth.currentSession?.user.id else { return }
        // Built once per tick and threaded through. Every access rebuilds the
        // blocklist — twenty-odd bundle ids plus every enabled category's
        // keywords — and this path used to construct three of them.
        let rules = exclusions.rules
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              !Self.ownBundleIDs.contains(bundleID),
              !rules.excludesApp(bundleID: bundleID)
        else { return }

        let reader = reader
        let pid = app.processIdentifier
        let read = await Task.detached(priority: .utility) { () -> (title: String, url: String?, text: String?)? in
            guard let focused = reader.focusedWindowText(forProcessID: pid, bundleID: bundleID),
                  !rules.excludesWindow(title: focused.title, url: focused.url)
            else { return nil }
            return (focused.title, focused.url, ScreenObservationBuilder.text(from: focused.texts))
        }.value

        guard let read, !ScreenObservationBuilder.isBrowserChrome(url: read.url),
              let captured = await recognizedIfAccessibilityIsThin((read.title, read.text), pid: pid, rules: rules) else { return }
        let observation = ScreenObservation(
            userID: userID,
            sourceApp: bundleID,
            sourceTitle: captured.title,
            sourceURL: read.url,
            // The title leads the content on purpose. It is often the most
            // informative line on screen — the channel, ticket, or document
            // name — and search runs over `content`, so a title-only match
            // ("Jira (DM)") would otherwise be invisible. It also makes the
            // dedup hash per-window instead of per-body, so two channels with
            // identical chrome stay two observations.
            content: ScreenObservationBuilder.merge(title: captured.title, text: captured.text),
            retention: ScreenContextDefaults.retention
        )
        // Re-checked at the write too: it is the moment that matters, and the
        // reads above take long enough for the user to have withdrawn since.
        guard isCaptureAllowed else { return }
        let hash = observation.contentHash
        if let last = lastStoredAt[hash], Date().timeIntervalSince(last) < Self.refreshInterval { return }
        let previous = lastStoredAt[hash]
        lastStoredAt[hash] = observation.observedAt

        do {
            try await supabase
                .from("screen_observations")
                .upsert(observation, onConflict: "user_id,source_app,content_hash")
                .execute()
            // Titles name the channel, the ticket, the document — the most
            // identifying part of an ambient capture, and the unified log is
            // persistent and collected by sysdiagnose.
            Log.screen.info("context: stored \(observation.content.count) chars from \(bundleID)")
            Log.screen.debug("context: window title — \(captured.title)")
        } catch {
            lastStoredAt[hash] = previous
            Log.screen.error("context: store failed — \(error.localizedDescription)")
        }
    }
}

extension ScreenContextService {
    /// Screen text matching a question, most recent first.
    ///
    /// Plain text matching, not vector search: observations are short-lived and
    /// keyword-shaped ("which ticket did Leo move?"), and giving them their own
    /// embedding pipeline would mean a second index with its own retention and
    /// its own way to go stale. Returns nothing when ambient context is off.
    func recentContext(matching query: String, extraTerms: [String] = [], limit: Int = 4) async -> [ScreenObservation] {
        let terms = Self.searchTerms(in: query, extra: extraTerms)
        guard !terms.isEmpty, let rows = await matches(terms: terms, fetching: limit * 4) else { return [] }
        let relevant = Array(Self.relevant(rows, for: terms).prefix(limit))
        Log.screen.info("context: \(relevant.count)/\(rows.count) observation(s) kept for \(terms.count) term(s)")
        return relevant
    }

    /// Screen text matching names the *sessions* supplied — the projects a
    /// retrieved excerpt is about — rather than words from the question.
    ///
    /// This is the only path that can ground a link between what the user
    /// committed to and what they then had open: the question-driven lookup
    /// searches for the user's words, and a question about a commitment shares
    /// no vocabulary with the window where the work happened.
    ///
    /// Ranked by how strongly each observation matches, not by recency: the
    /// point is the tie to the session, and the newest window is rarely the one
    /// that carries it. One term is enough here — every term is a name the
    /// extraction already judged central to a session, not a stray word from a
    /// sentence.
    ///
    /// The pool it ranks is still the newest matches, because PostgREST can
    /// only order this query by a column. So the fetch is deliberately wide:
    /// with a narrow one, an app whose chrome happens to carry a seed word fills
    /// every slot with fresh noise and buries the window that actually matters.
    func linkedContext(
        aboutProjects projects: [[String]],
        limit: Int = 3,
        excluding excluded: Set<UUID> = []
    ) async -> [ScreenObservation] {
        let terms = Self.searchTerms(inProjects: projects)
        guard !terms.isEmpty else {
            Log.screen.info("context: no crossing — \(projects.count) grounded session(s) name no searchable project")
            return []
        }
        guard let rows = await matches(terms: terms, fetching: Self.linkedPoolSize) else { return [] }
        let ranked = Self.linked(rows, for: terms, limit: limit, excluding: excluded)
        Log.screen.info("context: \(ranked.count) linked observation(s) for \(terms.count) session term(s)")
        return ranked
    }

    /// Strongest matches first, recency only as a tiebreak, and never one the
    /// caller already has.
    static func linked(
        _ observations: [ScreenObservation],
        for terms: [String],
        limit: Int,
        excluding excluded: Set<UUID> = []
    ) -> [ScreenObservation] {
        observations
            .filter { !excluded.contains($0.id) }
            .map { (observation: $0, score: score(observation: $0, for: terms)) }
            .filter { $0.score > 0 }
            .sorted { ($0.score, $0.observation.observedAt) > ($1.score, $1.observation.observedAt) }
            .prefix(limit)
            .map(\.observation)
    }

    /// Live observations whose text matches any of `terms`. `nil` when ambient
    /// capture is off or the query failed — distinct from "matched nothing", so
    /// callers don't log an empty result as a miss.
    private func matches(terms: [String], fetching limit: Int) async -> [ScreenObservation]? {
        guard isEntitled, ScreenContextDefaults.isEnabled, let supabase else { return nil }
        do {
            return try await supabase
                .from("screen_observations")
                .select(ScreenObservation.columns)
                .gt("expires_at", value: Date())
                // The stored vector, not `content`: the expression form made
                // the planner parse every row it walked, and a question with
                // no match on screen took the statement timeout before the
                // answer could start. `simple`, matching how the column is
                // built: the default `english` config stems away the
                // Ukrainian half of what people ask.
                .textSearch("content_tsv", query: terms.joined(separator: " | "), config: "simple")
                .order("observed_at", ascending: false)
                .limit(limit)
                .execute()
                .value
        } catch {
            Log.screen.error("context: lookup failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// Everything seen in a window, newest first, folded per app.
    ///
    /// The keyword path above cannot answer "what was I working on": none of
    /// the words in that question ("working", "recently") appear on the screen
    /// it is asking about, so the match is always empty. A recap is a time
    /// query, not a text query — the window is the whole filter.
    ///
    /// Read in two passes, index then bodies. One pass of whole rows ordered
    /// newest-first had to be capped to keep the payload sane, and the cap made
    /// "my day" a query about the last couple of hours: a day generates far more
    /// screen states than the cap allowed, so the morning fell off the end
    /// silently. The index is small enough to cover the whole window, and only
    /// the windows that survive the fold are read in full.
    func activity(in window: DateInterval) async -> ScreenActivityDigest {
        guard isEntitled, ScreenContextDefaults.isEnabled, let supabase else { return ScreenActivityDigest(apps: []) }
        do {
            let index = try await observationIndex(in: window, from: supabase)
            guard !index.isEmpty else {
                Log.screen.info("context: no observations in the requested window")
                return ScreenActivityDigest(apps: [])
            }
            let plan = ScreenActivityDigest.plan(from: index)
            let wanted = plan.hashesToRead
            let bodies = try await observationBodies(for: wanted, from: supabase)
            let digest = ScreenActivityDigest.build(plan: plan, bodies: bodies)
            Log.screen.info(
                "context: \(index.count) observation(s) folded into \(digest.apps.count) app(s), "
                    + "\(bodies.count)/\(wanted.count) window text(s) read"
            )
            return digest
        } catch {
            Log.screen.error("context: activity lookup failed — \(error.localizedDescription)")
            return ScreenActivityDigest(apps: [])
        }
    }

    /// Every observation in the window, text excluded.
    ///
    /// Paged rather than one big `limit`: PostgREST trims a response to its
    /// `max-rows` setting without saying so, so a limit above it doesn't fetch
    /// more rows — it just hides that it didn't.
    private func observationIndex(
        in window: DateInterval,
        from supabase: SupabaseClient
    ) async throws -> [ScreenObservationIndex] {
        var index: [ScreenObservationIndex] = []
        while index.count < Self.maximumIndexRows {
            let page: [ScreenObservationIndex] = try await supabase
                .from("screen_observations")
                .select(ScreenObservationIndex.columns)
                .gt("expires_at", value: Date())
                .gte("observed_at", value: window.start)
                .lte("observed_at", value: window.end)
                .order("observed_at", ascending: false)
                .range(from: index.count, to: index.count + Self.indexPageSize - 1)
                .execute()
                .value
            index.append(contentsOf: page)
            if page.count < Self.indexPageSize { return index }
        }
        if let oldest = index.last?.observedAt {
            Log.screen.error(
                "context: activity index hit its \(Self.maximumIndexRows)-row cap — "
                    + "nothing before \(ISO8601DateFormatter().string(from: oldest)) was considered"
            )
        }
        return index
    }

    /// The text behind the screen states a plan named, longest read per state.
    ///
    /// Chunked because the hashes travel in the URL and a plan can name well
    /// over a hundred of them.
    private func observationBodies(
        for hashes: [String],
        from supabase: SupabaseClient
    ) async throws -> [String: String] {
        var bodies: [String: String] = [:]
        for start in stride(from: 0, to: hashes.count, by: Self.bodyChunkSize) {
            let chunk = Array(hashes[start ..< min(start + Self.bodyChunkSize, hashes.count)])
            let rows: [ScreenObservation] = try await supabase
                .from("screen_observations")
                .select(ScreenObservation.columns)
                .gt("expires_at", value: Date())
                .in("content_hash", values: chunk)
                .execute()
                .value
            for row in rows where (bodies[row.contentHash]?.count ?? 0) < row.content.count {
                bodies[row.contentHash] = row.content
            }
        }
        return bodies
    }

    /// Postgres matches any term (`|`), which is what gives useful recall — but
    /// a single common word then drags in a window that has nothing to do with
    /// the question. Keep only what matches more than one term, unless the
    /// question had just one to begin with.
    ///
    /// A term found in the **title** counts double: the title is what the
    /// window *is*, so a question that names it has already identified it.
    /// Counting every match the same threw those away — a window titled "Jira
    /// (DM)" lost a six-term question because it shared only "jira" with it.
    static func relevant(_ observations: [ScreenObservation], for terms: [String]) -> [ScreenObservation] {
        let required = terms.count > 1 ? 2 : 1
        return observations.filter { score(observation: $0, for: terms) >= required }
    }

    static func score(observation: ScreenObservation, for terms: [String]) -> Int {
        let title = observation.sourceTitle.lowercased()
        let body = observation.content.lowercased()
        return terms.reduce(0) { total, term in
            if title.contains(term) { return total + 2 }
            return body.contains(term) ? total + 1 : total
        }
    }

    /// Words worth matching on. Short and very common words are dropped: they
    /// match everything, which is the same as matching nothing.
    static func searchTerms(in query: String) -> [String] {
        Array(asked(query).prefix(termLimit))
    }

    /// The question's own words plus what the query-prep model thinks the page
    /// would carry — the page is usually in English whatever the question was
    /// asked in, and "пітчі від YC" shares no word with a YouTube title.
    static func searchTerms(in query: String, extra: [String]) -> [String] {
        var seen = Set<String>()
        let own = asked(query).prefix(termLimit)
        // A lower floor than the question's own words: the model already
        // chose these as page keys, and "Demo Day" is two of them.
        let added = extra
            .flatMap { TextTokens.acronyms(in: $0) + TextTokens.contentWords(in: $0, longerThan: 3, excluding: stopWords) }
            .prefix(termLimit)
        return (Array(own) + Array(added)).filter { seen.insert($0).inserted }
    }

    /// The same reduction over the projects the grounded sessions are about —
    /// what the crossing searches for instead of the question's own words.
    ///
    /// Taken a session at a time rather than from one flat list: eight grounded
    /// sessions where the first is called "customer onboarding revamp phase two"
    /// would otherwise spend every slot on that one session and let the other
    /// seven contribute nothing.
    static func searchTerms(inProjects projects: [[String]], limit: Int = termLimit) -> [String] {
        let perSession = projects.map { searchable($0.joined(separator: " ")) }
        let rounds = perSession.map(\.count).max() ?? 0
        let interleaved = (0 ..< rounds).flatMap { round in
            perSession.compactMap { round < $0.count ? $0[round] : nil }
        }
        var seen = Set<String>()
        return Array(interleaved.filter { seen.insert($0).inserted }.prefix(limit))
    }

    /// One rule for what this index can usefully match, so the two callers can't
    /// drift apart on the length floor or the stopword list — they feed the same
    /// `textSearch` query.
    private static func searchable(_ text: String) -> [String] {
        TextTokens.contentWords(in: text, longerThan: 4, excluding: stopWords)
    }

    /// A question's words, acronyms first: "YC" is the most specific thing in
    /// "the video from YC" and the one the length floor would drop. Project
    /// names go through `searchable` alone — "API" names nothing there.
    private static func asked(_ text: String) -> [String] {
        var seen = Set<String>()
        return (TextTokens.acronyms(in: text) + searchable(text)).filter { seen.insert($0).inserted }
    }

    /// Terms per query. Past a handful they stop narrowing and start matching
    /// every window that carries any one of them.
    static let termLimit = 6

    private static let stopWords: Set<String> = [
        "what", "when", "where", "which", "that", "this", "with", "from",
        "about", "there", "they", "have", "were", "been", "does", "did",
        "тому", "який", "яка", "було", "мене", "мені", "цього", "після"
    ]
}

/// User-facing switches for ambient capture. Off until the user turns it on —
/// this reads more than any other part of Nod, so it must never arrive by
/// default with an app update.
enum ScreenContextDefaults {
    static let enabledKey = "screen.context.enabled"
    static let retentionDaysKey = "screen.context.retentionDays"
    static let defaultRetentionDays = 14

    static var isEnabled: Bool {
        resolveEnabled(
            fileByte: (try? Data(contentsOf: enabledFileURL))?.first,
            legacyFlag: UserDefaults.standard.bool(forKey: enabledKey)
        )
    }

    /// The resolution rule, kept pure: the file wins when it exists (an explicit
    /// off must survive), and only an install that predates it falls back to the
    /// old UserDefaults key. Testable without touching the real file — a test
    /// that deleted that would switch ambient capture off for whoever ran it.
    static func resolveEnabled(fileByte: UInt8?, legacyFlag: Bool) -> Bool {
        if let fileByte { return fileByte == 1 }
        return legacyFlag
    }

    /// Writes the switch to a file, synchronously, before returning.
    ///
    /// `UserDefaults` is not enough here: its writes reach disk through
    /// `cfprefsd` on its own schedule, and `synchronize()` no longer forces
    /// that. A build stopped from Xcode (SIGKILL) or replaced by a rebuild dies
    /// before the flush lands, and the key comes back *absent* — not `false` —
    /// on the next launch, silently disabling capture. A one-byte file written
    /// atomically is on disk the moment this returns, so the one switch that
    /// decides whether Nod reads the screen survives an abrupt exit. The
    /// `UserDefaults` write stays only to migrate installs that predate the file.
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        try? Data([enabled ? 1 : 0]).write(to: enabledFileURL, options: .atomic)
    }

    private static let enabledFileURL = AppSupport.root.appendingPathComponent("ambient-context.enabled")

    /// The deadline of a temporary pause, or nil when none was ever set. May be
    /// in the past — resolving that is `ScreenContextService.refresh`'s job.
    ///
    /// File-backed for the same reason as the switch above: a lost write here
    /// fails in the direction that keeps capture running after the user asked
    /// it to stop, and that is the one direction this feature must not fail in.
    static var pausedUntil: Date? {
        guard let raw = try? String(contentsOf: pausedUntilFileURL, encoding: .utf8),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// An expired deadline is not a pause. Kept pure and separate from the file
    /// read so it can be tested without writing the real one — a test that left
    /// a pause behind would silently suppress capture for whoever ran it.
    ///
    /// Resolving on read, rather than counting down, is what lets a pause
    /// outlive the process it was set in: quitting during one neither cancels it
    /// nor extends it past its own end.
    static func resolvePause(deadline: Date?, now: Date) -> Date? {
        guard let deadline, deadline > now else { return nil }
        return deadline
    }

    static func setPausedUntil(_ date: Date?) {
        guard let date else {
            try? FileManager.default.removeItem(at: pausedUntilFileURL)
            return
        }
        try? Data(String(date.timeIntervalSinceReferenceDate).utf8)
            .write(to: pausedUntilFileURL, options: .atomic)
    }

    private static let pausedUntilFileURL = AppSupport.root.appendingPathComponent("ambient-context.pausedUntil")

    static var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: retentionDaysKey)
        return stored > 0 ? stored : defaultRetentionDays
    }

    static var retention: TimeInterval {
        TimeInterval(retentionDays) * 24 * 60 * 60
    }
}
