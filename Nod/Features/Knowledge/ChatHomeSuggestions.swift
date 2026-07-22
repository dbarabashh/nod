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

    static func build(meetings: [Meeting], now: Date = Date(), titleLimit: Int = 40) -> [String] {
        let recent = meetings
            .filter { $0.deletedAt == nil && now.timeIntervalSince($0.startedAt) <= recentWindow }
            .sorted { $0.startedAt > $1.startedAt }

        var suggestions: [String] = []
        if recent.count >= 2 {
            suggestions.append("What did we decide this week?")
        }
        if let latest = recent.first, let title = latest.title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            suggestions.append("Catch me up on \(truncated(title, to: titleLimit))")
        }
        suggestions.append("What did I say I'd follow up on?")
        suggestions.append("What have I been thinking about lately?")

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
