import SwiftUI

/// Teams group people and the tools they reach for — not the recordings they
/// make. A person sits in one team but records meetings that concern several,
/// so filing a session under a team would ask a question with no honest answer;
/// what a session is shared with is decided on its own axis.
struct OrganizationTeams: View {
    @ObservedObject var service: OrganizationService
    let membership: OrgMembership

    @State private var newTeamName = ""

    var body: some View {
        let teams = service.teams(in: membership.id)
        let candidates = service.members.filter(\.isActive)
        return SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "Teams",
                subtitle: "Each team can point an integration at its own workspace."
            ) {
                Text("\(teams.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
            }
            if membership.role.administers {
                SettingsRowDivider()
                newTeamField
            }
            ForEach(teams) { team in
                SettingsRowDivider()
                TeamRow(
                    team: team,
                    canAdminister: membership.role.administers,
                    members: service.teamMembers[team.id],
                    candidates: candidates,
                    load: { await service.loadTeamMembers(team) },
                    rename: { name in Task { await service.renameTeam(team, to: name) } },
                    delete: { Task { await service.deleteTeam(team) } },
                    add: { member in Task { await service.addTeamMember(member, to: team) } },
                    remove: { member in Task { await service.removeTeamMember(member, from: team) } },
                    leave: service.teamMembers[team.id]?.contains { $0.userID == service.currentUserID } == true
                        ? { Task { await service.leaveTeam(team) } }
                        : nil
                )
            }
            if teams.isEmpty, !membership.role.administers {
                SettingsRowDivider()
                SettingsEmptyRow("No teams yet.")
            }
        }
    }

    private var newTeamField: some View {
        InlineCreateRow(prompt: "Team name", text: $newTeamName, buttonTitle: "Add team", action: createTeam)
    }

    private func createTeam() {
        Task {
            if await service.createTeam(named: newTeamName, in: membership.id) { newTeamName = "" }
        }
    }
}
