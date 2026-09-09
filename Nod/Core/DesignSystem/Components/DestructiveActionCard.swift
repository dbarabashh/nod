import SwiftUI

/// A settings card whose one control ends something — leaving, deleting — and
/// so asks again before it does. The row explains the consequence, the dialog
/// repeats it at the moment of commitment.
struct DestructiveActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let dialogTitle: String
    let dialogMessage: String
    let confirmTitle: String
    let action: () -> Void

    @State private var isConfirming = false

    var body: some View {
        SettingsCard {
            SettingsRow(icon: icon, title: title, subtitle: subtitle) {
                Button(buttonTitle) {
                    isConfirming = true
                }
                .font(.system(size: 12.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.danger)
            }
        }
        .confirmationDialog(dialogTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button(confirmTitle, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dialogMessage)
        }
    }
}

#Preview {
    DestructiveActionCard(
        icon: "nc-trash",
        title: "Delete organization",
        subtitle: "Everyone loses access.",
        buttonTitle: "Delete…",
        dialogTitle: "Delete Acme?",
        dialogMessage: "Every member loses access immediately.",
        confirmTitle: "Delete organization",
        action: {}
    )
    .padding(20)
    .frame(width: 520)
    .background(Theme.Palette.bg)
}
