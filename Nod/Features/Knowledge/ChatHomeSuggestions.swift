import Foundation

/// Openers for the empty chat, derived from what the user actually has.
///
/// Generic prompts ("ask me anything") teach nothing and get ignored. A
/// suggestion that names last week's meeting shows what the chat can reach, so
/// the list is built from real sessions and degrades to the generic pair only
/// when there is nothing to point at — a first run.
enum ChatHomeSuggestions {
    static let maximum = 4

    /// An opener: what the chip reads, and what actually gets asked.
    ///
    /// Two fields rather than one, because a long meeting title has to be cut to
    /// fit the chip — and the cut version used to be the question too. Tapping
    /// "Catch me up on Деплой LiveKit агента та усунення…" asked the model about
    /// a title ending in an ellipsis, so retrieval was matching against a name
    /// no session has.
    struct Opener: Identifiable, Equatable {
        let label: String
        let question: String
        /// The one to try first, drawn in the accent so it reads as a way in
        /// rather than one of four equal options.
        ///
        /// True for exactly one case: the sample session is the only thing this
        /// account has, and asking about it is the whole point of its being
        /// there. It stops being featured the moment a real session exists,
        /// because then there is something better to ask about.
        var isFeatured = false
        /// A session to open instead of a question to ask.
        ///
        /// Set only on the sample's opener. Somebody who has recorded nothing
        /// has nothing to be caught up *on* — the useful thing is to see what a
        /// session looks like, and an answer about a session they have not read
        /// is an answer with nothing behind it. The label says "Open" for the
        /// same reason: a chip that reads like a question and returns a screen
        /// has told the user the wrong thing about what it does.
        var opens: UUID?

        var id: String {
            question
        }

        init(_ text: String) {
            label = text
            question = text
        }

        init(label: String, question: String, isFeatured: Bool = false, opens: UUID? = nil) {
            self.label = label
            self.question = question
            self.isFeatured = isFeatured
            self.opens = opens
        }
    }

    /// A meeting counts as "recent" for a week; past that, "this week" would be
    /// a lie and the opener would return nothing.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The scoped projects read as prose — "Hiring", "Hiring and Pricing",
    /// "Hiring, Pricing and Roadmap". Nil when nothing is scoped.
    static func scopeName(_ projects: [String]) -> String? {
        TextList.prose(
            projects
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// What the chat is pointed at, spelled out above the openers. An empty
    /// composer reads as a generic chatbot; naming the reach ("all memory", or
    /// the folders the user scoped to) is what makes it read as *their* memory.
    static func scopeHeadline(projects: [String], titleLimit: Int = 40) -> String {
        guard let name = scopeName(projects) else { return "Ask across all memory" }
        return "Ask about \(truncated(name, to: titleLimit))"
    }

    /// The line under the greeting: what day it is, then what a question here
    /// reaches.
    ///
    /// The date belongs on this screen because it is the frame every answer
    /// resolves against — "what did I promise this week" and "anything left
    /// today" are questions about a day the person has to already have in mind,
    /// and the prompt knows it while the screen did not say it.
    static func homeSubtitle(projects: [String], now: Date = Date(), locale: Locale? = nil) -> String {
        "\(dayLine(now, locale: locale)) · \(scopeHeadline(projects: projects))"
    }

    /// Today, in the reader's own order: "Wednesday, August 19" where the month
    /// leads and "Wednesday, 19 August" where the day does. A fixed American
    /// order would be wrong for most of the people this ships to, and the year
    /// is left out because a header saying what day it is has no business
    /// telling you which one you are in.
    ///
    /// `locale` is nil in the app so the cached formatter is used — building a
    /// `DateFormatter` is expensive and this is read from a `body`. Tests pass
    /// one to pin an order that isn't the machine's.
    static func dayLine(_ now: Date = Date(), locale: Locale? = nil) -> String {
        guard let locale else { return dayFormatter.string(from: now) }
        return Self.dayFormatter(for: locale).string(from: now)
    }

    private static let dayFormatter = dayFormatter(for: .current)

    private static func dayFormatter(for locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }

    /// `firstRunPreview` defaults to off rather than to the debug switch: read
    /// from inside, a preference on the developer's machine changes what this
    /// pure function returns, and it did — seven tests started failing the
    /// moment the switch was flipped to look at the empty state. Production
    /// behaviour is the default; previewing is something a caller asks for.
    static func build(
        meetings: [Meeting],
        projects: [String] = [],
        now: Date = Date(),
        titleLimit: Int = 40,
        firstRunPreview: Bool = false,
        hasAmbientContext: Bool = false
    ) -> [Opener] {
        // What the person has actually recorded. The sample Nod seeds at signup
        // is a row in the list but not an answer to anything they said, so it
        // must not move an account out of its first run — it did, and the
        // openers that explain the product were replaced by memory questions
        // ("what did I promise?") that a brand-new account answers with "I
        // don't have anything on that yet".
        let recorded = meetings.live().filter { !$0.isWelcome }

        var suggestions: [Opener] = []
        if let full = scopeName(projects) {
            let short = truncated(full, to: titleLimit)
            suggestions = [
                naming("Catch me up on %@", short: short, full: full),
                naming("What did I promise in %@?", short: short, full: full),
                naming("What's still unresolved in %@?", short: short, full: full)
            ]
        } else if recorded.isEmpty || firstRunPreview {
            // Nothing recorded yet, so every opener that names a session has
            // nothing to name — and the generic ones are answered with "I
            // don't have anything on that yet", which is the worst possible
            // first impression of a memory product. Ask about the product
            // instead; `AboutNod` has the answers ready.
            //
            // The sample leads, when there is one: it is the only thing on this
            // screen that can be *read* rather than asked about, and reading it
            // answers most of what the questions below it would.
            let sample = meetings.live().first(where: \.isWelcome)
            suggestions = (sample.map { [opening($0, titleLimit: titleLimit)] } ?? [])
                + AboutNod.questions.map(Opener.init)
        } else {
            let recent = recorded.filter { now.timeIntervalSince($0.startedAt) <= recentWindow }

            if recent.count >= 2 {
                suggestions.append(Opener("What did we decide this week?"))
            }
            if let latest = recent.first, let title = latest.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                let full = title.trimmingCharacters(in: .whitespacesAndNewlines)
                suggestions.append(
                    naming("Catch me up on %@", short: truncated(full, to: titleLimit), full: full)
                )
            }
            suggestions.append(Opener("What did I promise?"))
            suggestions.append(Opener("What decisions are still unresolved?"))
        }

        if hasAmbientContext, scopeName(projects) == nil, !firstRunPreview {
            suggestions.insert(Opener(label: "Summarize my recent work", question: MemoryActivation.question), at: 0)
        }

        var seen = Set<String>()
        return suggestions.filter { seen.insert($0.question).inserted }.prefix(maximum).map { $0 }
    }

    /// The sample's own opener: a door, not a question.
    ///
    /// "Start here" rather than "Open" because the chip has to say what this is,
    /// and named anyway so the sentence points at something the session list
    /// shows under the same title.
    private static func opening(_ sample: Meeting, titleLimit: Int) -> Opener {
        let full = (sample.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let named = full.isEmpty ? "your sample session" : full
        return Opener(
            label: String(format: "Start here — %@", truncated(named, to: titleLimit)),
            question: String(format: "Start here — %@", named),
            isFeatured: true,
            opens: sample.id
        )
    }

    /// The empty state is the one screen nobody can see again once they have
    /// recorded anything, which is exactly why it goes unreviewed. Debug builds
    /// can force it:
    ///
    ///     defaults write com.example.nod chat.firstRunPreview -bool YES
    ///
    /// Release builds compile this to a constant false — a marketing surface
    /// that a preference can summon over real data is a bug waiting to be
    /// reported as one.
    static var isPreviewingFirstRun: Bool {
        #if DEBUG
            FirstRunPreview.isEnabled
        #else
            false
        #endif
    }

    #if DEBUG
        enum FirstRunPreview {
            static let defaultsKey = "chat.firstRunPreview"

            static var isEnabled: Bool {
                UserDefaults.standard.bool(forKey: defaultsKey)
                    || ProcessInfo.processInfo.environment["NOD_FIRST_RUN"] == "1"
            }
        }
    #endif

    /// One opener built from a template, cut for the chip and whole for the ask.
    private static func naming(_ template: String, short: String, full: String) -> Opener {
        Opener(
            label: template.replacingOccurrences(of: "%@", with: short),
            question: template.replacingOccurrences(of: "%@", with: full)
        )
    }

    /// A long meeting title would push the chip past the composer's width;
    /// cutting on a word keeps it readable.
    static func truncated(_ title: String, to limit: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let cut = trimmed.prefix(limit)
        guard let lastSpace = cut.lastIndex(of: " ") else { return String(cut) + "…" }
        return String(cut[cut.startIndex ..< lastSpace]) + "…"
    }

    /// "What's on your mind, Dima?" — first name only; a full name reads like a
    /// form letter. Falls back to the nameless form rather than an empty comma.
    static func greeting(for displayName: String?) -> String {
        guard let first = Profile.firstName(in: displayName) else {
            return "What's on your mind?"
        }
        return "What's on your mind, \(first)?"
    }
}
