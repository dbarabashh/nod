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
    @Published private(set) var isRunning = false
    @Published private(set) var lastCaptureAt: Date?
    /// Switched on but blocked on the Accessibility grant. A toggle that says
    /// "on" while nothing happens is worse than one that refuses to move, so
    /// the UI reads this and says what is missing.
    @Published private(set) var needsAccessibility = false

    private let supabase: SupabaseClient?
    private let exclusions: ScreenExclusions
    private let reader: AccessibilityReader
    private var timerTask: Task<Void, Never>?
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
    private static let interval: TimeInterval = 5

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

    init(supabase: SupabaseClient?, exclusions: ScreenExclusions, reader: AccessibilityReader = AccessibilityReader()) {
        self.supabase = supabase
        self.exclusions = exclusions
        self.reader = reader
    }

    func start() {
        guard !isRunning, ScreenContextDefaults.isEnabled else { return }
        guard AccessibilityAccess.isTrusted else {
            needsAccessibility = true
            // Asking here is the one moment the request is expected: the user
            // just switched the feature on.
            AccessibilityAccess.requestTrust()
            Log.screen.info("context: accessibility not granted — ambient capture stays off")
            return
        }
        needsAccessibility = false
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

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        isRunning = false
        needsAccessibility = false
        lastStoredAt.removeAll()
        Log.screen.info("context: ambient capture off")
    }

    /// Re-reads the toggle and starts or stops accordingly. Called when the
    /// user flips the switch in Settings.
    func refresh() {
        if ScreenContextDefaults.isEnabled {
            start()
        } else {
            stop()
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
        pid: pid_t
    ) async -> (title: String, text: String)? {
        // Whatever accessibility did return stays the answer whenever the pixel
        // read can't happen or comes back empty — a thin capture beats none.
        let asRead = read.text.map { (title: read.title, text: $0) }
        if let asRead, asRead.text.count >= ScreenObservationBuilder.thinCharacters { return asRead }
        guard ScreenTextRecognizer.isAvailable else { return asRead }
        if let last = lastRecognitionAt, Date().timeIntervalSince(last) < Self.recognitionInterval { return asRead }

        let rules = exclusions.rules
        lastRecognitionAt = Date()
        guard let recognized = await ScreenTextRecognizer.read(forProcessID: pid, isAllowed: {
            !rules.excludesWindow(title: $0)
        }), let text = ScreenObservationBuilder.text(from: recognized.texts) else { return asRead }

        let title = read.title.isEmpty ? recognized.title : read.title
        Log.screen.info("context: accessibility thin — read \(text.count) chars from pixels")
        return (title, text)
    }

    private func captureOnce() async {
        guard ScreenContextDefaults.isEnabled else { return stop() }
        guard let supabase, let userID = supabase.auth.currentSession?.user.id else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              !exclusions.excludesApp(bundleID: bundleID)
        else { return }

        let rules = exclusions.rules
        let reader = reader
        let pid = app.processIdentifier
        let read = await Task.detached(priority: .utility) { () -> (title: String, text: String?)? in
            guard let focused = reader.focusedWindowText(forProcessID: pid),
                  !rules.excludesWindow(title: focused.title)
            else { return nil }
            return (focused.title, ScreenObservationBuilder.text(from: focused.texts))
        }.value

        guard let read, let captured = await recognizedIfAccessibilityIsThin(read, pid: pid) else { return }
        let observation = ScreenObservation(
            userID: userID,
            sourceApp: bundleID,
            sourceTitle: captured.title,
            // The title leads the content on purpose. It is often the most
            // informative line on screen — the channel, ticket, or document
            // name — and search runs over `content`, so a title-only match
            // ("Jira (DM)") would otherwise be invisible. It also makes the
            // dedup hash per-window instead of per-body, so two channels with
            // identical chrome stay two observations.
            content: ScreenObservationBuilder.merge(title: captured.title, text: captured.text),
            retention: ScreenContextDefaults.retention
        )
        let hash = observation.contentHash
        if let last = lastStoredAt[hash], Date().timeIntervalSince(last) < Self.refreshInterval { return }
        let previous = lastStoredAt[hash]
        lastStoredAt[hash] = observation.observedAt

        do {
            try await supabase
                .from("screen_observations")
                .upsert(observation, onConflict: "user_id,source_app,content_hash")
                .execute()
            lastCaptureAt = observation.observedAt
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
    func recentContext(matching query: String, limit: Int = 4) async -> [ScreenObservation] {
        guard ScreenContextDefaults.isEnabled, let supabase else { return [] }
        let terms = Self.searchTerms(in: query)
        guard !terms.isEmpty else { return [] }

        do {
            let rows: [ScreenObservation] = try await supabase
                .from("screen_observations")
                .select()
                .gt("expires_at", value: Date())
                // `simple`, matching the GIN index: the default `english`
                // config stems away the Ukrainian half of what people ask, and
                // a query on another config would skip the index entirely.
                .textSearch("content", query: terms.joined(separator: " | "), config: "simple")
                .order("observed_at", ascending: false)
                .limit(limit * 4)
                .execute()
                .value
            let relevant = Array(Self.relevant(rows, for: terms).prefix(limit))
            Log.screen.info("context: \(relevant.count)/\(rows.count) observation(s) kept for \(terms.count) term(s)")
            return relevant
        } catch {
            Log.screen.error("context: lookup failed — \(error.localizedDescription)")
            return []
        }
    }

    /// Everything seen in a window, newest first, folded per app.
    ///
    /// The keyword path above cannot answer "what was I working on": none of
    /// the words in that question ("working", "recently") appear on the screen
    /// it is asking about, so the match is always empty. A recap is a time
    /// query, not a text query — the window is the whole filter.
    func activity(in window: DateInterval, limit: Int = 240) async -> ScreenActivityDigest {
        guard ScreenContextDefaults.isEnabled, let supabase else { return ScreenActivityDigest(apps: []) }
        do {
            let rows: [ScreenObservation] = try await supabase
                .from("screen_observations")
                .select()
                .gt("expires_at", value: Date())
                .gte("observed_at", value: window.start)
                .lte("observed_at", value: window.end)
                .order("observed_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            let digest = ScreenActivityDigest.build(from: rows)
            Log.screen.info("context: \(rows.count) observation(s) folded into \(digest.apps.count) app(s)")
            return digest
        } catch {
            Log.screen.error("context: activity lookup failed — \(error.localizedDescription)")
            return ScreenActivityDigest(apps: [])
        }
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
        TextTokens.words(in: query)
            .filter { $0.count >= 4 && !stopWords.contains($0) }
            .prefix(6)
            .map { $0 }
    }

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
        if let byte = (try? Data(contentsOf: enabledFileURL))?.first { return byte == 1 }
        // Migration: an install that only ever wrote the old UserDefaults key.
        return UserDefaults.standard.bool(forKey: enabledKey)
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
        try? FileManager.default.createDirectory(
            at: enabledFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data([enabled ? 1 : 0]).write(to: enabledFileURL, options: .atomic)
    }

    private static var enabledFileURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nod", isDirectory: true)
        return support.appendingPathComponent("ambient-context.enabled")
    }

    static var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: retentionDaysKey)
        return stored > 0 ? stored : defaultRetentionDays
    }

    static var retention: TimeInterval {
        TimeInterval(retentionDays) * 24 * 60 * 60
    }
}
