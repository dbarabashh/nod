import Foundation

/// One person on the organization's roster, whichever RPC answered for them.
///
/// `list_org_members` is an administrator's RPC and raises for everybody else;
/// `org_directory` answers for a member with names and addresses and nothing
/// more. Which of the two to call is the service's knowledge — it used to be
/// spelled out in the People page, in the pane that hosts it, and again in the
/// row that loaded it, so three places had to agree about the backend's
/// authorization model.
struct RosterEntry: Identifiable, Equatable {
    let id: UUID
    let name: String
    let detail: String?
    let joinedAt: Date?
    /// Present only where the administrator's RPC answered — the role menu and
    /// the removal action have nothing to act on without it.
    let member: OrgMember?
}

extension OrganizationService {
    /// Loads whichever roster this viewer is allowed to see.
    func loadRoster(in orgID: UUID, canAdminister: Bool) async {
        if canAdminister {
            await loadMembers(in: orgID)
        } else {
            await refreshDirectoryIfNeeded()
        }
    }

    /// `members` is populated by the administrator's RPC alone, so a non-empty
    /// one is the richer answer and the directory is the fallback. No flag
    /// tracks which call won because the emptiness already says it.
    static func rosterEntries(members: [OrgMember], directory: [Teammate]) -> [RosterEntry] {
        let active = members.filter(\.isActive)
        guard active.isEmpty else {
            return active.map { member in
                RosterEntry(
                    id: member.userID,
                    name: member.displayName ?? member.email,
                    detail: member.displayName == nil ? nil : member.email,
                    joinedAt: member.joinedAt,
                    member: member
                )
            }
        }
        return directory.map { teammate in
            RosterEntry(
                id: teammate.userID,
                name: teammate.name,
                detail: teammate.displayName == nil ? nil : teammate.email,
                joinedAt: nil,
                member: nil
            )
        }
    }
}
