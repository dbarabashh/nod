import Foundation

/// Which calendar entries the person has stepped out of, and why.
///
/// Kept on this Mac, in defaults, and never sent to the calendar: an answer
/// here means "don't offer to record it and show me what is after it", not a
/// declined invitation — declining emails the organizer, and that is a write
/// the person has to confirm in so many words.
enum MeetingAttendance {
    /// One key per answer rather than one dictionary of answers, so the marks
    /// written before there was a reason keep reading as "not going".
    enum Answer: String, CaseIterable {
        case notGoing
        case task

        var defaultsKey: String {
            switch self {
            case .notGoing: "calendar.notAttending"
            case .task: "calendar.madeTask"
            }
        }
    }

    /// Identity across ticks and surfaces. Two occurrences of a recurring
    /// meeting are different meetings; the same one seen twice is not.
    static func fingerprint(_ occurrence: CalendarOccurrence) -> String {
        "\(occurrence.title)@\(occurrence.startsAt.timeIntervalSince1970)"
    }

    /// Every entry with an answer, whatever it was.
    static func skipped(defaults: UserDefaults = .standard) -> Set<String> {
        Set(answers(defaults).keys)
    }

    static func answers(_ defaults: UserDefaults = .standard) -> [String: Answer] {
        Answer.allCases.reduce(into: [:]) { table, answer in
            for fingerprint in entries(for: answer, in: defaults).keys {
                table[fingerprint] = answer
            }
        }
    }

    static func answer(for occurrence: CalendarOccurrence, defaults: UserDefaults = .standard) -> Answer? {
        answers(defaults)[fingerprint(occurrence)]
    }

    static func mark(
        _ occurrence: CalendarOccurrence,
        as answer: Answer,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        clear(occurrence, now: now, defaults: defaults)
        var current = pruned(entries(for: answer, in: defaults), now: now)
        current[fingerprint(occurrence)] = occurrence.endsAt.timeIntervalSince1970
        defaults.set(current, forKey: answer.defaultsKey)
    }

    static func clear(_ occurrence: CalendarOccurrence, now: Date = Date(), defaults: UserDefaults = .standard) {
        for answer in Answer.allCases {
            var current = pruned(entries(for: answer, in: defaults), now: now)
            current.removeValue(forKey: fingerprint(occurrence))
            defaults.set(current, forKey: answer.defaultsKey)
        }
    }

    /// The first entry still ahead that the person has not stepped out of.
    static func next(
        in upcoming: [CalendarOccurrence],
        now: Date,
        skipping skipped: Set<String>
    ) -> CalendarOccurrence? {
        upcoming.first { $0.endsAt > now && !skipped.contains(fingerprint($0)) }
    }

    private static func entries(for answer: Answer, in defaults: UserDefaults) -> [String: Double] {
        defaults.dictionary(forKey: answer.defaultsKey) as? [String: Double] ?? [:]
    }

    /// A meeting that has ended cannot be skipped any more, so its mark goes
    /// with it — the list would otherwise grow by one for every meeting ever
    /// stepped out of.
    static func pruned(_ entries: [String: Double], now: Date) -> [String: Double] {
        entries.filter { $0.value > now.timeIntervalSince1970 }
    }
}
