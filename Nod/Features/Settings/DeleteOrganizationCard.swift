import SwiftUI

/// Closing the organization — an owner's action, and the only exit for a sole
/// one.
///
/// Kept at the foot of the pane and behind its own confirmation because it ends
/// access for everybody at once, which no other control here does.
struct DeleteOrganizationCard: View {
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
