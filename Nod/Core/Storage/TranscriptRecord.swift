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

    /// Who said this, as a person reads it. `speakerNames` is sparse — only the
    /// clusters somebody has actually named are in it — so an unnamed cluster
    /// keeps its number rather than becoming "Unknown", which would collapse
    /// two different voices into one label.
    ///
    /// No speaker at all is the user: the `me` stream is a single known voice
    /// and is never clustered.
    func speakerName(from speakerNames: [String: String], selfSpeaker: Int? = nil) -> String {
        guard let speaker else {
            return TranscriptSource(rawValue: source)?.label ?? source
        }
        if let selfSpeaker, speaker == selfSpeaker { return "Me" }
        return speakerNames[String(speaker)] ?? "Speaker \(speaker)"
    }

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
    ///
    /// `host` is whoever recorded the session, passed only when the reader is
    /// somebody else. It replaces `Me` for the same reason a name replaces
    /// `Them`: on screen the tag is not routing, it is who spoke.
    /// `selfSpeaker` is which cluster is the person who recorded it. It only
    /// applies to a room recording: there the user is one voice among the
    /// others on a single stream, and that number is the only thing that says
    /// which. On `me`/`them` the routing already answers it.
    func displayLabel(names: [String: String]? = nil, host: String? = nil, selfSpeaker: Int? = nil) -> String {
        guard let speaker = clusteredSpeaker else { return host ?? sourceLabel }
        if isSelf(speaker, selfSpeaker: selfSpeaker) { return host ?? "Me" }
        if let named = name(for: speaker, in: names) { return named }
        // A room line has no routing tag worth showing — "Speaker · Speaker 2"
        // says the word twice and the stream nothing.
        return isRoom ? "Speaker \(speaker)" : "\(sourceLabel) · Speaker \(speaker)"
    }

    /// The label a prompt sees. `[Me]` / `[Them]` are routing hints every
    /// playbook rule in `PromptLibrary` keys on, so here a name NARROWS the tag
    /// instead of replacing it — dropping `Them` would silently disable those
    /// rules for exactly the meetings we managed to name. `host` narrows `Me`
    /// the same way, for the same reason.
    /// A room line is mapped onto the same `[Me]` / `[Them]` vocabulary rather
    /// than introducing a third tag: every grounding rule in `PromptLibrary`
    /// keys on those two, and a tag they don't name is a rule that silently
    /// stops applying to exactly the sessions the phone recorded.
    func promptLabel(names: [String: String]? = nil, host: String? = nil, selfSpeaker: Int? = nil) -> String {
        guard let speaker = clusteredSpeaker else {
            return host.map { "\(sourceLabel) · \($0)" } ?? sourceLabel
        }
        if isSelf(speaker, selfSpeaker: selfSpeaker) {
            return host.map { "\(TranscriptSource.me.label) · \($0)" } ?? TranscriptSource.me.label
        }
        let named = name(for: speaker, in: names) ?? "Speaker \(speaker)"
        let tag = isRoom ? TranscriptSource.them.label : sourceLabel
        return "\(tag) · \(named)"
    }

    private var sourceLabel: String {
        TranscriptSource(rawValue: source)?.label ?? source
    }

    /// The clustered voice this line carries, or nil — the user's own routed
    /// mic is one known speaker and is never clustered.
    private var clusteredSpeaker: Int? {
        (TranscriptSource(rawValue: source)?.isClustered ?? false) ? speaker : nil
    }

    private var isRoom: Bool {
        TranscriptSource(rawValue: source) == .room
    }

    /// Only a room recording can have the user inside its clusters.
    private func isSelf(_ speaker: Int, selfSpeaker: Int?) -> Bool {
        isRoom && selfSpeaker == speaker
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
    func promptContext(names: [String: String]?, host: String? = nil) -> String {
        map { "[\($0.promptLabel(names: names, host: host))]: \($0.text)" }
            .joined(separator: "\n")
    }
}
