import Foundation

/// A stretch of screen captures folded into something a prompt can hold.
///
/// Polling every five seconds means a morning is hundreds of rows, most of them
/// the same window seen again. Feeding those in raw would blow the context and
/// bury the few windows that carry the day's actual work, so they're folded:
/// grouped by app, then by window, keeping the fullest capture of each and the
/// span it was on screen.
struct ScreenActivityDigest: Equatable {
    struct Window: Equatable {
        let title: String
        let content: String
        let firstSeen: Date
        let lastSeen: Date
        let captures: Int
    }

    struct App: Equatable, Identifiable {
        let bundleID: String
        let windows: [Window]
        let captures: Int

        var id: String {
            bundleID
        }
    }

    let apps: [App]

    var isEmpty: Bool {
        apps.isEmpty
    }

    /// Apps beyond this are a long tail of glances — a Finder window, a
    /// notification — and each one costs prompt room a real one could use.
    static let maximumApps = 6
    static let maximumWindowsPerApp = 4
    /// Per window, not per app: enough for a Jira ticket's body or a Slack
    /// thread, short of a whole document.
    static let maximumWindowCharacters = 700

    /// How many of a window's screen states are worth fetching text for.
    ///
    /// The fullest of them becomes the window's line, and which one that is
    /// can't be known from the index — length lives in the body. Six covers a
    /// window that loaded progressively; beyond that they are the same screen
    /// scrolled, and each one costs a row in the hydrate query.
    static let maximumCandidatesPerWindow = 6

    /// Folds an index into the shape of a digest, without any text: which apps
    /// and windows made the cut, and which screen states to read them from.
    static func plan(from index: [ScreenObservationIndex]) -> ScreenActivityPlan {
        var byApp: [String: [String: [ScreenObservationIndex]]] = [:]
        for entry in index {
            byApp[entry.sourceApp, default: [:]][windowKey(for: entry), default: []].append(entry)
        }

        var apps: [ScreenActivityPlan.App] = []
        for (bundleID, groups) in byApp {
            var folded = groups.values.compactMap(plannedWindow(from:))
            guard !folded.isEmpty else { continue }
            folded.sort { $0.lastSeen > $1.lastSeen }
            let captures = groups.values.reduce(0) { $0 + $1.count }
            apps.append(ScreenActivityPlan.App(
                bundleID: bundleID,
                windows: Array(folded.prefix(maximumWindowsPerApp)),
                captures: captures
            ))
        }
        apps.sort { left, right in
            left.captures == right.captures
                ? left.bundleID < right.bundleID
                : left.captures > right.captures
        }

        return ScreenActivityPlan(apps: Array(apps.prefix(maximumApps)))
    }

    /// Puts the text back on a plan. A window whose body never arrived — expired
    /// between the two queries, or dropped by the row cap — is left out rather
    /// than reported as an empty screen.
    static func build(plan: ScreenActivityPlan, bodies: [String: String]) -> ScreenActivityDigest {
        let apps: [App] = plan.apps.compactMap { app in
            let windows: [Window] = app.windows.compactMap { window in
                guard let fullest = fullestBody(among: window.candidateHashes, in: bodies) else { return nil }
                return Window(
                    title: window.title,
                    content: String(fullest.prefix(maximumWindowCharacters)),
                    firstSeen: window.firstSeen,
                    lastSeen: window.lastSeen,
                    captures: window.captures
                )
            }
            guard !windows.isEmpty else { return nil }
            return App(bundleID: app.bundleID, windows: windows, captures: app.captures)
        }
        return ScreenActivityDigest(apps: apps)
    }

    /// The longest capture wins: the same window read twice differs by how much
    /// of it had loaded, and the fuller read is the one worth keeping.
    private static func fullestBody(among hashes: [String], in bodies: [String: String]) -> String? {
        hashes.compactMap { bodies[$0] }.max { $0.count < $1.count }
    }

    /// An untitled window is still a window — grouping every one of them
    /// together would merge unrelated screens, so they fall back to their
    /// content hash.
    private static func windowKey(for entry: ScreenObservationIndex) -> String {
        let title = entry.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.isEmpty ? entry.contentHash : title
    }

    private static func plannedWindow(from group: [ScreenObservationIndex]) -> ScreenActivityPlan.Window? {
        guard let first = group.min(by: { $0.observedAt < $1.observedAt }),
              let last = group.max(by: { $0.observedAt < $1.observedAt })
        else { return nil }
        var seen = Set<String>()
        let candidates = group
            .sorted { $0.observedAt > $1.observedAt }
            .filter { seen.insert($0.contentHash).inserted }
            .prefix(maximumCandidatesPerWindow)
            .map(\.contentHash)
        return ScreenActivityPlan.Window(
            title: last.sourceTitle,
            firstSeen: first.observedAt,
            lastSeen: last.observedAt,
            captures: group.count,
            candidateHashes: candidates
        )
    }
}

/// A digest decided but not yet read: the apps and windows worth showing, and
/// the screen states whose text would fill them in.
struct ScreenActivityPlan: Equatable {
    struct Window: Equatable {
        let title: String
        let firstSeen: Date
        let lastSeen: Date
        let captures: Int
        /// Newest first, capped — the fullest of these becomes the window's text.
        let candidateHashes: [String]
    }

    struct App: Equatable {
        let bundleID: String
        let windows: [Window]
        let captures: Int
    }

    let apps: [App]

    /// Every screen state the digest needs the text of, deduplicated: the same
    /// content can front two windows.
    var hashesToRead: [String] {
        var seen = Set<String>()
        return apps
            .flatMap { $0.windows.flatMap(\.candidateHashes) }
            .filter { seen.insert($0).inserted }
    }
}

/// "What was I working on?" — a question about the user's own recent screen,
/// which no keyword search can serve.
enum ScreenRecall {
    /// How far back "recently" reaches when the question names no period. A
    /// full day: the answer is usually asked in the evening about the morning,
    /// or in the morning about yesterday.
    static let defaultLookback: TimeInterval = 24 * 60 * 60

    /// The window to recap, or nil when the question isn't asking for one.
    static func window(for question: String, now: Date = Date()) -> DateInterval? {
        guard asksForRecap(question) else { return nil }
        if let named = SessionTimeRange.detect(in: question, now: now) {
            return DateInterval(start: named.start, end: min(named.end, now))
        }
        return defaultWindow(now: now)
    }

    /// The window to use when something other than the phrase list decided the
    /// question is about the user's own recent activity.
    static func defaultWindow(now: Date = Date()) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-defaultLookback), end: now)
    }

    /// A phrase matches when every one of its words opens a word in the
    /// question, in any order and at any distance.
    ///
    /// Substring matching missed the way people actually type: "які останні
    /// новини" doesn't contain "які новини", and "what did I end up doing"
    /// doesn't contain "what did I do". Matching on word prefixes rather than
    /// whole words keeps the Ukrainian entries working — "працю" has to reach
    /// "працював", "працюю" and "працювала", which is why those entries are
    /// written as stems.
    static func asksForRecap(_ question: String) -> Bool {
        let words = TextTokens.words(in: question)
        return phrases.contains { phrase in
            TextTokens.words(in: phrase).allSatisfy { stem in
                words.contains { $0.hasPrefix(stem) }
            }
        }
    }

    /// Deliberately phrase-matched rather than routed by the model: this runs
    /// on every question, and a router round-trip to recognise "what was I
    /// doing" would cost a second of latency on all of them.
    ///
    /// Broad on purpose. Screen context is *added* to the session excerpts,
    /// never swapped in — so a phrase that fires on a question about meetings
    /// costs prompt room, while a missed one costs the answer. "Any recent
    /// updates?" retrieved nothing from the screen until this list grew.
    private static let phrases = ownWork + catchingUp

    private static let ownWork = [
        "what have i been",
        "what i have been",
        "what i've been",
        "what was i working",
        "what am i working",
        "what was i doing",
        "what am i doing",
        "what i was doing",
        "what did i do",
        "what have i done",
        "what was i just",
        "been up to",
        "was i up to",
        "recap of my day",
        "recap my day",
        "summarize my day",
        "summarise my day",
        "my day",
        "on my screen",
        "що я робив",
        "що я робила",
        "що я дивив",
        "чим я займав",
        "чим я займаю",
        "над чим я працю",
        "що я сьогодні",
        "мій день",
        "на екрані"
    ]

    private static let catchingUp = [
        "any updates",
        "recent updates",
        "any news",
        "what's new",
        "whats new",
        "anything new",
        "what did i miss",
        "what have i missed",
        "what's been happening",
        "whats been happening",
        "where did i leave off",
        "where i left off",
        "catch me up",
        "bring me up to speed",
        "що нового",
        "які новини",
        "що я пропустив",
        "де я зупинив",
        "введи мене в курс"
    ]
}

/// The one shape screen context takes in a prompt.
///
/// Both retrieval paths — the per-app recap and the keyword match — produce a
/// block the model is told to attribute by app and never to quote back. That
/// instruction names this header, this time range and this bullet layout, so
/// they are written once: a second definition means the instruction quietly
/// describes a format that no longer exists, and the plumbing leaks into the
/// answer, which is the exact failure the rule was written to prevent.
enum ScreenPromptBlock {
    static func header(source: String, when: String) -> String {
        "[On your screen — \(source), \(when)]"
    }

    static func single(source: String, when: String, content: String) -> String {
        "\(header(source: source, when: when))\n\(content)"
    }
}

extension ScreenActivityDigest.App {
    /// One prompt block per app, so the model can attribute a line to the app it
    /// came from instead of to "your screen" in general.
    func promptBlock(appName: String, formatter: DateFormatter) -> String {
        let span = windows.map(\.firstSeen).min().map(formatter.string(from:)) ?? ""
        let until = windows.map(\.lastSeen).max().map(formatter.string(from:)) ?? ""
        let body = windows
            .map { window in
                let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = title.isEmpty ? "(untitled window)" : title
                return "• \(label) (\(formatter.string(from: window.lastSeen)))\n\(window.content)"
            }
            .joined(separator: "\n\n")
        return ScreenPromptBlock.single(
            source: appName,
            when: span == until ? span : "\(span)–\(until)",
            content: body
        )
    }
}
