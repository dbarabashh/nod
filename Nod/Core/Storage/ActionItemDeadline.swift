import Foundation

/// Deadlines are extracted as the phrase actually spoken ("end of week", "next
/// Tuesday") — meaningful only relative to the day of that meeting. Rendering
/// the phrase verbatim forever makes a task from three weeks ago still read as
/// if it were due this Friday. This anchors the phrase to the meeting date and
/// says what's true *now*: overdue, due today, or a concrete date.
///
/// Pure and time-injectable so the whole table is unit-testable.
enum ActionItemDeadline {
    enum Urgency: Equatable {
        /// The deadline has passed.
        case overdue
        /// Today or tomorrow.
        case imminent
        case upcoming
        /// A phrase we couldn't pin to a day, or a fuzzy one ("next few weeks")
        /// whose window has already run out — shown without urgency colouring
        /// because we can't honestly claim it's late.
        case vague
    }

    struct Display: Equatable {
        let text: String
        let urgency: Urgency
        /// Tooltip headline: the phrase turned into an actual date, which the
        /// relative pill ("Overdue by 2 weeks") deliberately doesn't show.
        let headline: String
        /// Tooltip subline: the wording as it was spoken, so the rewritten pill
        /// never hides what the meeting actually stated. Callers append where
        /// and when it was said.
        let quote: String
    }

    struct Resolution: Equatable {
        let date: Date
        /// True for windows rather than dates ("next few weeks") — close enough
        /// to sort by, never precise enough to call something a day late.
        let isApproximate: Bool
    }

    /// Meetings older than this make an unresolvable phrase suspect: "end of
    /// week" said yesterday still means something, said last month it doesn't.
    private static let staleAfterDays = 7

    static func display(
        phrase: String,
        spokenAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Display {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = calendar.startOfDay(for: now)
        let saidDays = days(from: calendar.startOfDay(for: spokenAt), to: today, calendar: calendar)
        let resolved = resolve(phrase: phrase, spokenAt: spokenAt, calendar: calendar)
        let due = resolved.map { calendar.startOfDay(for: $0.date) }
        let remaining = due.map { days(from: today, to: $0, calendar: calendar) }
        /// What the phrase said, kept intact when the pill can't improve on it.
        let asSpoken = "\(phrase) · said \(agoLabel(saidDays, date: spokenAt))"

        let pill: (text: String, urgency: Urgency) =
            switch (resolved?.isApproximate, remaining) {
            case (nil, _):
                saidDays > staleAfterDays ? (asSpoken, .vague) : (phrase, .upcoming)
            case (true, let remaining?) where remaining < 0:
                (asSpoken, .vague)
            case (true, _):
                (phrase, .upcoming)
            case (false, let remaining?) where remaining < 0:
                (overdueLabel(-remaining, due: due ?? today), .overdue)
            case (false, let remaining?):
                (
                    dueLabel(remaining, due: due ?? today, crossesYear: crossesYear(due ?? today, today, calendar)),
                    remaining <= 1 ? .imminent : .upcoming
                )
            default:
                (phrase, .upcoming)
            }

        return Display(
            text: pill.text,
            urgency: pill.urgency,
            headline: headlineLabel(due: due, remaining: remaining, isApproximate: resolved?.isApproximate),
            quote: "Said “\(phrase)”"
        )
    }

    // MARK: - Resolution

    static func resolve(phrase: String, spokenAt: Date, calendar: Calendar = .current) -> Resolution? {
        let text = normalize(phrase)
        guard !text.isEmpty else { return nil }
        let day = calendar.startOfDay(for: spokenAt)

        func exact(_ date: Date?) -> Resolution? {
            date.map { Resolution(date: $0, isApproximate: false) }
        }
        func fuzzy(_ date: Date?) -> Resolution? {
            date.map { Resolution(date: $0, isApproximate: true) }
        }
        func shift(_ value: Int, _ unit: Calendar.Component) -> Date? {
            calendar.date(byAdding: unit, value: value, to: day)
        }

        if text.contains("asap") || text.contains("immediately") || text.contains("right away") {
            return exact(day)
        }
        if text.contains("day after tomorrow") { return exact(shift(2, .day)) }
        if text.contains("tomorrow") { return exact(shift(1, .day)) }
        if text.contains("today") || text.contains("tonight") || text.contains("end of day") || text.contains("eod") {
            return exact(day)
        }
        if let (value, unit) = numericOffset(in: text) {
            return exact(calendar.date(byAdding: unit, value: value, to: day))
        }
        if let weeks = fuzzyWeeks(in: text) {
            return fuzzy(shift(weeks * 7, .day))
        }
        if text.contains("couple of days") || text.contains("few days") {
            return fuzzy(shift(3, .day))
        }
        if text.contains("end of month") || text.contains("end of the month") || text.contains("this month") {
            return exact(endOfMonth(containing: day, calendar: calendar))
        }
        if text.contains("next month") {
            return exact(shift(1, .month).flatMap { endOfMonth(containing: $0, calendar: calendar) })
        }
        if let weekday = weekday(in: text) {
            return exact(nextOccurrence(of: weekday, after: day, wantsFollowingWeek: text.contains("next"), calendar: calendar))
        }
        if text.contains("next week") {
            if text.contains("early") { return exact(startOfWeek(day, weeksAhead: 1, calendar: calendar)) }
            return exact(endOfWeek(day, weeksAhead: 1, calendar: calendar))
        }
        if text.contains("end of week") || text.contains("end of the week") || text.contains("this week")
            || text.contains("eow") {
            return exact(endOfWeek(day, weeksAhead: 0, calendar: calendar))
        }
        if let date = explicitDate(in: text, notBefore: day, calendar: calendar) {
            return exact(date)
        }
        return nil
    }

    // MARK: - Phrase parsing

    private static func normalize(_ phrase: String) -> String {
        phrase
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compiled once: `NSRegularExpression` construction costs far more than the
    /// match, and `resolve` runs per row on every list render.
    private static let numericPatterns: [(regex: NSRegularExpression, unit: Calendar.Component)] = {
        let units: [(String, Calendar.Component)] = [
            ("day", .day), ("week", .weekOfYear), ("month", .month)
        ]
        return units.compactMap { name, unit in
            let pattern = "(?:in|within|next)\\s+(\\d+|a|an|one|two|three)\\s+\(name)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, unit)
        }
    }()

    private static let numberWords = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3]

    /// "in 3 days", "within 2 weeks", "in a month".
    private static func numericOffset(in text: String) -> (Int, Calendar.Component)? {
        for (regex, unit) in numericPatterns {
            guard let word = firstMatch(regex, in: text),
                  let value = Int(word) ?? numberWords[word]
            else { continue }
            return (value, unit)
        }
        return nil
    }

    /// "next few weeks", "a couple of weeks" — a window, not a date.
    private static func fuzzyWeeks(in text: String) -> Int? {
        guard text.contains("week") else { return nil }
        if text.contains("few") { return 3 }
        if text.contains("couple") { return 2 }
        return nil
    }

    private static func weekday(in text: String) -> Int? {
        let names = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7
        ]
        for (name, index) in names where text.contains(name) {
            return index
        }
        return nil
    }

    private static let dayFirstFormats = ["MMMM d", "MMM d", "d MMMM", "d MMM", "MM/dd"]

    private static func explicitDate(in text: String, notBefore: Date, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // Strip lead-ins so "by july 25" still matches a bare "MMMM d".
        let stripped = text
            .replacingOccurrences(of: "by ", with: "")
            .replacingOccurrences(of: "before ", with: "")
            .replacingOccurrences(of: "no later than ", with: "")
            .replacingOccurrences(of: "on ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        formatter.dateFormat = "yyyy/MM/dd"
        if let absolute = formatter.date(from: stripped) { return absolute }

        // The rest name a month and day only, so they resolve against the year
        // the phrase was spoken in — rolling forward when that date has passed.
        let anchorYear = calendar.component(.year, from: notBefore)
        for format in dayFirstFormats {
            formatter.dateFormat = "\(format) yyyy"
            guard let parsed = formatter.date(from: "\(stripped) \(anchorYear)") else { continue }
            guard parsed < notBefore else { return parsed }
            return calendar.date(byAdding: .year, value: 1, to: parsed)
        }
        return nil
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[group])
    }

    // MARK: - Calendar helpers

    /// Friday of the target week — the working sense of "end of week". A phrase
    /// said on the weekend still means that same weekend, not the Friday past.
    private static func endOfWeek(_ day: Date, weeksAhead: Int, calendar: Calendar) -> Date? {
        guard let start = startOfWeek(day, weeksAhead: weeksAhead, calendar: calendar),
              let friday = calendar.date(byAdding: .day, value: 4, to: start)
        else { return nil }
        return weeksAhead == 0 ? max(friday, day) : friday
    }

    private static func startOfWeek(_ day: Date, weeksAhead: Int, calendar: Calendar) -> Date? {
        var monday = calendar
        monday.firstWeekday = 2
        guard let interval = monday.dateInterval(of: .weekOfYear, for: day) else { return nil }
        return calendar.date(byAdding: .weekOfYear, value: weeksAhead, to: interval.start)
    }

    private static func nextOccurrence(
        of weekday: Int,
        after day: Date,
        wantsFollowingWeek: Bool,
        calendar: Calendar
    ) -> Date? {
        let current = calendar.component(.weekday, from: day)
        var delta = (weekday - current + 7) % 7
        if delta == 0 { delta = 7 }
        guard let base = calendar.date(byAdding: .day, value: delta, to: day) else { return nil }
        guard wantsFollowingWeek,
              let thisWeek = startOfWeek(day, weeksAhead: 0, calendar: calendar),
              let baseWeek = startOfWeek(base, weeksAhead: 0, calendar: calendar),
              thisWeek == baseWeek
        else { return base }
        // "next Tuesday" said on Monday means the Tuesday of the week after, not
        // tomorrow — but said on Friday it already lands in the next week.
        return calendar.date(byAdding: .day, value: 7, to: base)
    }

    private static func endOfMonth(containing day: Date, calendar: Calendar) -> Date? {
        guard let interval = calendar.dateInterval(of: .month, for: day) else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: interval.end)
    }

    private static func days(from: Date, to: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    // MARK: - Labels

    /// Always called with at least one whole day past due.
    private static func overdueLabel(_ days: Int, due: Date) -> String {
        switch days {
        case ..<2: "Overdue by 1 day"
        case 2 ..< 14: "Overdue by \(days) days"
        case 14 ..< 60: "Overdue by \(days / 7) weeks"
        default: "Overdue since \(shortDate(due))"
        }
    }

    private static func dueLabel(_ days: Int, due: Date, crossesYear: Bool) -> String {
        switch days {
        case 0: "Due today"
        case 1: "Due tomorrow"
        case 2 ..< 7: "Due \(weekdayName(due))"
        default: "Due \(shortDate(due, includeYear: crossesYear))"
        }
    }

    /// Only ever reached once a phrase has gone stale — a week for one we
    /// couldn't read, longer for a fuzzy window that has run out.
    private static func agoLabel(_ days: Int, date: Date) -> String {
        switch days {
        case ..<14: "last week"
        case 14 ..< 60: "\(days / 7) weeks ago"
        default: shortDate(date)
        }
    }

    /// The real date behind the pill's relative wording. An approximate phrase
    /// says "around" rather than naming a day it never actually committed to.
    private static func headlineLabel(due: Date?, remaining: Int?, isApproximate: Bool?) -> String {
        guard let due, let remaining, let isApproximate else { return "No date to read from this one" }
        let day = "\(weekdayName(due)), \(shortDate(due))"
        if isApproximate { return "Around \(day)" }
        return remaining < 0 ? "Was due \(day)" : "Due \(day)"
    }

    private static func crossesYear(_ due: Date, _ now: Date, _ calendar: Calendar) -> Bool {
        calendar.component(.year, from: due) != calendar.component(.year, from: now)
    }

    /// The deadline for a document that outlives the app session — an exported
    /// file is read weeks later, so a relative label ("Overdue by 2 weeks")
    /// would be a lie by then. Absolute ISO date, or the phrase anchored to the
    /// day it was said when no date can be read out of it.
    static func exportLabel(phrase: String, spokenAt: Date, calendar: Calendar = .current) -> String {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resolved = resolve(phrase: phrase, spokenAt: spokenAt, calendar: calendar) else {
            return "“\(phrase)”, said \(isoDate(spokenAt))"
        }
        let day = isoDate(calendar.startOfDay(for: resolved.date))
        return resolved.isApproximate ? "due around \(day)" : "due \(day)"
    }

    /// Where and when the phrase was spoken, for the tooltip's second line.
    static func sourceLine(quote: String, spokenAt: Date, meetingTitle: String? = nil) -> String {
        let when = formatted(spokenAt, as: "EEE, MMM d 'at' h:mm a")
        return [quote, meetingTitle, when].compactMap { $0 }.joined(separator: " · ")
    }

    /// Pinned to POSIX English so the date reads in the same language as the
    /// "Due"/"Overdue" it sits next to — the app's UI chrome is English
    /// regardless of the user's generated-output language.
    private static func weekdayName(_ date: Date) -> String {
        formatted(date, as: "EEEE")
    }

    private static func shortDate(_ date: Date, includeYear: Bool = false) -> String {
        formatted(date, as: includeYear ? "MMM d, yyyy" : "MMM d")
    }

    private static func isoDate(_ date: Date) -> String {
        formatted(date, as: "yyyy-MM-dd")
    }

    /// Cached per format — `DateFormatter` construction dwarfs the formatting
    /// itself, and these run several times per row on every list render.
    private static let formatters: [String: DateFormatter] = {
        let formats = ["EEEE", "MMM d", "MMM d, yyyy", "EEE, MMM d 'at' h:mm a", "yyyy-MM-dd"]
        return Dictionary(uniqueKeysWithValues: formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return (format, formatter)
        })
    }()

    private static func formatted(_ date: Date, as format: String) -> String {
        formatters[format]?.string(from: date) ?? ""
    }
}
