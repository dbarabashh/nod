import SwiftUI

/// The role a member holds, and what the viewer may do about it.
///
/// The menu offers only what the server would accept — role changes to owners,
/// removal to owners and administrators — because an action that exists in the
/// interface and fails on use teaches people not to trust the interface. The
/// database still refuses independently; this only keeps the two in agreement.
struct MemberActions: View {
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
