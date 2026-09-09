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
        var url: String?
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

    /// Apps beyond this are a long tail of glances — a Finder window, a
    /// notification — and each one costs prompt room a real one could use.
    static let maximumApps = 6
    /// Eight, not four. A day's browsing is one app: at four windows the
    /// afternoon's reading collapsed into whichever tabs were open longest,
    /// and a recap that named two of eight sites read as inattentive.
    static let maximumWindowsPerApp = 8
    /// Per window, not per app. At 700 this was the binding constraint on how
    /// specific a recap could be: capture stores up to
    /// `ScreenObservation.maximumCharacters`, and the digest was throwing away
    /// most of it — a Slack channel arrived without its ticket numbers, a
    /// LinkedIn page without its figures, a video without its title.
    static let maximumWindowCharacters = 1_400

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
            var folded = groups.values.flatMap { visits(in: $0) }.compactMap(plannedWindow(from:))
            guard !folded.isEmpty else { continue }
            // By how long the window was up, exactly as apps are ranked below —
            // the two used to disagree, and that disagreement is what made a
            // recap of a period unstable. Ranked by `lastSeen`, a window opened
            // a minute ago outranked one that filled the morning, so four idle
            // glances evicted the day's actual work and the same question
            // answered twice, seconds apart, described two different days.
            // Captures are five seconds each, so the count is dwell time.
            folded.sort { left, right in
                left.captures == right.captures
                    ? left.lastSeen > right.lastSeen
                    : left.captures > right.captures
            }
            let captures = groups.values.reduce(0) { $0 + $1.count }
            apps.append(ScreenActivityPlan.App(
                bundleID: bundleID,
                windows: covering(folded, limit: maximumWindowsPerApp),
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

    /// Keyword matches the recap has no room for. A recap ranks windows by how
    /// long they were up, so a page glanced at for ten seconds loses its seat to
    /// the morning's work — and that page is exactly what a question naming it
    /// is about. Anything already in the recap is dropped so nothing is said
    /// twice.
    static func uncovered(_ matches: [ScreenObservation], by digest: ScreenActivityDigest) -> [ScreenObservation] {
        let shown = Set(digest.apps.flatMap { app in
            app.windows.map { windowKey(app.bundleID, $0.title) }
        })
        var seen = Set<String>()
        return matches.filter { observation in
            let key = windowKey(observation.sourceApp, observation.sourceTitle)
            return !shown.contains(key) && seen.insert(key).inserted
        }
    }

    private static func windowKey(_ bundleID: String, _ title: String) -> String {
        bundleID + "\u{1F}" + title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Puts the text back on a plan. A window whose body never arrived — expired
    /// between the two queries, or dropped by the row cap — is left out rather
    /// than reported as an empty screen.
    static func build(plan: ScreenActivityPlan, bodies: [String: String]) -> ScreenActivityDigest {
        let apps: [App] = plan.apps.compactMap { app in
            // Each app gets the same allowance. A day in a browser would
            // otherwise fill the whole screen section on its own and push the
            // Slack channel and the editor out of the answer entirely — and
            // breadth is what a recap of a day is for.
            var used = 0
            var windows: [Window] = []
            for window in app.windows {
                guard let fullest = fullestBody(among: window.candidateHashes, in: bodies) else { continue }
                // Past the allowance a window is kept at a glance rather than
                // dropped. Spending the budget used to delete the rest of the
                // app outright — a browser picked eight tabs for coverage and
                // five of them vanished, title and all — and a tab's title is
                // most of what it was: "Dimension — shutting down 20 May",
                // "console1984 by Basecamp". Depth for the first few, presence
                // for the rest, which is the shape a day actually has.
                let limit = used < appBudget ? maximumWindowCharacters : glimpseCharacters
                let content = String(fullest.prefix(limit))
                used += content.count
                windows.append(Window(
                    title: window.title,
                    content: content,
                    firstSeen: window.firstSeen,
                    lastSeen: window.lastSeen,
                    captures: window.captures,
                    url: window.url
                ))
            }
            guard !windows.isEmpty else { return nil }
            return App(bundleID: app.bundleID, windows: windows, captures: app.captures)
        }
        return ScreenActivityDigest(apps: apps)
    }

    /// One app's share of full-depth windows — about two and a half of them.
    /// The first is always admitted, however long, so an app is never present
    /// as a name with nothing under it.
    static let appBudget = 3_500

    /// What a window past the allowance still gets. Enough for a tab to say
    /// what it was, which is often the whole point of it.
    static let glimpseCharacters = 220

    /// The windows worth keeping for a *period*: the day's hours, each
    /// represented, and the longest-held window inside each of them.
    ///
    /// Dwell alone answers "what am I doing", not "what was my day". Ranked by
    /// time on screen, an afternoon of one long document buries every twenty
    /// second thing the day was actually about — the pricing page, the
    /// competitor's shutdown notice, the thread somebody linked — which is
    /// exactly the detail that makes a recap read as observant rather than
    /// vague. So each hour present gets its best window first, and only then
    /// is the remaining room filled by dwell.
    ///
    /// `folded` arrives already ranked by dwell, and the result keeps that
    /// order: coverage decides who is included, not who is listed first.
    static func covering(_ folded: [ScreenActivityPlan.Window], limit: Int) -> [ScreenActivityPlan.Window] {
        guard folded.count > limit else { return folded }
        let calendar = Calendar.current
        var seenHours = Set<Date>()
        var chosen = Set<Int>()
        for (index, window) in folded.enumerated() {
            let hour = calendar.dateInterval(of: .hour, for: window.lastSeen)?.start ?? window.lastSeen
            guard seenHours.insert(hour).inserted, chosen.count < limit else { continue }
            chosen.insert(index)
        }
        for index in folded.indices where chosen.count < limit {
            chosen.insert(index)
        }
        return folded.indices.filter { chosen.contains($0) }.map { folded[$0] }
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

    /// One window's captures split into the separate times you were in it.
    ///
    /// Folding on the title alone made a whole day in one app a single window.
    /// Slack's title is `Nod, ops - Slack` from morning to night, so every
    /// capture of it collapsed into one row and `fullestBody` kept one snapshot
    /// of one moment — which is why a recap could say "you were in Slack" and
    /// never which tickets were discussed. The same held for LinkedIn and for a
    /// long ChatGPT conversation.
    ///
    /// Split on the gap rather than on the clock. A fixed two-hour bucket cuts
    /// a window that was up from 13:55 to 14:05 into two visits at a boundary
    /// that means nothing, while a window you left and came back to after lunch
    /// is genuinely a second look — and only the gap can tell those apart.
    static func visits(in group: [ScreenObservationIndex]) -> [[ScreenObservationIndex]] {
        let ordered = group.sorted { $0.observedAt < $1.observedAt }
        var runs: [[ScreenObservationIndex]] = []
        for entry in ordered {
            if let last = runs.last?.last, entry.observedAt.timeIntervalSince(last.observedAt) <= revisitGap {
                runs[runs.count - 1].append(entry)
            } else {
                runs.append([entry])
            }
        }
        return runs
    }

    /// Long enough that stepping away for coffee does not split an afternoon
    /// in one document, short enough that coming back after lunch is a second
    /// visit with its own contents.
    static let revisitGap: TimeInterval = 45 * 60

    /// `visit` arrives sorted oldest-first, from `visits(in:)`. Its ends are
    /// therefore its first and last, and newest-first is just the reverse —
    /// re-deriving both cost a sort and two scans on data that had just been
    /// ordered one call up the stack, once per visit rather than once per
    /// window group.
    private static func plannedWindow(from visit: [ScreenObservationIndex]) -> ScreenActivityPlan.Window? {
        guard let first = visit.first, let last = visit.last else { return nil }
        var seen = Set<String>()
        let candidates = visit
            .reversed()
            .filter { seen.insert($0.contentHash).inserted }
            .prefix(maximumCandidatesPerWindow)
            .map(\.contentHash)
        return ScreenActivityPlan.Window(
            title: last.sourceTitle,
            firstSeen: first.observedAt,
            lastSeen: last.observedAt,
            captures: visit.count,
            candidateHashes: candidates,
            url: visit.last { $0.sourceURL != nil }?.sourceURL
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
        var url: String?
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
    /// The two fixed parts of a block header, named because the prompt rules
    /// quote them back at the model and a test holds the two in step.
    ///
    /// "captured" is load-bearing: the stamp is when the screenshot was taken,
    /// and without the word the model read it as the time of whatever message
    /// the window happened to be showing.
    static let opening = "[On your screen — "
    static let captureMarker = ", captured "

    static func header(source: String, when: String) -> String {
        "\(opening)\(source)\(captureMarker)\(when)]"
    }

    static func single(source: String, when: String, content: String) -> String {
        "\(header(source: source, when: when))\n\(content)"
    }
}

extension ScreenActivityDigest.App {
    /// One prompt block per app, so the model can attribute a line to the app it
    /// came from instead of to "your screen" in general.
    func promptBlock(appName: String, now: Date = Date()) -> String {
        let body = windows
            .map { window in
                let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = title.isEmpty ? "(untitled window)" : title
                let link = window.url.map { "\nLink: \($0)" } ?? ""
                return "• \(label) (\(PromptLibrary.observationStamp(window.lastSeen, now: now)))\(link)\n\(window.content)"
            }
            .joined(separator: "\n\n")
        let when = if let first = windows.map(\.firstSeen).min(), let last = windows.map(\.lastSeen).max() {
            PromptLibrary.observationSpan(from: first, to: last, now: now)
        } else {
            ""
        }
        return ScreenPromptBlock.single(source: appName, when: when, content: body)
    }
}
