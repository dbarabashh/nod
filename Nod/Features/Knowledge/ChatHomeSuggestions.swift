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

        var id: String {
            question
        }

        init(_ text: String) {
            label = text
            question = text
        }

        init(label: String, question: String) {
            self.label = label
            self.question = question
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

    static func build(
        meetings: [Meeting],
        projects: [String] = [],
        now: Date = Date(),
        titleLimit: Int = 40
    ) -> [Opener] {
        var suggestions: [Opener] = []
        if let full = scopeName(projects) {
            let short = truncated(full, to: titleLimit)
            suggestions = [
                naming("Catch me up on %@", short: short, full: full),
                naming("What did I promise in %@?", short: short, full: full),
                naming("What's still unresolved in %@?", short: short, full: full)
            ]
        } else {
            let recent = meetings
                .liveNewestFirst()
                .filter { now.timeIntervalSince($0.startedAt) <= recentWindow }

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

        var seen = Set<String>()
        return suggestions.filter { seen.insert($0.question).inserted }.prefix(maximum).map { $0 }
    }

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
