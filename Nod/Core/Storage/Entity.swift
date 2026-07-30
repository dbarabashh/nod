import Foundation

enum EntityKind: String, Codable, CaseIterable {
    case person
    case project
    case topic

    var icon: String {
        switch self {
        case .person: "person.fill"
        case .project: "folder.fill"
        case .topic: "tag.fill"
        }
    }
}

/// A person, project, or topic the user's sessions reference. Wire-compatible
/// with the `entities` table (`20260602120300_add_entities.sql`). De-duped per
/// user on `(kind, normalized_name)`.
struct Entity: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let userID: UUID
    let kind: EntityKind
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case kind
        case name
    }
}

/// What the extractor pulls out of a finished session. Decoded from the
/// LLM's JSON; names are de-duped + normalized before they become `entities`.
struct ExtractedEntities: Codable {
    var people: [String]
    var projects: [String]
    var topics: [String]
    /// Diarized cluster number → the person speaking it, for the clusters the
    /// transcript names outright. Optional so a response from before this
    /// existed (or a model that omits it) still decodes.
    var speakers: [String: String]?

    var isEmpty: Bool {
        people.isEmpty && projects.isEmpty && topics.isEmpty
    }

    /// Flattened `(kind, name)` pairs with blank names dropped.
    var pairs: [(kind: EntityKind, name: String)] {
        let p = people.map { (EntityKind.person, $0) }
        let pr = projects.map { (EntityKind.project, $0) }
        let t = topics.map { (EntityKind.topic, $0) }
        return (p + pr + t)
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
    }
}
