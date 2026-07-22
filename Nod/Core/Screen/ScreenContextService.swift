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
    /// Hashes stored this launch, so an unchanged screen isn't re-sent on every
    /// tick. The unique index is the real guarantee; this saves the round trip.
    private var recentHashes: Set<String> = []

    /// Sampling interval. Littlebird polls every two seconds; we deliberately
    /// don't. A tighter loop mostly re-reads an unchanged window, and every
    /// read is another window's text held in memory.
    private static let interval: TimeInterval = 15

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
        recentHashes.removeAll()
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
        let captured = await Task.detached(priority: .utility) { () -> (title: String, text: String)? in
            var title = ""
            let parts = reader.texts(forProcessID: pid) { windowTitle in
                guard !rules.excludesWindow(title: windowTitle) else { return false }
                title = windowTitle
                return true
            }
            guard let text = ScreenObservationBuilder.text(from: parts) else { return nil }
            return (title, text)
        }.value

        guard let captured else { return }
        let observation = ScreenObservation(
            userID: userID,
            sourceApp: bundleID,
            sourceTitle: captured.title,
            content: captured.text,
            retention: ScreenContextDefaults.retention
        )
        guard recentHashes.insert(observation.contentHash).inserted else { return }

        do {
            try await supabase
                .from("screen_observations")
                .upsert(observation, onConflict: "user_id,source_app,content_hash")
                .execute()
            lastCaptureAt = observation.observedAt
            Log.screen.info(
                "context: stored \(observation.content.count) chars from \(bundleID) — \(captured.title)"
            )
        } catch {
            recentHashes.remove(observation.contentHash)
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
                .textSearch("content", query: terms.joined(separator: " | "))
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

    /// Postgres matches any term (`|`), which is what gives useful recall — but
    /// a single common word then drags in a window that has nothing to do with
    /// the question. Keep only what matches more than one term, unless the
    /// question had just one to begin with.
    static func relevant(_ observations: [ScreenObservation], for terms: [String]) -> [ScreenObservation] {
        let required = terms.count > 1 ? 2 : 1
        return observations.filter { observation in
            let content = observation.content.lowercased()
            return terms.count(where: { content.contains($0) }) >= required
        }
    }

    /// Words worth matching on. Short and very common words are dropped: they
    /// match everything, which is the same as matching nothing.
    static func searchTerms(in query: String) -> [String] {
        query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
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
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var retentionDays: Int {
        let stored = UserDefaults.standard.integer(forKey: retentionDaysKey)
        return stored > 0 ? stored : defaultRetentionDays
    }

    static var retention: TimeInterval {
        TimeInterval(retentionDays) * 24 * 60 * 60
    }
}
