import SwiftUI

/// Who is in the organization — members and the addresses that have been asked
/// and haven't answered.
///
/// One list, not two. Keeping invites in a strip of their own made the roster
/// read as complete when it wasn't, which is exactly the moment somebody
/// re-invites a person who already has a live invite. The filter above it does
/// the separating instead.
struct OrganizationPeople: View {
    @ObservedObject var service: OrganizationService
    let membership: OrgMembership

    @State private var filter = Filter.all
    @State private var isInviting = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, members, pending

        var id: String {
            rawValue
        }
    }

    private static let metaWidth: CGFloat = 96
    private static let roleWidth: CGFloat = 96

    private var canAdminister: Bool {
        membership.role.administers
    }

    var body: some View {
        let people = filter == .pending ? [] : service.roster
        let invites = canAdminister && filter != .members ? service.pendingInvites : []
        return VStack(alignment: .leading, spacing: 12) {
            toolbar
            SettingsCard {
                columnHeader
                ForEach(invites) { invite in
                    SettingsRowDivider()
                    inviteRow(invite)
                }
                ForEach(people) { entry in
                    SettingsRowDivider()
                    personRow(entry)
                }
                if invites.isEmpty, people.isEmpty {
                    SettingsRowDivider()
                    SettingsEmptyRow(filter == .pending ? "No invites waiting." : "Nobody here yet.")
                }
            }
        }
        .sheet(isPresented: $isInviting) {
            InviteSheet(service: service, membership: membership)
        }
        .task { await service.loadRoster(in: membership.id, canAdminister: canAdminister) }
    }

    /// The filter counts invites, so it only means anything to somebody who can
    /// see them. A member gets the plain roster and the sentence explaining why
    /// it carries less than an administrator's.
    @ViewBuilder
    private var toolbar: some View {
        if canAdminister {
            let members = service.roster.count
            let invites = service.pendingInvites.count
            HStack(spacing: 10) {
                SegmentedControl(selection: $filter, options: Filter.allCases) { option in
                    switch option {
                    case .all: "All \(members + invites)"
                    case .members: "Members \(members)"
                    case .pending: "Pending \(invites)"
                    }
                }
                .frame(maxWidth: 280)
                Spacer(minLength: 8)
                inviteButton
            }
        } else {
            Text("Everybody you can name in \(membership.organization.name). Roles, join dates and invites are an administrator's view.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var inviteButton: some View {
        GlassPillButton("Invite people", leadingIcon: "nc-plus") {
            isInviting = true
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            SectionLabel("Name")
                .padding(.leading, 38)
            Spacer(minLength: 8)
            if canAdminister {
                SectionLabel("Joined")
                    .frame(width: Self.metaWidth, alignment: .leading)
                SectionLabel("Role")
                    .frame(width: Self.roleWidth, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func personRow(_ entry: RosterEntry) -> some View {
        let isSelf = entry.id == service.currentUserID
        return PersonRow(
            name: entry.name,
            detail: entry.detail,
            joined: entry.joinedAt,
            isSelf: isSelf,
            metaWidth: canAdminister ? Self.metaWidth : nil,
            isPending: false
        ) {
            if let member = entry.member {
                MemberActions(
                    member: member,
                    isSelf: isSelf,
                    viewerRole: membership.role,
                    grantableRoles: service.grantableRoles(as: membership.role),
                    setRole: { role in Task { await service.setRole(role, for: member, in: membership.id) } },
                    remove: { Task { await service.removeMember(member, in: membership.id) } }
                )
                .frame(width: Self.roleWidth, alignment: .trailing)
            }
        }
    }

    private func inviteRow(_ invite: OrgInvite) -> some View {
        PersonRow(
            name: invite.email,
            detail: "Invited as \(invite.role.displayName.lowercased()) · not accepted yet",
            isPending: true
        ) {
            HStack(spacing: 12) {
                Button("Copy link") {
                    NSPasteboard.copyText(invite.url)
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
}
