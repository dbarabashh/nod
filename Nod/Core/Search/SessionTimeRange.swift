import Foundation

/// "What happened last week?" is a question a calendar answers exactly and an
/// embedding can't answer at all — no one says "last week" inside the meeting
/// it refers to, so vector search has nothing to match on and the session
/// router is left guessing. Query prep reads the period out of the question,
/// in whatever language it was asked, and this turns it into a concrete window.
///
/// Pure and time-injectable so the table is unit-testable.
enum SessionTimeRange {
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

    /// A period that has not happened yet. There are no sessions in it, so it
    /// resolves to the recent ones, where plans for it would have been said.
    static let upcoming = "upcoming"

    /// What a standup report covers, and so a period that is about the user's
    /// own work whatever else query prep made of the question.
    static let sinceLastWorkdayKey = "since_last_workday"

    /// The window query prep named, in the vocabulary its prompt lists.
    ///
    /// The model reads the period and this only does the arithmetic: which
    /// words mean "last week" is a question about every language people ask
    /// in, and a phrase table answered it for three.
    static func resolve(period: String, now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        var week = calendar
        week.firstWeekday = 2
        let key = period.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "today": return calendar.dateInterval(of: .day, for: now)
        case "yesterday": return shifted(.day, by: -1, from: now, calendar: calendar)
        case "this_week": return week.dateInterval(of: .weekOfYear, for: now)
        case "last_week": return shifted(.weekOfYear, by: -1, from: now, calendar: week)
        case "this_month": return calendar.dateInterval(of: .month, for: now)
        case "last_month": return shifted(.month, by: -1, from: now, calendar: calendar)
        case sinceLastWorkdayKey: return sinceLastWorkday(now: now, calendar: calendar)
        case upcoming: return planningLookback(now: now, calendar: calendar)
        default: break
        }
        if key.hasPrefix("last_"), key.hasSuffix("_days"), let days = Int(key.dropFirst(5).dropLast(5)), days > 0,
           let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) {
            return DateInterval(start: start, end: now)
        }
        // The prompt states today's date in the Gregorian calendar, so the
        // dates that come back are read in it too, whatever the device uses.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let written = key.components(separatedBy: "..").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1 ... 2).contains(written.count), let first = day(written[0], calendar: gregorian) else { return nil }
        // "Since the 6th" is written open-ended, and ends now.
        if written.count == 2, written[1].isEmpty {
            return first <= now ? DateInterval(start: first, end: now) : nil
        }
        guard let last = day(written[written.count - 1], calendar: gregorian), first <= last,
              let end = gregorian.dateInterval(of: .day, for: last)?.end
        else { return nil }
        return DateInterval(start: first, end: end)
    }

    private static func day(_ text: String, calendar: Calendar) -> Date? {
        let written = text.split(separator: "-", omittingEmptySubsequences: false)
        let parts = written.compactMap { Int($0) }
        // A two-digit year is year 26, and the sessions "nearest" to it are
        // simply the oldest ones.
        guard written.count == 3, parts.count == 3, (2000 ... 2100).contains(parts[0]) else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        // `date(from:)` rolls the 45th of month 13 over into a real day.
        guard let date = calendar.date(from: components) else { return nil }
        let read = calendar.dateComponents([.year, .month, .day], from: date)
        return (read.year, read.month, read.day) == (parts[0], parts[1], parts[2]) ? date : nil
    }

    /// From the start of the previous working day until now — what a standup
    /// report covers. "Today's daily" names the day of the meeting, not of the
    /// work: read as today, a Monday-morning report was built from the hour
    /// before it was asked for.
    static func sinceLastWorkday(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        var day = calendar.startOfDay(for: now)
        repeat {
            guard let earlier = calendar.date(byAdding: .day, value: -1, to: day) else { return nil }
            day = earlier
        } while calendar.isDateInWeekend(day)
        return DateInterval(start: day, end: now)
    }

    /// Recent sessions, where plans for the coming days would have been said.
    static func planningLookback(now: Date = Date(), calendar: Calendar = .current) -> DateInterval? {
        guard let start = calendar.date(byAdding: .day, value: -planningLookbackDays, to: calendar.startOfDay(for: now)) else {
            return nil
        }
        return DateInterval(start: start, end: now)
    }

    private static func shifted(_ unit: Calendar.Component, by value: Int, from now: Date, calendar: Calendar) -> DateInterval? {
        guard let shifted = calendar.date(byAdding: unit, value: value, to: now) else { return nil }
        return calendar.dateInterval(of: unit, for: shifted)
    }
}
