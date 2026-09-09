import SwiftUI

/// What this organization is: who holds it, which products it permits, and the
/// two ways to end your part in it.
struct OrganizationOverview: View {
    @ObservedObject var service: OrganizationService
    var integrations: IntegrationService?
    let membership: OrgMembership

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if membership.role.administers {
                ownersCard
                if let integrations {
                    toolsCard(integrations)
                }
            }
            dangerZone
        }
    }

    /// Ownership is transferred by making a second owner, not by handing a
    /// title over — so the card says that rather than offering a button for a
    /// thing the server has no verb for. It is also the only way out for a sole
    /// owner, who otherwise sees "delete the organization" as their one exit.
    private var ownersCard: some View {
        let owners = service.members.filter { $0.isActive && $0.role == .owner }
        return SettingsCard {
            SettingsRow(
                icon: "nc-shield-check",
                title: owners.count == 1 ? "Owner" : "Owners",
                subtitle: "Owners control the organization and its data. To hand it over, make somebody else an owner on the People page — then step down or leave."
            ) {
                Text("\(owners.count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
            }
            ForEach(owners) { owner in
                SettingsRowDivider()
                PersonRow(
                    name: owner.displayName ?? owner.email,
                    detail: owner.displayName == nil ? nil : owner.email,
                    isSelf: owner.userID == service.currentUserID,
                    isPending: false
                ) {
                    EmptyView()
                }
            }
        }
    }

    /// The organization's answer for every product, in one table.
    ///
    /// An administrator setting company policy is asking one question about every
    /// product, so it is asked once, here. It used to sit as a bare switch on
    /// each row of the Integrations pane, beside the person's own connection —
    /// two different people's decisions on one line, one of them unlabelled.
    private func toolsCard(_ integrations: IntegrationService) -> some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-puzzle-piece",
                title: "Tools in \(membership.organization.name)",
                subtitle: "Turn a product off and Nod stops acting in it for everybody here, whether or not they connected their own account."
            ) {
                EmptyView()
            }
            SettingsRowDivider()
            columnHeader
            ForEach(IntegrationProvider.allCases) { provider in
                SettingsRowDivider()
                HStack(spacing: 10) {
                    ProviderMark(provider: provider, size: 15)
                    Text(provider.displayName)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.ink)
                    Spacer(minLength: 8)
                    OrgToolToggle(service: integrations, provider: provider, membership: membership)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }

    private var columnHeader: some View {
        HStack {
            SectionLabel("Tool")
            Spacer(minLength: 8)
            SectionLabel("Allowed")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityHidden(true)
    }

    /// Under a label of its own, because leaving and closing are not two more
    /// settings — a card that looks like every other card is a card people
    /// click through.
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Organization actions")
            if !service.isSoleOwner(of: membership.id) {
                LeaveOrganizationCard(organization: membership.organization) {
                    Task { await service.leaveOrganization(membership.id) }
                }
            }
            if membership.role == .owner {
                DeleteOrganizationCard(organization: membership.organization) {
                    Task { await service.deleteOrganization(membership.id) }
                }
            }
        }
        .padding(.top, 6)
    }
}

/// Whether the organization permits one tool at all — an administrator's
/// answer, and the only place it is asked.
struct OrgToolToggle: View {
    @ObservedObject var service: IntegrationService
    let provider: IntegrationProvider
    let membership: OrgMembership

    var body: some View {
        Toggle(
            "Allowed in \(membership.organization.name)",
            isOn: Binding(
                get: { !service.blockedByOrganization.contains(provider) },
                set: { allowed in
                    Task { await service.setAllowed(allowed, for: provider, in: membership.id) }
                }
            )
        )
        .nodSwitch()
        .controlSize(.mini)
        .labelsHidden()
        .help("Allowed in \(membership.organization.name)")
        .accessibilityLabel("\(provider.displayName) allowed in \(membership.organization.name)")
    }
}
