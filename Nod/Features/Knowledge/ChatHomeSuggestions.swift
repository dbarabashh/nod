import Foundation

/// Openers for the empty chat, derived from what the user actually has.
///
/// Generic prompts ("ask me anything") teach nothing and get ignored. A
/// suggestion that names last week's meeting shows what the chat can reach, so
/// the list is built from real sessions and degrades to the generic pair only
/// when there is nothing to point at — a first run.
enum ChatHomeSuggestions {
    static let maximum = 4

    /// A meeting counts as "recent" for a week; past that, "this week" would be
    /// a lie and the opener would return nothing.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    /// What the chat is pointed at, spelled out above the openers. An empty
    /// composer reads as a generic chatbot; naming the reach ("all memory", or
    /// the folder the user scoped to) is what makes it read as *their* memory.
    static func scopeHeadline(project: String?, titleLimit: Int = 40) -> String {
        guard let project, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Ask across all memory"
        }
        return "Ask about \(truncated(project, to: titleLimit))"
    }

    static func build(
        meetings: [Meeting],
        project: String? = nil,
        now: Date = Date(),
        titleLimit: Int = 40
    ) -> [String] {
        var suggestions: [String] = []
        if let project, !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let name = truncated(project, to: titleLimit)
            suggestions = [
                "Catch me up on \(name)",
                "What did I promise in \(name)?",
                "What's still unresolved in \(name)?"
            ]
        } else {
            let recent = meetings
                .liveNewestFirst()
                .filter { now.timeIntervalSince($0.startedAt) <= recentWindow }

            if recent.count >= 2 {
                suggestions.append("What did we decide this week?")
            }
            if let latest = recent.first, let title = latest.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
                suggestions.append("Catch me up on \(truncated(title, to: titleLimit))")
            }
            suggestions.append("What did I promise?")
            suggestions.append("What decisions are still unresolved?")
        }

        var seen = Set<String>()
        return suggestions.filter { seen.insert($0).inserted }.prefix(maximum).map { $0 }
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
        let first = displayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) ?? ""
        return first.isEmpty ? "What's on your mind?" : "What's on your mind, \(first)?"
    }
}
