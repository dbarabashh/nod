import Foundation

/// "What happened last week?" is a question a calendar answers exactly and an
/// embedding can't answer at all — no one says "last week" inside the meeting
/// it refers to, so vector search has nothing to match on and the session
/// router is left guessing. This reads the time window out of the question up
/// front and hands retrieval a concrete set of sessions.
///
/// Pure and time-injectable so the table is unit-testable.
enum SessionTimeRange {
    /// Phrases are matched in the language the user asks in — the transcript's
    /// language is irrelevant here, and questions arrive in whatever the user
    /// speaks. English, Ukrainian and Russian for now; adding a language is a
    /// row in each table, not a code change.
    private static let todayPhrases = ["today", "сьогодні", "сегодня"]
    private static let yesterdayPhrases = ["yesterday", "вчора", "учора", "вчера"]
    private static let thisWeekPhrases = ["this week", "цього тижня", "цьому тижні", "на цьому тижні", "на этой неделе", "этой неделе"]
    private static let lastWeekPhrases = [
        "last week", "past week",
        "минулого тижня", "минулому тижні", "на минулому тижні", "минулий тиждень",
        "на прошлой неделе", "прошлой неделе", "прошлую неделю"
    ]
    private static let thisMonthPhrases = ["this month", "цього місяця", "цьому місяці", "в этом месяце", "этом месяце"]
    private static let lastMonthPhrases = [
        "last month", "past month",
        "минулого місяця", "минулому місяці", "минулий місяць",
        "в прошлом месяце", "прошлом месяце", "прошлый месяц"
    ]

    /// Phrases pointing at days that haven't happened yet. There are no
    /// sessions in the future, so these don't scope a search — they change what
    /// we search for: plans stated in recent sessions.
    private static let futurePhrases = [
        "next week", "next month", "tomorrow", "coming week", "upcoming", "going forward", "this coming",
        "наступного тижня", "наступний тиждень", "на наступному тижні", "наступного місяця", "завтра", "надалі",
        "на следующей неделе", "следующую неделю", "следующий месяц", "завтра"
    ]

    /// How far back to look for statements about what's coming. Plans are made
    /// in the days before they land, not months earlier.
    private static let planningLookbackDays = 21

    /// True when the question is about days that haven't happened yet.
    static func mentionsFuture(in question: String) -> Bool {
        let text = question.lowercased()
        return futurePhrases.contains { text.contains($0) }
    }

    /// Recent sessions, where plans for the coming days would have been said.
    static func planningLookback(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(byAdding: .day, value: -planningLookbackDays, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return DateInterval(start: start, end: now)
    }

    /// The window a question refers to, or nil when it isn't time-scoped.
    static func detect(in question: String, now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        let text = question
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var week = calendar
        week.firstWeekday = 2

        // Longest-first: "last week" must win over "week", and the month
        // phrases must not be shadowed by a bare weekday match.
        if contains(text, lastWeekPhrases) {
            return shifted(.weekOfYear, by: -1, from: now, calendar: week)
        }
        if contains(text, thisWeekPhrases) {
            return week.dateInterval(of: .weekOfYear, for: now)
        }
        if contains(text, lastMonthPhrases) {
            return shifted(.month, by: -1, from: now, calendar: calendar)
        }
        if contains(text, thisMonthPhrases) {
            return calendar.dateInterval(of: .month, for: now)
        }
        if contains(text, yesterdayPhrases) {
            return shifted(.day, by: -1, from: now, calendar: calendar)
        }
        if contains(text, todayPhrases) {
            return calendar.dateInterval(of: .day, for: now)
        }
        if let days = trailingDays(in: text) {
            guard let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) else {
                return nil
            }
            return DateInterval(start: start, end: now)
        }
        return nil
    }

    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }

    private static func shifted(_ unit: Calendar.Component, by value: Int, from now: Date, calendar: Calendar) -> DateInterval? {
        guard let shifted = calendar.date(byAdding: unit, value: value, to: now) else { return nil }
        return calendar.dateInterval(of: unit, for: shifted)
    }

    /// "in the last 3 days", "за останні 10 днів", "за последние 2 недели".
    private static let trailingPattern = try? NSRegularExpression(
        pattern: "(?:last|past|останні|останніх|последние|последних)\\s+(\\d+)\\s*(day|days|дн|дні|днів|дня|дней|week|weeks|тиж|тижні|тижнів|недел)"
    )

    private static func trailingDays(in text: String) -> Int? {
        guard let regex = trailingPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let countRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let count = Int(text[countRange])
        else { return nil }
        let unit = String(text[unitRange])
        let isWeeks = unit.hasPrefix("week") || unit.hasPrefix("тиж") || unit.hasPrefix("недел")
        return isWeeks ? count * 7 : count
    }
}
