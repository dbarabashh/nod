import Foundation

/// One distilled statement about an entity, as retrieval returns it.
///
/// Wire-compatible with the `concepts` rows `match_concepts` serves through
/// the proxy's search response. The knowledge layer's write side lives
/// server-side (the distiller and `apply_concept`); the client only reads
/// concepts, cites them, and — through `supersede_concept` — corrects one when
/// the room contradicts it.
struct RetrievedConcept: Decodable, Identifiable, Equatable {
    let id: UUID
    let entityID: UUID
    let kind: String
    let claimKey: String
    let body: String
    /// ISO timestamp from Postgres. Kept as the wire string; `validFrom`
    /// parses on demand — a decode strategy on the shared search decoder would
    /// impose itself on every other field.
    let validFromRaw: String?
    let meetingID: UUID?
    let provider: String?
    let externalKey: String?
    let similarity: Double

    enum CodingKeys: String, CodingKey {
        case id
        case entityID = "entity_id"
        case kind
        case claimKey = "claim_key"
        case body
        case validFromRaw = "valid_from"
        case meetingID = "meeting_id"
        case provider
        case externalKey = "external_key"
        case similarity
    }

    var validFrom: Date? {
        validFromRaw.flatMap(Self.parseTimestamp)
    }

    /// "12 Aug" — the date an answer cites beside the fact, in the same shape
    /// every session label already uses.
    var validFromLabel: String? {
        validFrom.map { Meeting.shortDateFormatter.string(from: $0) }
    }

    /// Postgres emits fractional seconds; a plain ISO8601 formatter refuses
    /// them, so try both shapes.
    private static func parseTimestamp(_ raw: String) -> Date? {
        withFractional.date(from: raw) ?? plain.date(from: raw)
    }

    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}

/// One search response's two stages together: the distilled facts for the
/// entities the question named, and the transcript chunks behind everything
/// else. Concepts are empty on an old proxy and while reading ships dark.
struct KnowledgeHits {
    let chunks: [RetrievedChunk]
    let concepts: [RetrievedConcept]

    static let empty = KnowledgeHits(chunks: [], concepts: [])
}

/// What one distillation pass did, for the recap's knowledge line. All zeros —
/// the expected outcome for most sessions — renders as nothing at all.
struct DistillCounts: Decodable, Equatable {
    let added: Int
    let updated: Int
    let retired: Int
    let noop: Int

    var changed: Int {
        added + updated + retired
    }
}
