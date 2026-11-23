import Foundation

/// The `nod-meetings` v1 file the new Nod imports. The shape is a contract with
/// that app: change a key or a meaning here and files already exported stop
/// importing.
struct MeetingArchive: Encodable, Equatable {
    let format = "nod-meetings"
    let version = 1
    let exportedAt: Date
    let meetings: [ArchivedMeeting]

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, meetings
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct ArchivedMeeting: Encodable, Equatable {
    let id: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let summary: String
    let folder: String?
    let transcript: [ArchivedLine]

    enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, summary, folder, transcript
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(summary, forKey: .summary)
        try container.encode(folder, forKey: .folder)
        try container.encode(transcript, forKey: .transcript)
    }
}

struct ArchivedLine: Encodable, Equatable {
    enum Speaker: String, Encodable {
        case me, others
    }

    let speaker: Speaker
    let startMs: Int
    let endMs: Int
    let text: String
}

/// One `meetings` row as the export reads it. Its own type rather than
/// `Meeting`, whose non-optional `kind` enum fails the whole page on a value
/// this build has never seen.
struct MeetingArchiveRow: Decodable, Equatable {
    let id: UUID
    let createdAt: Date?
    let startedAt: Date?
    let endedAt: Date?
    let title: String?
    let summary: String?
    let recap: MeetingRecap?

    init(
        id: UUID,
        createdAt: Date? = nil,
        startedAt: Date?,
        endedAt: Date?,
        title: String?,
        summary: String?,
        recap: MeetingRecap? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.summary = summary
        self.recap = recap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        // A recap this build cannot read still leaves the rendered `summary`.
        recap = try? container.decodeIfPresent(MeetingRecap.self, forKey: .recap)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case title
        case summary
        case recap = "recap_json"
    }

    static let columns = "id,created_at,started_at,ended_at,title,summary,recap_json"
}

/// A project the user filed meetings under (`labels`).
struct LabelArchiveRow: Decodable, Equatable {
    let id: UUID
    let userID: UUID
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case name
    }

    static let columns = "id,user_id,name"
}

/// One meeting filed under one project (`meeting_labels`).
struct MeetingLabelArchiveRow: Decodable, Equatable {
    let meetingID: UUID
    let labelID: UUID

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case labelID = "label_id"
    }

    static let columns = "meeting_id,label_id"
}

/// One `meeting_transcripts` row. `ts` is the wall-clock instant the line was
/// spoken (`TranscriptEntry.timestamp`, see `MeetingEnrichment.records`), not an
/// offset.
struct TranscriptArchiveRow: Decodable, Equatable {
    let meetingID: UUID
    let source: String
    let text: String
    let ts: Date
    let idx: Int

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case source, text, ts, idx
    }

    static let columns = "meeting_id,source,text,ts,idx"
}

extension MeetingArchive {
    static func make(
        rows: [MeetingArchiveRow],
        transcripts: [UUID: [TranscriptArchiveRow]],
        folders: [UUID: String] = [:],
        exportedAt: Date
    ) -> MeetingArchive {
        var seen = Set<UUID>()
        let meetings = rows.compactMap { row -> ArchivedMeeting? in
            guard seen.insert(row.id).inserted else { return nil }
            guard let startedAt = row.startedAt ?? row.createdAt else { return nil }
            return ArchivedMeeting(
                id: row.id.uuidString.lowercased(),
                title: row.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                startedAt: startedAt,
                endedAt: row.endedAt,
                summary: summary(of: row),
                folder: folders[row.id],
                transcript: lines(transcripts[row.id] ?? [], startedAt: startedAt, endedAt: row.endedAt)
            )
        }
        return MeetingArchive(exportedAt: exportedAt, meetings: meetings)
    }

    /// What the Summary tab shows: the typed recap when there is one, the
    /// stored markdown otherwise. The two failure placeholders are not a
    /// summary, so they export as none.
    static func summary(of row: MeetingArchiveRow) -> String {
        if let recap = row.recap, !recap.isEmpty {
            return recap.toMarkdown()
        }
        let stored = (row.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = [Meeting.summaryUnavailableNote, Meeting.recoveredPlaceholder]
        return placeholders.contains(stored) ? "" : stored
    }

    /// The one project each meeting is exported under. The new app has a single
    /// folder per meeting, so a meeting in several projects keeps the first by
    /// name. Only the owner's projects count, and a blank name is no project.
    static func folders(
        links: [MeetingLabelArchiveRow],
        labels: [LabelArchiveRow],
        ownerID: UUID
    ) -> [UUID: String] {
        let names = Dictionary(
            labels.compactMap { label -> (UUID, String)? in
                guard label.userID == ownerID else { return nil }
                let name = label.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : (label.id, name)
            },
            uniquingKeysWith: { first, _ in first }
        )
        var candidates: [UUID: [(id: UUID, name: String)]] = [:]
        for link in links {
            guard let name = names[link.labelID] else { continue }
            candidates[link.meetingID, default: []].append((link.labelID, name))
        }
        return candidates.compactMapValues { labels in
            labels.min { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                return left == right
                    ? lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
                    : left < right
            }?.name
        }
    }

    static func lines(_ rows: [TranscriptArchiveRow], startedAt: Date, endedAt: Date?) -> [ArchivedLine] {
        let spoken = rows
            .sorted { ($0.ts, $0.idx) < ($1.ts, $1.idx) }
            .compactMap { row -> (speaker: ArchivedLine.Speaker, startMs: Int, text: String)? in
                let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return (row.source == "me" ? .me : .others, offsetMs(row.ts, from: startedAt), text)
            }
        let lastEndMs = endedAt.map { offsetMs($0, from: startedAt) }
        return spoken.enumerated().map { index, line in
            let next = index + 1 < spoken.count ? spoken[index + 1].startMs : lastEndMs
            return ArchivedLine(
                speaker: line.speaker,
                startMs: line.startMs,
                endMs: max(line.startMs, next ?? line.startMs),
                text: line.text
            )
        }
    }

    private static func offsetMs(_ instant: Date, from start: Date) -> Int {
        max(0, Int((instant.timeIntervalSince(start) * 1000).rounded()))
    }
}
