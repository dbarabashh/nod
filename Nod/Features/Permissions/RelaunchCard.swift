import SwiftUI

/// "You granted it, macOS is holding it for the next launch."
///
/// Every surface that can ask for Screen Recording needs this: ScreenCaptureKit
/// only picks up a fresh TCC entry in a new process, so without it the user
/// flips the switch in System Settings, comes back, sees the same "not allowed"
/// row, and concludes Nod is broken. Owns the failure line as well as the hint
/// so the two sentences can't drift apart between callers.
struct RelaunchCard: View {
    let hint: String
    let actionLabel: String
    let failure: String?
    let onRelaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                Image("nc-refresh-2")
                    .icon(15)
                    .foregroundStyle(Theme.Palette.cyan)

                Text(hint)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.GlassButton.text.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(action: onRelaunch) {
                    Text(actionLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                    .fill(Theme.Palette.cyan.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                            .stroke(Theme.Palette.cyan.opacity(0.4), lineWidth: 0.6)
                    )
            )

            if let failure {
                Text(PermissionManager.relaunchFailureMessage(failure))
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

#Preview {
    RelaunchCard(
        hint: PermissionManager.relaunchHint,
        actionLabel: "Relaunch",
        failure: nil,
        onRelaunch: {}
    )
    .padding(20)
    .frame(width: 420)
    .background(Theme.Palette.surface)
}
