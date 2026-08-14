import AppKit
import SwiftUI

struct OrganizationSection: View {
    @ObservedObject var service: OrganizationService
    @State private var newName = ""
    @State private var inviteEmail = ""
    @State private var inviteRole: OrgRole = .member

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            contextCard
            if let membership = service.activeMembership {
                if !service.teams(in: membership.id).isEmpty {
                    teamsCard(membership)
                }
                if membership.role.administers {
                    inviteCard(membership)
                    if !service.members.isEmpty { membersCard(membership) }
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

    private func teamsCard(_ membership: OrgMembership) -> some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-user",
                title: "Teams",
                subtitle: service.teams(in: membership.id).map(\.name).joined(separator: ", ")
            ) {
                EmptyView()
            }
        }
    }

    private func inviteCard(_ membership: OrgMembership) -> some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-user",
                title: "Invite someone",
                subtitle: "They get an email with a link. It only works for the address you send it to."
            ) {
                EmptyView()
            }
            SettingsRowDivider()
            inviteField(membership)
            if let url = service.lastInviteURL {
                SettingsRowDivider()
                inviteLinkRow(url)
            }
            ForEach(service.pendingInvites) { invite in
                SettingsRowDivider()
                pendingInviteRow(invite, in: membership.id)
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

    private func inviteLinkRow(_ url: String) -> some View {
        HStack(spacing: 10) {
            Text(url)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            .font(.system(size: 12, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pendingInviteRow(_ invite: OrgInvite, in orgID: UUID) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.email)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Invited as \(invite.role.displayName.lowercased()) · not accepted yet")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
            Spacer(minLength: 8)
            Button("Revoke") {
                Task { await service.revokeInvite(invite, in: orgID) }
            }
            .font(.system(size: 12))
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.danger)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func membersCard(_ membership: OrgMembership) -> some View {
        SettingsCard {
            SettingsRow(icon: "nc-users", title: "Members", subtitle: nil) { EmptyView() }
            ForEach(service.members.filter(\.isActive)) { member in
                SettingsRowDivider()
                memberRow(member, viewerRole: membership.role, orgID: membership.id)
            }
        }
    }

    private func memberRow(_ member: OrgMember, viewerRole: OrgRole, orgID: UUID) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? member.email)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.ink)
                if member.displayName != nil {
                    Text(member.email)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            Spacer(minLength: 8)
            MemberActions(
                member: member,
                isSelf: member.userID == service.currentUserID,
                viewerRole: viewerRole,
                grantableRoles: service.grantableRoles(as: viewerRole),
                setRole: { role in Task { await service.setRole(role, for: member, in: orgID) } },
                remove: { Task { await service.removeMember(member, in: orgID) } }
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

/// One choosable context in the switcher.
///
/// A struct rather than a helper method because the row owns hover state, and a
/// `some View` helper cannot hold any.
///
/// Selection is the surface itself — fill plus a hairline border — with no tick
/// beside it. Once the row is visibly chosen the mark restates what the shape
/// already says, and it was the one thin glyph on a card of heavier type. Safe
/// for `differentiateWithoutColor` because the signal is a fill, not a hue;
/// VoiceOver hears it from the `.isSelected` trait below, which is where that
/// belongs anyway.
private struct ContextRow: View {
    let title: String
    let subtitle: String
    /// The name to take an initial from. `nil` is the personal context, which
    /// gets a person rather than a letter — it is not one organization among
    /// several, it is the absence of one.
    let monogram: String?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radii.chip)
                    .stroke(isSelected ? Theme.Palette.borderStrong : .clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Theme.Palette.surfaceStrong }
        return isHovering ? Theme.Palette.surface : .clear
    }

    @ViewBuilder
    private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip)
        ZStack {
            shape.fill(isSelected ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
            shape.stroke(Theme.Palette.border, lineWidth: 0.5)
            if let monogram, let initial = monogram.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            } else {
                Image("nc-user")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
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

/// The role a member holds, and what the viewer may do about it.
///
/// The menu offers only what the server would accept — role changes to owners,
/// removal to owners and administrators — because an action that exists in the
/// interface and fails on use teaches people not to trust the interface. The
/// database still refuses independently; this only keeps the two in agreement.
private struct MemberActions: View {
    let member: OrgMember
    /// You administer an organization, not yourself. A sole owner cannot be
    /// removed from their own organization at all, and offering the action on
    /// your own row promises something the server will refuse. Leaving or
    /// closing the organization live in the pane, where they belong.
    let isSelf: Bool
    let viewerRole: OrgRole
    let grantableRoles: [OrgRole]
    let setRole: (OrgRole) -> Void
    let remove: () -> Void

    @State private var isConfirmingRemoval = false

    var body: some View {
        if viewerRole.administers, !isSelf {
            Menu {
                if viewerRole == .owner {
                    Picker("Role", selection: roleBinding) {
                        ForEach(grantableRoles) { role in
                            Text(role.displayName).tag(role)
                        }
                    }
                    Divider()
                }
                Button("Remove from organization…", role: .destructive) {
                    isConfirmingRemoval = true
                }
            } label: {
                Text(member.role.displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .plainMenuChrome()
            .fixedSize()
            .accessibilityLabel("\(member.displayName ?? member.email), \(member.role.displayName)")
            .confirmationDialog(
                "Remove \(member.displayName ?? member.email) from the organization?",
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive, action: remove)
                Button("Cancel", role: .cancel) {}
            } message: {
                // Says what does *not* happen, because that is the part people
                // get wrong: removal ends access, it does not retract work. What
                // they recorded for the organization stays with the organization,
                // which is what makes retention and legal hold mean anything.
                Text(
                    "They lose access to this organization and go back to their personal space. Sessions they recorded here stay with the organization."
                )
            }
        } else {
            Text(member.role.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    private var roleBinding: Binding<OrgRole> {
        Binding(get: { member.role }, set: setRole)
    }
}

/// Closing the organization — an owner's action, and the only exit for a sole
/// one.
///
/// Kept at the foot of the pane and behind its own confirmation because it ends
/// access for everybody at once, which no other control here does.
private struct DeleteOrganizationCard: View {
    let organization: Organization
    let delete: () -> Void

    @State private var isConfirming = false

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-trash",
                title: "Delete organization",
                subtitle: "Everyone loses access. Sessions recorded here keep belonging to the organization and stay readable by whoever recorded them."
            ) {
                Button("Delete…") {
                    isConfirming = true
                }
                .font(.system(size: 12.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.danger)
            }
        }
        .confirmationDialog(
            "Delete \(organization.name)?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Delete organization", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every member loses access immediately and goes back to their personal space. Pending invites stop working. This can't be undone from the app."
            )
        }
    }
}
