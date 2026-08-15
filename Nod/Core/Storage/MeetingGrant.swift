import Foundation
import Supabase

/// One meeting handed to a team, or to the whole organization.
///
/// Not `FolderShare`, and not the public share link either. A folder share says
/// "everything I file here"; a link says "anyone holding this token, summary
/// only". This says "this call, these colleagues, the whole record" — which is
/// what the moment after a recording ends actually calls for, before anybody has
/// filed anything.
///
/// The audience is deliberately a team or an organization and never a person. A
/// grant made to whoever happened to be listening would stop meaning what it
/// meant the first time somebody joined or left; a grant made to the design team
/// keeps meaning it.
struct MeetingGrant: Decodable, Identifiable, Equatable {
    let id: UUID
    let meetingID: UUID
    /// Exactly one of these is set — `meeting_grants_one_audience` refuses a row
    /// that names both, because a grant with two audiences silently applies the
    /// wider one.
    let teamID: UUID?
    let orgID: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case teamID = "team_id"
        case orgID = "org_id"
    }
}

/// Which meetings have been handed to whom.
///
/// Separate from `MeetingStore` rather than folded into it: that type is already
/// at the size where SwiftLint stops it growing, and this is a different
/// question from "what did I record". It mirrors `LabelStore`'s sharing half so
/// the two read the same way.
@MainActor
final class MeetingGrantStore: ObservableObject {
    @Published private(set) var grants: [UUID: [MeetingGrant]] = [:]

    private let supabase: SupabaseClient?

    /// Optional so previews can seed state without a network client, the same
    /// way `OrganizationService` does.
    init(supabase: SupabaseClient?) {
        self.supabase = supabase
    }

    /// Every grant this account can see: the ones it made, and the ones that
    /// reach it. Both come back under RLS, so the same call serves the host
    /// deciding what to unshare and a colleague seeing what arrived.
    func refresh() async {
        guard let supabase else { return }
        do {
            let rows: [MeetingGrant] = try await supabase
                .from("meeting_grants")
                .select("id, meeting_id, team_id, org_id")
                .execute()
                .value
            grants = Dictionary(grouping: rows, by: \.meetingID)
        } catch {
            Log.ui.error("MeetingGrantStore.refresh failed: \(error.localizedDescription)")
        }
    }

    func grants(forMeeting meetingID: UUID) -> [MeetingGrant] {
        grants[meetingID] ?? []
    }

    /// The server checks that the meeting is yours and that the audience is
    /// inside your organization, so this passes the choice straight through.
    func share(_ meetingID: UUID, withTeam teamID: UUID?, org orgID: UUID?) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_meeting: UUID
                let p_team: UUID?
                let p_org: UUID?
            }
            _ = try await supabase
                .rpc("grant_meeting", params: Params(p_meeting: meetingID, p_team: teamID, p_org: orgID))
                .execute()
            await refresh()
            Log.ui.info("meeting shared")
        } catch {
            Log.ui.error("MeetingGrantStore.share failed: \(error.localizedDescription)")
        }
    }

    func unshare(_ grant: MeetingGrant) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_grant: UUID
            }
            _ = try await supabase
                .rpc("revoke_meeting_grant", params: Params(p_grant: grant.id))
                .execute()
            await refresh()
            Log.ui.info("meeting unshared")
        } catch {
            Log.ui.error("MeetingGrantStore.unshare failed: \(error.localizedDescription)")
        }
    }

    func clear() {
        grants = [:]
    }
}

#if DEBUG
    extension MeetingGrantStore {
        /// Seeds the published state directly so a preview can show the shared
        /// and unshared readings without a network client.
        static func preview(grants: [MeetingGrant] = []) -> MeetingGrantStore {
            let store = MeetingGrantStore(supabase: nil)
            store.grants = Dictionary(grouping: grants, by: \.meetingID)
            return store
        }
    }
#endif
