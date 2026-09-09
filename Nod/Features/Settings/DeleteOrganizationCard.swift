import SwiftUI

/// Closing the organization — an owner's action, and the only exit for a sole
/// one.
///
/// Kept at the foot of the pane and behind its own confirmation because it ends
/// access for everybody at once, which no other control here does.
struct DeleteOrganizationCard: View {
    let organization: Organization
    let delete: () -> Void

    var body: some View {
        DestructiveActionCard(
            icon: "nc-trash",
            title: "Delete organization",
            subtitle: "Everyone loses access. Sessions recorded here keep belonging to the organization and stay readable by whoever recorded them.",
            buttonTitle: "Delete…",
            dialogTitle: "Delete \(organization.name)?",
            dialogMessage: "Every member loses access immediately and goes back to their personal space. Pending invites stop working. This can't be undone from the app.",
            confirmTitle: "Delete organization",
            action: delete
        )
    }
}
