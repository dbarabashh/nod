import Foundation

/// One persisted Whisper-finalised chunk. Wire-compatible with the
/// `meeting_transcripts` table; one row per `TranscriptEntry` produced
/// during a meeting. `idx` is the position within the meeting so the
/// detail view can order entries without trusting `ts` for ties.
struct TranscriptRecord: Codable, Identifiable {
    let id: UUID
    let meetingID: UUID
    let userID: UUID
    let createdAt: Date?
    let source: String
    let text: String
    let ts: Date
    let idx: Int
    /// Which clustered voice on the `them` stream said this, `1...N` in order of
    /// first appearance. Nil when the session wasn't diarized, when clustering
    /// couldn't attribute the line, or on the `me` stream — the user's own mic
    /// is a single known speaker and is never clustered.
    let speaker: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case userID = "user_id"
        case createdAt = "created_at"
        case source
        case text
        case ts
        case idx
        case speaker
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(meetingID, forKey: .meetingID)
        try c.encode(userID, forKey: .userID)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(source, forKey: .source)
        try c.encode(text, forKey: .text)
        try c.encode(ts, forKey: .ts)
        try c.encode(idx, forKey: .idx)
        try c.encodeIfPresent(speaker, forKey: .speaker)
    }
}

extension TranscriptRecord {
    /// `Me`, or `Them` narrowed to the clustered voice when diarization
    /// attributed the line — `Them · Speaker 2`. The source prefix stays so
    /// every existing surface (and every prompt rule keyed on `[Them]`) keeps
    /// reading the same way whether or not speakers were resolved.
    func displayLabel() -> String {
        let base = TranscriptSource(rawValue: source)?.label ?? source
        guard let speaker, TranscriptSource(rawValue: source) == .them else { return base }
        return "\(base) · Speaker \(speaker)"
    }

    /// A copy with the diarized speaker stripped — used to retry an insert
    /// against a database where the `speaker` column hasn't been applied yet,
    /// so a not-yet-migrated environment never costs the whole transcript.
    func droppingSpeaker() -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            meetingID: meetingID,
            userID: userID,
            createdAt: createdAt,
            source: source,
            text: text,
            ts: ts,
            idx: idx,
            speaker: nil
        )
    }
}
