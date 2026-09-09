import AppKit
import SwiftUI

/// Inviting somebody, as a thing you decide to do.
///
/// It used to be a text field, a role picker and a button welded to the top of
/// the roster — permanently on screen for a decision most people make a handful
/// of times, and pushing the list everybody actually came for further down. The
/// controls have room to be legible here, and the roster is a roster again.
struct InviteSheet: View {
    @ObservedObject var service: OrganizationService
    let membership: OrgMembership

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = OrgRole.member
    @State private var isSending = false
    @State private var sentTo: String?
    /// The sheet's own, rather than `service.lastError`: that slot is written by
    /// every organization operation, so a background refresh failing behind the
    /// sheet used to surface here as a failure to send.
    @State private var error: String?

    private var isAddressable: Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && !trimmed.hasSuffix("@")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SettingsRowDivider(indent: 0)
            form
            SettingsRowDivider(indent: 0)
            footer
        }
        .frame(width: 420)
        .background(Theme.Palette.bgSoft)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Invite to \(membership.organization.name)")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
            Text("The link only works for the address you send it to, so a forwarded invite opens nothing.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Email address")
                TextField("name@company.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit(send)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Role")
                SegmentedControl(
                    selection: $role,
                    options: service.grantableRoles(as: membership.role),
                    title: \.displayName
                )
                Text(roleExplanation)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let sentTo {
                confirmation(sentTo)
            }
            if let error {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    /// Named here rather than left to the role labels, because "Admin" and
    /// "Owner" look interchangeable until somebody has handed out the wrong one.
    private var roleExplanation: String {
        switch role {
        case .owner: "Full control, including closing the organization and changing anybody's role."
        case .admin: "Manages people, teams and which tools are allowed. Doesn't get to read what members recorded."
        case .member: "Records and shares their own sessions. No administration."
        }
    }

    /// Stays on screen after a send: a bounced email is the common failure and
    /// the link is the recovery, so it has to be reachable in the moment rather
    /// than found again in the roster.
    private func confirmation(_ address: String) -> some View {
        HStack(spacing: 10) {
            Image("nc-circle-check")
                .icon(13)
                .foregroundStyle(Theme.Palette.success)
            Text("Invited \(address)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 8)
            if let invite = service.pendingInvites.first(where: { $0.email == address }) {
                Button("Copy link") { NSPasteboard.copyText(invite.url) }
                    .font(.system(size: 12))
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .font(.system(size: 12.5))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.muted)
            GlassPillButton(isSending ? "Sending…" : "Send invite", size: .regular, shortcut: .defaultAction, action: send)
                .disabled(!isAddressable || isSending)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func send() {
        guard isAddressable, !isSending else { return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isSending = true
        error = nil
        Task {
            let sent = await service.invite(email: address, role: role, to: membership.id)
            isSending = false
            error = service.lastError
            guard sent else { return }
            sentTo = address
            email = ""
        }
    }
}
