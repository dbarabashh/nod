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

    static func build(from observations: [ScreenObservation]) -> ScreenActivityDigest {
        var byApp: [String: [String: [ScreenObservation]]] = [:]
        for observation in observations {
            byApp[observation.sourceApp, default: [:]][windowKey(for: observation), default: []].append(observation)
        }

        var apps: [App] = []
        for (bundleID, groups) in byApp {
            var folded: [Window] = groups.values.compactMap(window(from:))
            guard !folded.isEmpty else { continue }
            folded.sort { $0.lastSeen > $1.lastSeen }
            let captures = groups.values.reduce(0) { $0 + $1.count }
            apps.append(App(
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

        return ScreenActivityDigest(apps: Array(apps.prefix(maximumApps)))
    }

    /// An untitled window is still a window — grouping every one of them
    /// together would merge unrelated screens, so they fall back to their
    /// content hash.
    private static func windowKey(for observation: ScreenObservation) -> String {
        let title = observation.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title.isEmpty ? observation.contentHash : title
    }

    /// The longest capture wins: the same window read twice differs by how much
    /// of it had loaded, and the fuller read is the one worth keeping.
    private static func window(from group: [ScreenObservation]) -> Window? {
        guard let fullest = group.max(by: { $0.content.count < $1.content.count }),
              let first = group.min(by: { $0.observedAt < $1.observedAt }),
              let last = group.max(by: { $0.observedAt < $1.observedAt })
        else { return nil }
        return Window(
            title: fullest.sourceTitle,
            content: String(fullest.content.prefix(maximumWindowCharacters)),
            firstSeen: first.observedAt,
            lastSeen: last.observedAt,
            captures: group.count
        )
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
        let words = Self.words(in: question)
        return phrases.contains { phrase in
            Self.words(in: phrase).allSatisfy { stem in
                words.contains { $0.hasPrefix(stem) }
            }
        }
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
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

extension ScreenActivityDigest.App {
    /// One prompt block per app, so the model can attribute a line to the app it
    /// came from instead of to "your screen" in general.
    func promptBlock(appName: String, formatter: DateFormatter) -> String {
        let span = windows.map(\.firstSeen).min().map(formatter.string(from:)) ?? ""
        let until = windows.map(\.lastSeen).max().map(formatter.string(from:)) ?? ""
        let header = span == until ? span : "\(span)–\(until)"
        let body = windows
            .map { window in
                let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = title.isEmpty ? "(untitled window)" : title
                return "• \(label) (\(formatter.string(from: window.lastSeen)))\n\(window.content)"
            }
            .joined(separator: "\n\n")
        return "[On your screen — \(appName), \(header)]\n\(body)"
    }
}
