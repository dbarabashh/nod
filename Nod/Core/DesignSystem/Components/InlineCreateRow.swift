import SwiftUI

/// A settings row that makes one new thing: a name and the button that
/// creates it, live only once there is a name to give.
struct InlineCreateRow: View {
    let prompt: String
    @Binding var text: String
    let buttonTitle: String
    var isBusy = false
    let action: () -> Void

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isBlank || isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

#Preview {
    SettingsCard {
        InlineCreateRow(prompt: "Team name", text: .constant(""), buttonTitle: "Add team", action: {})
        SettingsRowDivider()
        InlineCreateRow(prompt: "Organization name", text: .constant("Acme"), buttonTitle: "Create", action: {})
    }
    .padding(20)
    .frame(width: 520)
    .background(Theme.Palette.bg)
}
