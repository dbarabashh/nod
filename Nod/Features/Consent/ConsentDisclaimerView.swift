import SwiftUI

/// Pre-first-meeting consent disclaimer, shown as a state of the notch surface.
///
/// Paints only its content: the notch is the card, and a second card drawn
/// inside it would read as a dialog floating in a dialog.
struct ConsentDisclaimerView: View {
    let strings: ConsentStrings
    let onCancel: () -> Void
    /// Called with `dontShowAgain == true` when the user wants the consent
    /// to be persisted, false when they want the modal to reappear next
    /// time they start a meeting.
    let onAcknowledge: (_ dontShowAgain: Bool) -> Void

    @State private var dontShowAgain: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("nc-shield-check")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.warning)
                Text(strings.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }

            Text(strings.body)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $dontShowAgain) {
                Text(strings.dontShowAgain)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.9))
            }
            .toggleStyle(.checkbox)

            HStack {
                Button(action: onCancel) {
                    Text(strings.cancel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Spacer(minLength: 0)

                Button(action: { onAcknowledge(dontShowAgain) }) {
                    Text(strings.acknowledge)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .contentShape(Rectangle())
    }
}
