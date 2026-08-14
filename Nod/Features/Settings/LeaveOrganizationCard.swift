import SwiftUI

/// Leaving, as the member's own act.
///
/// Sits where the owner sees "Delete organization", because it answers the same
/// question from the other side: how do I stop being in this. Joining takes a
/// second and used to be undoable only by asking an administrator — an
/// obligation that runs both ways should be endable by the person carrying it.
///
/// Absent for a sole owner. They cannot leave — an organization with no owner
/// cannot be administered or closed — and the action that fits them is the
/// deletion card shown in their place.
struct LeaveOrganizationCard: View {
    let organization: Organization
    let leave: () -> Void

    @State private var isConfirming = false

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-user",
                title: "Leave organization",
                subtitle: "You stop seeing anything shared with \(organization.name). Sessions you recorded here keep belonging to it."
            ) {
                Button("Leave…") {
                    isConfirming = true
                }
                .font(.system(size: 12.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.danger)
            }
        }
        .confirmationDialog(
            "Leave \(organization.name)?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive, action: leave)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "You go back to your personal space. Folders shared with you disappear from your sidebar. Getting back in needs a new invite."
            )
        }
    }
}
