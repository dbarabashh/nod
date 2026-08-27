import SwiftUI

/// The sidebar's bottom band: what needs attention, what Nod is doing, and who
/// you are signed in as. Its own view because the sidebar above it is already
/// long, and none of this depends on the lists it sits under.
struct HomeSidebarFooter: View {
    let surface: MainWindowView.Surface

    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var settingsFocus: SettingsFocus

    var body: some View {
        VStack(spacing: 2) {
            Divider()
                .overlay(Theme.Palette.border)
                .padding(.bottom, 6)
            // Takes the service from the environment itself. Holding it here
            // instead meant every capture tick — one every 5 seconds while
            // ambient context runs — invalidated the whole sidebar body to
            // redraw one 30pt row.
            AmbientContextSidebarRow()
            SidebarNavRow(
                title: "Give 50%, get a free month",
                icon: "nc-gift",
                isSelected: false,
                action: { settingsFocus.open(.rewards) }
            )
            // Named panes, not just the surface: landing on whichever pane was
            // open last makes the same click go somewhere different each time.
            SidebarNavRow(
                title: "Settings",
                icon: "nc-gear-2",
                isSelected: surface == .settings,
                action: { settingsFocus.open(.general) }
            )
            accountRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// Goes to the profile, where the row above it goes to General. Two rows
    /// that opened the same pane read as one of them being broken.
    private var accountRow: some View {
        Button { settingsFocus.open(.profile) } label: {
            HStack(spacing: 9) {
                Image("nc-user")
                    .icon(15)
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                        .lineLimit(1)
                    Text(planLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Your profile")
    }

    private var displayName: String {
        let name = profileStore.profile?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Your account" : name
    }

    /// Reads the plan the server resolved. Unresolved (offline, first launch)
    /// says nothing rather than guessing a tier the user isn't on.
    private var planLabel: String {
        guard let entitlement = entitlements.entitlement else { return "—" }
        let plan = entitlement.plan.capitalized
        return entitlement.status == .trialing ? "\(plan) · trial" : plan
    }
}
