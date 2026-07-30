import Foundation

/// One persisted Whisper-finalised chunk. Wire-compatible with the
/// `meeting_transcripts` table; one row per `TranscriptEntry` produced
/// during a meeting. `idx` is the position within the meeting so the
/// detail view can order entries without trusting `ts` for ties.
struct TranscriptRecord: Codable, Identifiable, Equatable {
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
    var speaker: Int?

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
    /// What a person reads on the row: the speaker's name once we know it,
    /// otherwise the routing tag — `Me`, `Them`, or `Them · Speaker 2`. A name
    /// replaces `Them` rather than narrowing it; "Them · Eric" reads as two
    /// people to everyone but us.
    func displayLabel(names: [String: String]? = nil) -> String {
        guard let speaker = themSpeaker else { return sourceLabel }
        return name(for: speaker, in: names) ?? "\(sourceLabel) · Speaker \(speaker)"
    }

    /// The label a prompt sees. `[Me]` / `[Them]` are routing hints every
    /// playbook rule in `PromptLibrary` keys on, so here a name NARROWS the tag
    /// instead of replacing it — dropping `Them` would silently disable those
    /// rules for exactly the meetings we managed to name.
    func promptLabel(names: [String: String]? = nil) -> String {
        guard let speaker = themSpeaker else { return sourceLabel }
        let narrowed = name(for: speaker, in: names) ?? "Speaker \(speaker)"
        return "\(sourceLabel) · \(narrowed)"
    }

    private var sourceLabel: String {
        TranscriptSource(rawValue: source)?.label ?? source
    }

    /// The clustered voice on the remote stream, or nil — the user's own mic is
    /// one known speaker and is never clustered.
    private var themSpeaker: Int? {
        TranscriptSource(rawValue: source) == .them ? speaker : nil
    }

    /// Trimmed at the read boundary too, not only before writing: the map is
    /// server state, so a row written by another build is not ours to trust.
    private func name(for speaker: Int, in names: [String: String]?) -> String? {
        guard let raw = names?["\(speaker)"] else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// A copy with the diarized speaker stripped — used to retry an insert
    /// against a database where the `speaker` column hasn't been applied yet,
    /// so a not-yet-migrated environment never costs the whole transcript.
    func droppingSpeaker() -> TranscriptRecord {
        var copy = self
        copy.speaker = nil
        return copy
    }
}

extension [TranscriptRecord] {
    /// The transcript in the shape every prompt expects: one tagged line per
    /// record. The `[Me]` / `[Them]` tag is load-bearing — the playbook rules in
    /// `PromptLibrary` key on it — so each surface that grounds a model in a
    /// saved meeting has to hand it the same shape, or a rule fires on one
    /// surface and not another.
    func promptContext(names: [String: String]?) -> String {
        map { "[\($0.promptLabel(names: names))]: \($0.text)" }
            .joined(separator: "\n")
    }
}
