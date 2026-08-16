import Foundation

/// Which voice in a recording belongs to whom, and on what evidence.
///
/// Wire compatible with `meeting_speakers` (`20260816210000_meeting_speakers.sql`).
/// It does not replace `Meeting.speakerNames` — that map is still what the
/// transcript draws, and every shipped build reads it. This carries what a
/// string cannot: the person behind the name, and how far the naming may be
/// trusted.
struct MeetingSpeaker: Codable, Equatable {
    /// The diarized cluster, as it appears in `TranscriptRecord.speaker`.
    let cluster: Int
    /// Set only once somebody is actually identified. Null is the normal answer
    /// outside an organization, where there is nobody to identify them as.
    var personID: UUID?
    var displayName: String?
    var confidence: Double
    var decidedBy: Decision

    /// The signal that put a name on the cluster.
    ///
    /// Ordered by how much it may be trusted, which is the only reason the
    /// distinction is recorded: a name good enough to print above a line of
    /// transcript is not automatically good enough to file work against.
    enum Decision: String, Codable, Equatable {
        /// The local microphone. Certain by construction — there is one person
        /// behind it. Not emitted today: the mic is its own transcript source
        /// rather than a cluster, so clusters are remote voices only.
        case microphone
        /// The conferencing app's participant list. Not emitted today either:
        /// the roster feeds the naming pass rather than deciding a cluster on
        /// its own, so what it contributes is recorded as `llm`. Kept because
        /// the column accepts it and a value the database can hold must decode.
        case roster
        /// The naming pass, reading the transcript for who addressed whom.
        case llm
        /// The last unnamed cluster, when every other name was taken.
        case elimination
        /// The user answered "who was that". The only signal that can attach a
        /// person rather than a name.
        case user

        /// How far this signal may be trusted, before anything about the
        /// specific meeting is taken into account.
        ///
        /// A standing property of the signal, not a measurement — the naming
        /// pass is right most of the time and wrong often enough that nobody
        /// should be assigned a ticket on its say-so alone.
        var confidence: Double {
            switch self {
            case .microphone, .user: 1.0
            case .roster: 0.8
            case .llm: 0.6
            case .elimination: 0.5
            }
        }
    }

    /// The bar a naming has to clear before Nod will act on it — name somebody
    /// as the owner of a task, or address them in a connected product.
    ///
    /// Set so that only a confirmed identity or the user's own microphone
    /// qualifies. Everything the naming pass produces stays displayable and
    /// stays unusable as an assignment, which is the split
    /// `18. Confidence and Trust` asks for.
    static let actionableConfidence = 0.9

    var isActionable: Bool {
        personID != nil && confidence >= Self.actionableConfidence
    }

    enum CodingKeys: String, CodingKey {
        case cluster
        case personID = "person_id"
        case displayName = "display_name"
        case confidence
        case decidedBy = "decided_by"
    }
}

/// A name plus the signal that produced it, as the naming pass hands it back.
///
/// The pass used to answer with `[cluster: name]`, which threw away the one
/// thing the finalize now needs to persist. Callers that only want to render a
/// transcript take `.names`.
struct SpeakerAttribution: Equatable {
    let name: String
    let decidedBy: MeetingSpeaker.Decision
}

extension [String: SpeakerAttribution] {
    /// The plain cluster→name map, for everything that only draws a label.
    var names: [String: String] {
        mapValues(\.name)
    }

    func rows(personIDs: [String: UUID] = [:]) -> [MeetingSpeaker] {
        compactMap { cluster, attribution in
            guard let number = Int(cluster) else { return nil }
            return MeetingSpeaker(
                cluster: number,
                personID: personIDs[cluster],
                displayName: attribution.name,
                confidence: attribution.decidedBy.confidence,
                decidedBy: attribution.decidedBy
            )
        }
    }
}
