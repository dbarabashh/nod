import AppKit
import SwiftUI

struct OrganizationSection: View {
    @ObservedObject var service: OrganizationService
    @State private var newName = ""
    @State private var inviteEmail = ""
    @State private var inviteRole: OrgRole = .member
    @State private var newTeamName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            contextCard
            if let membership = service.activeMembership {
                if membership.role.administers {
                    peopleCard(membership)
                    teamsCard(membership)
                } else if !service.teams(in: membership.id).isEmpty {
                    teamsCard(membership)
                }
            }
            if service.memberships.isEmpty {
                createCard
            }
            if let membership = service.activeMembership, membership.role == .owner {
                DeleteOrganizationCard(organization: membership.organization) {
                    Task { await service.deleteOrganization(membership.id) }
                }
            }
            if let error = service.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.danger)
            }
        }
        .task {
            await service.refreshIfNeeded()
            if let active = service.activeMembership, active.role.administers {
                await service.loadMembers(in: active.id)
            }
        }
    }

    private var contextCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "Where new sessions go",
                subtitle: "Sessions you record are filed here. Your own sessions stay visible to you in every context — switching never hides your work."
            ) {
                EmptyView()
            }
            SettingsRowDivider()
            VStack(spacing: 2) {
                ContextRow(
                    title: "Personal",
                    subtitle: "Only you",
                    monogram: nil,
                    isSelected: service.activeOrgID == nil
                ) {
                    switchContext(to: nil)
                }
                ForEach(service.memberships) { membership in
                    ContextRow(
                        title: membership.organization.name,
                        subtitle: membership.role.displayName,
                        monogram: membership.organization.name,
                        isSelected: service.activeOrgID == membership.id
                    ) {
                        switchContext(to: membership.id)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
    }

    private func switchContext(to orgID: UUID?) {
        guard service.activeOrgID != orgID else { return }
        Task { await service.switchContext(to: orgID) }
    }

    private func createOrganization() {
        Task {
            if await service.createOrganization(named: newName) { newName = "" }
        }
    }

    private func sendInvite(to orgID: UUID) {
        Task {
            if await service.invite(email: inviteEmail, role: inviteRole, to: orgID) { inviteEmail = "" }
        }
    }

    /// Teams group people and the tools they reach for — not the recordings they
    /// make. A person sits in one team but records meetings that concern
    /// several, so filing a session under a team would ask a question with no
    /// honest answer; what a session is shared with is decided on its own axis.
    private func teamsCard(_ membership: OrgMembership) -> some View {
        let teams = service.teams(in: membership.id)
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
                newTeamField(membership)
            }
            ForEach(teams) { team in
                SettingsRowDivider()
                TeamRow(
                    team: team,
                    canAdminister: membership.role.administers,
                    members: service.teamMembers[team.id],
                    candidates: service.members.filter(\.isActive),
                    load: { await service.loadTeamMembers(team) },
                    rename: { name in Task { await service.renameTeam(team, to: name) } },
                    delete: { Task { await service.deleteTeam(team) } },
                    add: { member in Task { await service.addTeamMember(member, to: team) } },
                    remove: { member in Task { await service.removeTeamMember(member, from: team) } }
                )
            }
        }
    }

    private func newTeamField(_ membership: OrgMembership) -> some View {
        HStack(spacing: 10) {
            TextField("Team name", text: $newTeamName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            Button {
                createTeam(in: membership.id)
            } label: {
                Text("Add team")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(newTeamName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func createTeam(in orgID: UUID) {
        Task {
            if await service.createTeam(named: newTeamName, in: orgID) { newTeamName = "" }
        }
    }

    private func peopleCard(_ membership: OrgMembership) -> some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "People",
                subtitle: "Invites only work for the address you send them to."
            ) {
                Text(peopleCount)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
            }
            SettingsRowDivider()
            inviteField(membership)
            ForEach(service.pendingInvites) { invite in
                SettingsRowDivider()
                PersonRow(
                    name: invite.email,
                    detail: "Invited as \(invite.role.displayName.lowercased()) · not accepted yet",
                    isPending: true
                ) {
                    HStack(spacing: 12) {
                        Button("Copy link") {
                            copy(invite.url)
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.muted)
                        Button("Revoke") {
                            Task { await service.revokeInvite(invite, in: membership.id) }
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            ForEach(service.members.filter(\.isActive)) { member in
                SettingsRowDivider()
                PersonRow(
                    name: member.displayName ?? member.email,
                    detail: member.displayName == nil ? nil : member.email,
                    isPending: false
                ) {
                    MemberActions(
                        member: member,
                        isSelf: member.userID == service.currentUserID,
                        viewerRole: membership.role,
                        grantableRoles: service.grantableRoles(as: membership.role),
                        setRole: { role in Task { await service.setRole(role, for: member, in: membership.id) } },
                        remove: { Task { await service.removeMember(member, in: membership.id) } }
                    )
                }
            }
        }
    }

    private func inviteField(_ membership: OrgMembership) -> some View {
        HStack(spacing: 10) {
            TextField("name@company.com", text: $inviteEmail)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            SegmentedControl(
                selection: $inviteRole,
                options: service.grantableRoles(as: membership.role),
                title: \.displayName
            )
            .frame(width: membership.role == .owner ? 186 : 130)
            .accessibilityLabel("Role for the invite")
            Button {
                sendInvite(to: membership.id)
            } label: {
                Text("Invite")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!inviteEmail.contains("@") || service.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Counted apart, because "3" beside a list of five rows reads as a bug. An
    /// invited address is not a member yet — that is the whole difference the
    /// row below is drawing.
    private var peopleCount: String {
        let members = service.members.filter(\.isActive).count
        let invited = service.pendingInvites.count
        guard invited > 0 else { return "\(members)" }
        return "\(members) · \(invited) invited"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var createCard: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-users",
                title: "Create an organization",
                subtitle: "Shared billing and a shared place for your team's sessions."
            ) {
                EmptyView()
            }
            SettingsRowDivider()
            HStack(spacing: 10) {
                TextField("Organization name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5))
                Button {
                    createOrganization()
                } label: {
                    Text("Create")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || service.isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }
}

#if DEBUG
    private let previewOrg = Organization(id: UUID(), name: "Acme", slug: "acme")

    #Preview("Personal only") {
        OrganizationSection(service: .preview(memberships: []))
            .padding()
            .frame(width: 560)
            .background(WindowBackdrop())
    }

    #Preview("In an organization") {
        OrganizationSection(service: .preview(
            memberships: [OrgMembership(organization: previewOrg, role: .admin)],
            activeOrgID: previewOrg.id,
            teams: [Team(id: UUID(), orgID: previewOrg.id, name: "Platform")]
        ))
        .padding()
        .frame(width: 560)
        .background(WindowBackdrop())
    }
#endif
