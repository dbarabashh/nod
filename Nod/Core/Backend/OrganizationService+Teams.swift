import Foundation
import Supabase

/// Teams: the boundary of people and the tools they reach for.
///
/// Kept apart from the organization surface it extends because the two answer
/// different questions — who belongs to the company, and who works on what
/// inside it — and because one type carrying both had outgrown the file it
/// lived in.
@MainActor
extension OrganizationService {
    @discardableResult
    func createTeam(named name: String, in orgID: UUID) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let supabase, !trimmed.isEmpty else { return false }
        do {
            struct Params: Encodable {
                let p_org: UUID
                let p_name: String
            }
            _ = try await supabase.rpc("create_team", params: Params(p_org: orgID, p_name: trimmed)).execute()
            await reloadTeams()
            lastError = nil
            Log.ui.info("team created")
            return true
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't create that team."
            Log.ui.error("OrganizationService.createTeam failed: \(error.localizedDescription)")
            return false
        }
    }

    func renameTeam(_ team: Team, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let supabase, !trimmed.isEmpty else { return }
        do {
            struct Params: Encodable {
                let p_team: UUID
                let p_name: String
            }
            _ = try await supabase.rpc("rename_team", params: Params(p_team: team.id, p_name: trimmed)).execute()
            await reloadTeams()
            lastError = nil
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't rename that team."
            Log.ui.error("OrganizationService.renameTeam failed: \(error.localizedDescription)")
        }
    }

    func deleteTeam(_ team: Team) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_team: UUID
            }
            _ = try await supabase.rpc("delete_team", params: Params(p_team: team.id)).execute()
            teamMembers[team.id] = nil
            await reloadTeams()
            lastError = nil
            Log.ui.info("team deleted")
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't delete that team."
            Log.ui.error("OrganizationService.deleteTeam failed: \(error.localizedDescription)")
        }
    }

    func addTeamMember(_ member: OrgMember, to team: Team) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_team: UUID
                let p_user: UUID
            }
            _ = try await supabase.rpc("add_team_member", params: Params(p_team: team.id, p_user: member.userID)).execute()
            await loadTeamMembers(team)
            lastError = nil
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't add that person."
            Log.ui.error("OrganizationService.addTeamMember failed: \(error.localizedDescription)")
        }
    }

    func removeTeamMember(_ member: TeamMember, from team: Team) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_team: UUID
                let p_user: UUID
            }
            _ = try await supabase.rpc("remove_team_member", params: Params(p_team: team.id, p_user: member.userID)).execute()
            await loadTeamMembers(team)
            lastError = nil
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't remove that person."
            Log.ui.error("OrganizationService.removeTeamMember failed: \(error.localizedDescription)")
        }
    }

    func loadTeamMembers(_ team: Team) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_team: UUID
            }
            teamMembers[team.id] = try await supabase
                .rpc("list_team_members", params: Params(p_team: team.id))
                .execute()
                .value
        } catch {
            Log.ui.error("OrganizationService.loadTeamMembers failed: \(error.localizedDescription)")
        }
    }

    private func reloadTeams() async {
        guard let supabase, !memberships.isEmpty else { return }
        teams = await (try? supabase
            .from("teams")
            .select("id, org_id, name")
            .execute()
            .value) ?? teams
    }

    func leaveTeam(_ team: Team) async {
        guard let supabase else { return }
        do {
            struct Params: Encodable {
                let p_team: UUID
            }
            _ = try await supabase.rpc("leave_team", params: Params(p_team: team.id)).execute()
            teamMembers[team.id] = nil
            lastError = nil
            Log.ui.info("left team")
        } catch {
            lastError = Self.rpcMessage(error) ?? "Couldn't leave that team."
            Log.ui.error("OrganizationService.leaveTeam failed: \(error.localizedDescription)")
        }
    }
}
