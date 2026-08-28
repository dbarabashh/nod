import Foundation

/// A question the user saved and asked Nod to keep asking — every weekday at
/// nine, every Monday, every morning. The prompt is whatever they would have
/// typed into Ask Nod; a beat holds no template slots and no branching, because
/// what makes the answer worth reading is the context it is answered from, not
/// the shape of the question.
///
/// Wire-compatible with `public.beats`. The schedule arithmetic is Postgres'
/// (`next_beat_run`), so `nextRunAt` is read here and never written: the list,
/// the cron tick and this Mac cannot disagree about when a beat is next due.
struct Beat: Codable, Identifiable, Equatable {
    enum Cadence: String, Codable, CaseIterable, Equatable {
        case daily
        case weekdays
        case weekly
        case monthly
    }

    let id: UUID
    let userID: UUID
    var title: String
    var prompt: String
    var cadence: Cadence
    /// Wall-clock time in `timezone`, not an instant — "every morning at nine"
    /// has to survive a flight and a daylight-saving change.
    var hour: Int
    var minute: Int
    /// ISO weekday, Monday = 1. Read only for `.weekly`.
    var weekday: Int
    /// Day of the month for `.monthly`, 1–28. Capped below 29 server-side: a
    /// beat set for the 30th would silently skip February.
    var dayOfMonth: Int
    var timezone: String
    var enabled: Bool
    let nextRunAt: Date?
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case title
        case prompt
        case cadence
        case hour
        case minute
        case weekday
        case dayOfMonth = "day_of_month"
        case timezone
        case enabled
        case nextRunAt = "next_run_at"
        case createdAt = "created_at"
    }

    /// Insert payload. `next_run_at` and `created_at` are server-owned — a
    /// device sending its own would let a Mac whose clock is a day fast claim
    /// tomorrow's slot today.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(userID, forKey: .userID)
        try container.encode(title, forKey: .title)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(hour, forKey: .hour)
        try container.encode(minute, forKey: .minute)
        try container.encode(weekday, forKey: .weekday)
        try container.encode(dayOfMonth, forKey: .dayOfMonth)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(enabled, forKey: .enabled)
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled beat" : trimmed
    }
}

/// One occurrence of a beat: the instant it came due, and what became of it.
///
/// A run is created server-side when the schedule comes round, claimed by
/// whichever Mac is awake, and finished by that same Mac once the answer is
/// written. `expired` is the honest name for the case this design accepts —
/// nobody was awake inside the claim window, so the question went unasked.
struct BeatRun: Codable, Identifiable, Equatable {
    enum Status: String {
        case due
        case claimed
        case done
        case failed
        case expired
        /// A status this build doesn't know. Kept as its own case so a server
        /// that learns a new one degrades to "not actionable" instead of
        /// failing to decode the row at all.
        case unknown
    }

    let id: UUID
    let beatID: UUID
    let userID: UUID
    /// When the beat was due, not when it ran. A briefing claimed at 10:40
    /// because the Mac was shut is still the 09:00 briefing.
    let scheduledFor: Date
    let statusRaw: String
    let threadID: UUID?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case beatID = "beat_id"
        case userID = "user_id"
        case scheduledFor = "scheduled_for"
        case statusRaw = "status"
        case threadID = "thread_id"
        case error
    }

    var status: Status {
        Status(rawValue: statusRaw) ?? .unknown
    }
}
