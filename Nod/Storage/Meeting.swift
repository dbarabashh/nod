import Foundation

/// A persisted meeting — summary + transcript pair plus the metadata you
/// need to render a HistoryView row. Wire-compatible with the `meetings`
/// table created in migration `20260523204132_meetings.sql`. Issue #14.
struct Meeting: Codable, Identifiable {
    let id: UUID
    let userID: UUID
    /// Server-assigned via `default now()`. nil on a freshly-built Meeting
    /// before INSERT — the custom encoder omits it from the payload so the
    /// DB default kicks in instead of trusting the client's wall-clock.
    let createdAt: Date?
    let startedAt: Date
    let endedAt: Date
    let title: String?
    let summary: String
    let language: String

    // The full transcript is intentionally NOT persisted (issue #14 follow-up).
    // Storing every participant's words on our server creates retention /
    // discovery exposure we don't want to carry. The transcript lives only
    // in `TranscriptStore` during the meeting, gets fed to the LLM once for
    // summary generation, and is discarded with `store.clear()` on cleanup.

    enum CodingKeys: String, CodingKey {
        case id
        case userID     = "user_id"
        case createdAt  = "created_at"
        case startedAt  = "started_at"
        case endedAt    = "ended_at"
        case title
        case summary
        case language
    }

    /// Custom encode so `created_at` is omitted when nil — lets Postgres'
    /// `default now()` populate the column on insert. Without this, the
    /// client's wall-clock value (which may be skewed) would be sent and
    /// the default never used.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(language, forKey: .language)
    }

    /// Newly-completed meeting before insert — `id` is client-generated so a
    /// failed save can be retried with the same id (idempotent on the
    /// server side via PK). `createdAt` is intentionally nil so the DB
    /// default supplies an accurate server-side timestamp.
    static func newCompleted(
        userID: UUID,
        startedAt: Date,
        endedAt: Date,
        summary: String,
        language: String,
        title: String? = nil
    ) -> Meeting {
        Meeting(
            id: UUID(),
            userID: userID,
            createdAt: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            summary: summary,
            language: language
        )
    }

    /// Returns a copy with the title and summary replaced. Used by
    /// MeetingDetailView's autosave — Meeting's properties are all `let`,
    /// so updates flow as new value instances.
    func updating(title: String?, summary: String) -> Meeting {
        Meeting(
            id: id,
            userID: userID,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            summary: summary,
            language: language
        )
    }

    /// Convenience for HistoryView row rendering — finds the first line of
    /// actual content (skipping section headers like `**Topics covered**`,
    /// `**Topics covered:**`, or `**Topics covered**:`) and returns it
    /// without markdown markers.
    var summaryPreview: String {
        for raw in summary.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // Strip a leading bullet marker, then drop ALL inline `**` so we
            // don't ever leak literal asterisks into the preview text.
            var line = trimmed
            if line.hasPrefix("- ") { line.removeFirst(2) }
            line = line.replacingOccurrences(of: "**", with: "")
            // Drop a trailing colon — section headers might be written as
            // `**Section**:` or `**Section:**`; both reach here as
            // "Section:" after the strip above.
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { continue }
            if Self.looksLikeSectionHeader(cleaned) { continue }

            return cleaned
        }
        return "(no summary)"
    }

    /// Heuristic: short line ending in `:`, or matching one of the known
    /// recap section labels (EN + UA). Skipped from the preview so the
    /// user sees the first actual bullet instead of the structural header.
    private static func looksLikeSectionHeader(_ line: String) -> Bool {
        if line.count <= 30 && line.hasSuffix(":") { return true }
        let dropped = line.hasSuffix(":") ? String(line.dropLast()) : line
        return sectionHeaderLabels.contains(dropped.lowercased())
    }

    private static let sectionHeaderLabels: Set<String> = [
        "topics covered", "decisions made", "open questions", "recap",
        "теми обговорення", "теми", "рішення", "ухвалені рішення",
        "відкриті питання", "питання", "підсумок"
    ]

    /// Display title — falls back to a humanised date when the meeting was
    /// saved without an explicit title.
    func displayTitle(dateFormatter: DateFormatter) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return "Meeting on \(dateFormatter.string(from: startedAt))"
    }
}

// MARK: - Hashable

extension Meeting: Hashable {
    /// Hash on `id` only — transcripts are arbitrarily long, hashing them
    /// every time `NavigationLink(value:)` resolves a destination would
    /// burn CPU for no gain (id is already unique).
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Meeting, rhs: Meeting) -> Bool {
        lhs.id == rhs.id
    }
}
