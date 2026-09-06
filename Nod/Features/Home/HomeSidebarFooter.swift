import SwiftUI

/// The sidebar's bottom band: what needs attention, what Nod is doing, and who
/// you are signed in as. Its own view because the sidebar above it is already
/// long, and none of this depends on the lists it sits under.
struct HomeSidebarFooter: View {
    let surface: MainWindowView.Surface

    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var entitlements: EntitlementService
    @EnvironmentObject private var settingsFocus: SettingsFocus
    @EnvironmentObject private var feed: UpdaterChannelDelegate

    var body: some View {
        VStack(spacing: 2) {
            Divider()
                .overlay(Theme.Palette.border)
                .padding(.bottom, 6)
            if let update = feed.available {
                UpdateSidebarRow(update: update, action: feed.install)
                    .transition(.opacity)
            }
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
        SidebarNavRow(title: displayName, subtitle: planLabel, verticalPadding: 6) {
            settingsFocus.open(.profile)
        } leading: {
            Image("nc-user")
                .icon(15)
                .foregroundStyle(Theme.Palette.muted)
        }
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

/// "Update Nod · 13.2.0" — the one sidebar row that is an offer, not a place.
/// Tinted with the brand rather than selected, because it is never where you
/// are; it is something waiting for you.
struct UpdateSidebarRow: View {
    let update: FeedBuild
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarRowMetrics.inset) {
                Image("nc-refresh-2")
                    .icon(12.5)
                    .frame(width: 16)
                Text("Update Nod")
                    .textStyle(Theme.Typography.uiEmphasis)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(update.version)
                    .textStyle(Theme.Typography.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.Palette.brand)
            .padding(.horizontal, SidebarRowMetrics.inset)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.brand.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                            .stroke(Theme.Palette.brand.opacity(0.28), lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .linkCursor()
        .help("Update Nod to \(update.label)")
        .accessibilityLabel("Update Nod to version \(update.version)")
    }
}

#Preview("Update offered") {
    UpdateSidebarRow(update: FeedBuild(version: "13.2.0", build: 71), action: {})
        .frame(width: HomeSidebar.width - 20)
        .padding(10)
        .background(Theme.Palette.bg)
}
