import SwiftUI

/// The organization you belong to, stated rather than chosen.
///
/// This was a context switcher, and the switch was a promise the product does
/// not keep: membership decides what you can read, sharing is settled per
/// session, and a recording is filed the same way in either context. Switching
/// hid nothing and revealed nothing.
///
/// The one case where a choice is real is belonging to two: `org_directory`,
/// `org_people` and every sharing target are scoped to one active organization,
/// and the server cannot guess which. Then, and only then, this is a menu.
struct OrgSidebarRow: View {
    @EnvironmentObject private var organizations: OrganizationService
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var isSwitchable: Bool {
        organizations.memberships.count > 1
    }

    var body: some View {
        Group {
            if isSwitchable {
                Menu {
                    ForEach(organizations.memberships) { membership in
                        Button {
                            switchContext(to: membership.id)
                        } label: {
                            IconLabel(
                                title: membership.organization.name,
                                icon: organizations.activeOrgID == membership.id ? "nc-check" : "nc-users",
                                size: 11
                            )
                        }
                    }
                    Divider()
                    Button("Organization settings…", action: openSettings)
                } label: {
                    surface
                }
                .plainMenuChrome()
            } else if let membership = organizations.activeMembership {
                Button(action: openSettings) {
                    surface
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "\(membership.organization.name), \(membership.role.displayName). Opens organization settings."
                )
            }
        }
        .onHover { isHovering = $0 }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
    }

    /// Deliberately without a fill or a border. It sits directly above the
    /// Start Nod button, which carries both — two identical plates stacked read
    /// as two controls of equal weight, and this one is a label saying which
    /// organization you are in.
    ///
    /// Sized for a mark rather than for a letter. The tile used to hold an
    /// initial the name beside it already spelled, so it could stay small; a
    /// logo is the one thing here that isn't repeated in words, and at 24pt it
    /// read as an icon in front of a label instead of the company's face.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
        return HStack(spacing: 10) {
            OrgMonogram(
                name: organizations.activeMembership?.organization.name,
                size: 32,
                logo: organizations.activeMembership.flatMap { organizations.logoURL(for: $0.organization) }
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(organizations.activeMembership?.organization.name ?? "Personal")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .lineLimit(1)
                Text(organizations.activeMembership?.role.displayName ?? "Only you")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isSwitchable {
                Image("nc-chevron-expand-y")
                    .icon(10)
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .hoverHighlight(isHovering, reduceMotion: reduceMotion)
        .contentShape(shape)
    }

    /// `SettingsFocus` rather than a notification: this row is inside the main
    /// window, whose pane already watches the injected request. The notification
    /// path exists for the entry points that start outside the window.
    private func openSettings() {
        settingsFocus.open(.organization)
    }

    private func switchContext(to orgID: UUID) {
        guard organizations.activeOrgID != orgID else { return }
        Task { await organizations.switchContext(to: orgID) }
    }
}
