import Foundation

/// A persisted meeting — summary + transcript pair plus the metadata you
/// need to render a MainWindowView row. Wire-compatible with the `meetings`
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
    /// What this recording is — drives audio capture + recap framing. Every
    /// legacy row defaults to `.meeting` server-side.
    let kind: SessionKind
    let summary: String
    /// Structured recap — same content as `summary` (which is the rendered
    /// markdown view) but as typed JSON: topics / decisions / actions /
    /// open_questions. Nullable for backward compatibility with rows
    /// generated before the `recap_json` column existed.
    let recap: MeetingRecap?
    let language: String
    /// Soft-delete timestamp — non-nil when the meeting lives in the Trash
    /// segment (#16). Nil for active rows. Server-driven; the client only
    /// reads this (mutations go via `MeetingStore.softDelete` / `.restore`).
    let deletedAt: Date?

    // The transcript itself lives in a sibling table — `meeting_transcripts`
    // (migration `20260527093241_meeting_transcripts.sql`) — one row per
    // Whisper-finalised chunk, cascade-deleted with this row. Kept off
    // `meetings` so the list-view fetch doesn't drag a meeting's worth of
    // text per row; the detail view loads transcript entries lazily when
    // the Transcript tab is opened.

    /// The short date a session is labelled with wherever it's listed — the
    /// launcher row, the chat's source chip, the grounding label. Shared so the
    /// same untitled session can't read differently in two of them.
    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        return formatter
    }()

    /// Date + time, for the surfaces that list sessions or head one. Shared so
    /// the same untitled session can't read differently in the list and in the
    /// chat header above it.
    static let listDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// "yesterday", "3d ago" — how old a session is, which is what the
    /// attention surfaces care about. One formatter, built once: allocating a
    /// `RelativeDateTimeFormatter` per row per render was measurable.
    static func ago(_ date: Date, relativeTo now: Date = Date()) -> String {
        agoFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let agoFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Whether this session matches a free-text query. Shared by the Library's
    /// filter and the launcher so the same words never surface a session in one
    /// and hide it in the other.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return title?.lowercased().contains(needle) == true || summary.lowercased().contains(needle)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case title
        case kind
        case summary
        case recap = "recap_json"
        case language
        case deletedAt = "deleted_at"
    }

    /// Custom encode so `created_at` and `deleted_at` are omitted when nil
    /// — lets Postgres' `default now()` populate the former on insert, and
    /// keeps the soft-delete column out of insert payloads entirely (the
    /// server starts every row at `deleted_at = NULL`; the client never
    /// sets it on insert).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(userID, forKey: .userID)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(kind, forKey: .kind)
        try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(recap, forKey: .recap)
        try c.encode(language, forKey: .language)
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
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
        kind: SessionKind = .meeting,
        title: String? = nil,
        recap: MeetingRecap? = nil
    ) -> Meeting {
        Meeting(
            id: UUID(),
            userID: userID,
            createdAt: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            kind: kind,
            summary: summary,
            recap: recap,
            language: language,
            deletedAt: nil
        )
    }

    /// Returns a copy with the title, summary, and recap replaced. Used by
    /// MeetingDetailView's autosave and by the end-of-meeting generation
    /// path — Meeting's properties are all `let`, so updates flow as new
    /// value instances. `recap` defaults to the existing value so callers
    /// that only touch text (manual edits) don't have to thread the JSON
    /// through; pass `recap: .some(newRecap)` to refresh structured state.
    func updating(title: String?, summary: String, recap: MeetingRecap? = nil) -> Meeting {
        Meeting(
            id: id,
            userID: userID,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            kind: kind,
            summary: summary,
            recap: recap ?? self.recap,
            language: language,
            deletedAt: deletedAt
        )
    }

    /// Returns a copy with the recording bookends taken from `draft`, keeping
    /// every other field. Used by the refresh merge: a meeting streamed to the
    /// server mid-recording carries `ended_at == started_at`, but the local
    /// generating draft holds the real stop time — so the duration stays
    /// accurate during generation without clobbering the server row's content.
    func withBookends(from draft: Meeting) -> Meeting {
        Meeting(
            id: id,
            userID: userID,
            createdAt: createdAt,
            startedAt: draft.startedAt,
            endedAt: draft.endedAt,
            title: title,
            kind: kind,
            summary: summary,
            recap: recap,
            language: language,
            deletedAt: deletedAt
        )
    }

    /// Returns a copy with only `deletedAt` replaced — the local-cache mirror
    /// of a soft delete / restore while the next refresh fetches the
    /// server-stamped value.
    func updating(deletedAt: Date?) -> Meeting {
        Meeting(
            id: id,
            userID: userID,
            createdAt: createdAt,
            startedAt: startedAt,
            endedAt: endedAt,
            title: title,
            kind: kind,
            summary: summary,
            recap: recap,
            language: language,
            deletedAt: deletedAt
        )
    }

    /// Convenience for MainWindowView row rendering — finds the first line of
    /// actual content (skipping section headers like `**Topics covered**`,
    /// `**Topics covered:**`, or `**Topics covered**:`) and returns it
    /// without markdown markers.
    var summaryPreview: String {
        for raw in summary.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            // A wholly-bold line is a section header (`**Topics covered**`,
            // `**Customer needs**`, …). With dynamic section titles the label
            // is unknown, so skip any line that is one full bold span rather
            // than relying on the known-label list below.
            if Self.isWhollyBold(trimmed) { continue }

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
    /// True when the line is a single bold span end-to-end — i.e. a section
    /// header like `**Decisions made**` with no other content. Inner `**` would
    /// mean the bold is only part of the line (real content), so those don't
    /// count.
    private static func isWhollyBold(_ line: String) -> Bool {
        guard line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 else { return false }
        let inner = line.dropFirst(2).dropLast(2)
        return !inner.contains("**") && !inner.isEmpty
    }

    private static func looksLikeSectionHeader(_ line: String) -> Bool {
        if line.count <= 30 && line.hasSuffix(":") { return true }
        let dropped = line.hasSuffix(":") ? String(line.dropLast()) : line
        return sectionHeaderLabels.contains(dropped.lowercased())
    }

    private static let sectionHeaderLabels: Set<String> = [
        "topics covered", "decisions made", "action items", "open questions", "recap",
        "теми обговорення", "теми", "рішення", "ухвалені рішення",
        "дії", "завдання", "пункти дій",
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

extension [Meeting] {
    /// Live sessions, newest first — the trash-visibility invariant in one
    /// place. A copy of this that forgets `deletedAt` leaks a deleted session
    /// into whatever surface re-rolled it.
    func liveNewestFirst() -> [Meeting] {
        filter { $0.deletedAt == nil }.sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Hashable

extension Meeting: Hashable {
    /// Hash on `id` only — id is already unique, so this satisfies the
    /// Hashable contract (equal values share an id ⟹ equal hashes) without
    /// hashing every field on each `NavigationLink(value:)` resolve.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
