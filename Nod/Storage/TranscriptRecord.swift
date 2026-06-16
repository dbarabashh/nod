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
    /// Diarized speaker index within the `them` stream (0-based); nil for `me`
    /// and meetings recorded before diarization.
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
    /// "Them" rows read cleaner as plain "Them" when only one remote speaker
    /// was detected; number them only once diarization separated more than one.
    static func speakersAreNumbered(_ records: [TranscriptRecord]) -> Bool {
        Set(records.compactMap { $0.source == TranscriptSource.them.rawValue ? $0.speaker : nil }).count > 1
    }

    /// `Me` / `Them`, or `Them N` when `numbered` and a speaker index is set.
    func displayLabel(numbered: Bool) -> String {
        guard let src = TranscriptSource(rawValue: source) else { return source }
        return src.displayLabel(speaker: speaker, numbered: numbered)
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
