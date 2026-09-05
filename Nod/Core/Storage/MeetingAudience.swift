import Foundation

/// Everyone who can open a session, from every route that lets them.
///
/// The header's access chip answers one question — *is this only mine* — and it
/// was answering it from `meeting_grants` alone. That is one of the ways in.
/// `meetings`' own read policies name several:
///
///   * a grant on the session (`_meetings_granted_to_me`)
///   * **a project the session is filed in, shared with a team or the org**
///     (`can_read_meeting_via_folder`)
///   * having listened to the room live (`_rooms_i_listened_to_recently`)
///   * being an org admin, for a session stamped with an org
///
/// A chip reading "Only me" over a session sitting in a shared project is not
/// an imprecision, it is the wrong answer to the only question it exists for.
/// So the two routes a person controls are counted together here, and told
/// apart — because unsharing them are different acts in different places.
///
/// The remaining two are not represented and cannot be: a listener's access is
/// a fact about a call that already happened, and an admin's is a property of
/// the organization rather than of this session. Neither is something the
/// person looking at this row can change.
struct MeetingAudience: Equatable {
    /// Reached by a grant on the session itself. Revocable from the session.
    let direct: [String]
    /// Reached because the session is filed in a shared project. Revoking one
    /// belongs to the project — it would take the access away from every other
    /// session in it, which is not a decision this screen can make.
    let viaProjects: [Reach]

    struct Reach: Equatable {
        let project: String
        let audiences: [String]
    }

    var isPrivate: Bool {
        direct.isEmpty && viaProjects.allSatisfy(\.audiences.isEmpty)
    }

    /// Everybody, once each, direct routes first.
    var everyone: [String] {
        var seen: Set<String> = []
        return (direct + viaProjects.flatMap(\.audiences)).filter { seen.insert($0).inserted }
    }

    /// Names the audience rather than counting it: "Shared with 2 groups" tells
    /// you a number and leaves you to go and find out which two.
    ///
    /// "Shared with" is not decoration. An organization and a project can carry
    /// the same name, and they did — this chip read "Nod" beside a project chip
    /// reading "Nod", two different facts wearing one word. The verb separates
    /// them.
    var title: String {
        let names = everyone
        switch names.count {
        case 0: return "Only me"
        case 1: return "Shared with \(names[0])"
        default: return "Shared with \(names[0]) +\(names.count - 1)"
        }
    }

    /// Built from what the two stores already hold. Static and plain-valued so
    /// the answer can be tested — a chip that states who can read a recording
    /// is not something to check by opening the app and squinting.
    static func of(
        grants: [MeetingGrant],
        projects: [(name: String, shares: [FolderShare])],
        teams: [(id: UUID, name: String)],
        orgName: String
    ) -> MeetingAudience {
        func name(team teamID: UUID?, org orgID: UUID?) -> String? {
            if orgID != nil { return orgName }
            guard let teamID else { return nil }
            return teams.first { $0.id == teamID }?.name
        }
        // The org first when it is there: it is the widest audience, and the
        // widest is what somebody checking "who can see this" needs read first.
        let wide: [String] = grants.filter { $0.orgID != nil }.compactMap { name(team: $0.teamID, org: $0.orgID) }
        let narrow: [String] = grants.filter { $0.orgID == nil }.compactMap { name(team: $0.teamID, org: $0.orgID) }
        let direct: [String] = wide + narrow
        let reaches = projects.compactMap { project -> Reach? in
            let audiences = project.shares.compactMap { name(team: $0.teamID, org: $0.orgID) }
            return audiences.isEmpty ? nil : Reach(project: project.name, audiences: audiences)
        }
        return MeetingAudience(direct: direct, viaProjects: reaches)
    }
}
