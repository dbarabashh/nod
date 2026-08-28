import Foundation

/// How a beat's schedule reads in the list. Pure and table-driven so the same
/// beat says the same thing everywhere, and so it can be tested without
/// waiting for nine in the morning.
enum BeatSchedule {
    /// "Weekdays at 09:00", "Mondays at 17:00", "Every day at 08:30".
    static func describe(_ beat: Beat, locale: Locale = .current) -> String {
        describe(
            cadence: beat.cadence,
            hour: beat.hour,
            minute: beat.minute,
            weekday: beat.weekday,
            dayOfMonth: beat.dayOfMonth,
            locale: locale
        )
    }

    static func describe(_ template: BeatTemplates.Template, locale: Locale = .current) -> String {
        describe(
            cadence: template.cadence,
            hour: template.hour,
            minute: template.minute,
            weekday: template.weekday,
            dayOfMonth: template.dayOfMonth,
            locale: locale
        )
    }

    static func describe(
        cadence: Beat.Cadence,
        hour: Int,
        minute: Int,
        weekday: Int,
        dayOfMonth: Int = 1,
        locale: Locale = .current
    ) -> String {
        let time = clock(hour: hour, minute: minute, locale: locale)
        return switch cadence {
        case .daily: "Every day at \(time)"
        case .weekdays: "Weekdays at \(time)"
        case .weekly: "\(weekdayName(weekday, locale: locale))s at \(time)"
        case .monthly: "Monthly on the \(ordinal(dayOfMonth)) at \(time)"
        }
    }

    /// "1st", "2nd", "23rd" — the day of the month as a person says it.
    static func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    /// What the row says under the schedule. A disabled beat has no next run,
    /// and saying "Next: —" is worse than saying it is paused.
    static func nextRun(_ date: Date?, now: Date = Date(), locale: Locale = .current) -> String {
        guard let date else { return "Paused" }
        let calendar = Calendar.current
        let time = clock(from: date, locale: locale)
        if calendar.isDateInToday(date) { return "Next today at \(time)" }
        if calendar.isDateInTomorrow(date) { return "Next tomorrow at \(time)" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return "Next \(formatter.string(from: date)) at \(time)"
    }

    /// What became of the last run, in the words the row shows. Nil when a beat
    /// has never run — a row that says "never" reads as broken on the morning
    /// somebody created it.
    static func lastRun(_ run: BeatRun?, now: Date = Date(), locale: Locale = .current) -> String? {
        guard let run else { return nil }
        switch run.status {
        case .done: return "Last ran \(relative(run.scheduledFor, now: now, locale: locale))"
        case .failed: return run.error ?? "The last run failed"
        case .expired: return "Missed — this Mac was asleep"
        case .due, .claimed: return "Running now"
        case .unknown: return nil
        }
    }

    private static func relative(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func clock(hour: Int, minute: Int, locale: Locale) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return clock(from: date, locale: locale)
    }

    private static func clock(from date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("j:mm")
        return formatter.string(from: date)
    }

    /// ISO weekday (Monday = 1) as a name. `Calendar.weekdaySymbols` is indexed
    /// from Sunday, which is the off-by-one this exists to contain.
    static func weekdayName(_ isoWeekday: Int, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.weekdaySymbols
        let index = isoWeekday % 7
        guard symbols.indices.contains(index) else { return "" }
        return symbols[index]
    }
}
