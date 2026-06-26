import Combine
import Foundation
import Supabase

/// Persists extracted entities + their session links, and answers the two
/// read questions the UI asks: "what entities does this session touch?" and
/// "what other sessions are related to it?". RLS scopes everything to the
/// owner.
@MainActor
final class EntityStore: ObservableObject {
    private let supabase: SupabaseClient
    private static let entitiesTable = "entities"
    private static let linksTable = "meeting_entities"

    init(supabase: SupabaseClient) {
        self.supabase = supabase
    }

    /// Upserts the extracted entities (de-duped per user) and links them to
    /// the session. Best-effort: extraction is an enrichment, never a blocker,
    /// so failures are logged and swallowed by the caller.
    func saveExtraction(_ extracted: ExtractedEntities, meetingID: UUID, userID: UUID) async throws {
        let pairs = dedupe(extracted.pairs)
        guard !pairs.isEmpty else { return }
        Log.ui.info("EntityStore.saveExtraction meeting=\(meetingID.uuidString) entities=\(pairs.count)")

        struct EntityUpsert: Encodable {
            let user_id: UUID
            let kind: String
            let name: String
            let normalized_name: String
            let updated_at: Date
        }
        let now = Date()
        let rows = pairs.map {
            EntityUpsert(
                user_id: userID,
                kind: $0.kind.rawValue,
                name: $0.name,
                normalized_name: normalize($0.name),
                updated_at: now
            )
        }
        let saved: [Entity] = try await supabase
            .from(Self.entitiesTable)
            .upsert(rows, onConflict: "user_id,kind,normalized_name")
            .select()
            .execute()
            .value

        struct LinkUpsert: Encodable {
            let meeting_id: UUID
            let entity_id: UUID
            let user_id: UUID
        }
        let links = saved.map { LinkUpsert(meeting_id: meetingID, entity_id: $0.id, user_id: userID) }
        guard !links.isEmpty else { return }
        try await supabase
            .from(Self.linksTable)
            .upsert(links, onConflict: "meeting_id,entity_id")
            .execute()
    }

    /// Entities linked to one session, for the detail view's chip row.
    func entities(forMeeting meetingID: UUID) async -> [Entity] {
        do {
            struct Link: Decodable { let entity_id: UUID }
            let links: [Link] = try await supabase
                .from(Self.linksTable)
                .select("entity_id")
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
                .value
            let ids = links.map(\.entity_id.uuidString)
            guard !ids.isEmpty else { return [] }
            let entities: [Entity] = try await supabase
                .from(Self.entitiesTable)
                .select()
                .in("id", values: ids)
                .execute()
                .value
            return entities.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            Log.ui.error("EntityStore.entities(forMeeting) failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Other sessions that share at least one entity with this one, ranked by
    /// how many they share, newest-first as a tiebreak. Capped small — this
    /// drives a humble "Related" list, not a graph.
    func relatedMeetings(to meetingID: UUID, limit: Int = 5) async -> [Meeting] {
        do {
            struct Link: Decodable { let entity_id: UUID; let meeting_id: UUID }

            let mine: [Link] = try await supabase
                .from(Self.linksTable)
                .select("entity_id, meeting_id")
                .eq("meeting_id", value: meetingID.uuidString)
                .execute()
                .value
            let entityIDs = mine.map(\.entity_id.uuidString)
            guard !entityIDs.isEmpty else { return [] }

            let neighbours: [Link] = try await supabase
                .from(Self.linksTable)
                .select("entity_id, meeting_id")
                .in("entity_id", values: entityIDs)
                .neq("meeting_id", value: meetingID.uuidString)
                .execute()
                .value
            guard !neighbours.isEmpty else { return [] }

            var sharedCount: [UUID: Int] = [:]
            for link in neighbours {
                sharedCount[link.meeting_id, default: 0] += 1
            }
            let rankedIDs = sharedCount.keys.map(\.uuidString)

            let meetings: [Meeting] = try await supabase
                .from("meetings")
                .select()
                .in("id", values: rankedIDs)
                .is("deleted_at", value: nil)
                .execute()
                .value

            return meetings
                .sorted {
                    let lhs = sharedCount[$0.id] ?? 0
                    let rhs = sharedCount[$1.id] ?? 0
                    if lhs != rhs { return lhs > rhs }
                    return $0.startedAt > $1.startedAt
                }
                .prefix(limit)
                .map { $0 }
        } catch {
            Log.ui.error("EntityStore.relatedMeetings failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Normalization

    private func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Collapse duplicates within a single extraction (same kind + normalized
    /// name), keeping the first surface form.
    private func dedupe(_ pairs: [(kind: EntityKind, name: String)]) -> [(kind: EntityKind, name: String)] {
        var seen = Set<String>()
        var result: [(kind: EntityKind, name: String)] = []
        for pair in pairs {
            let key = "\(pair.kind.rawValue):\(normalize(pair.name))"
            if seen.insert(key).inserted {
                result.append(pair)
            }
        }
        return result
    }
}
