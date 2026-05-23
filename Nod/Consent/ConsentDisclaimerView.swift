import SwiftUI

/// Pre-first-meeting consent disclaimer. Overlay-style modal (not a Sheet —
/// FloatingPanel is a non-activating panel and sheets misbehave attached to
/// the system keyWindow). Rendered as a full-panel ZStack overlay by the
/// caller; this view only paints the centred card + backdrop.
struct ConsentDisclaimerView: View {
    let strings: ConsentStrings
    let onCancel: () -> Void
    /// Called with `dontShowAgain == true` when the user wants the consent
    /// to be persisted, false when they want the modal to reappear next
    /// time they start a meeting.
    let onAcknowledge: (_ dontShowAgain: Bool) -> Void

    @State private var dontShowAgain: Bool = true

    var body: some View {
        // No backdrop — the floating panel is non-activating, so a full
        // black-fill behind the card looks like a heavy iOS sheet rather
        // than a discreet macOS overlay. Hit-testing for the underlying
        // controls is gated by the parent ContentView (`allowsHitTesting`).
        card
            .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.shield.fill")
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
                        .foregroundStyle(Theme.Palette.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonBrand))
                        .shadow(color: Theme.Palette.pink.opacity(0.3), radius: 12, x: 0, y: 6)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.bgSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                        .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
                )
        )
        // Explicit hit-test so taps inside the card body don't risk falling
        // through to anything underneath (defence in depth even though the
        // backdrop no longer cancels on tap).
        .contentShape(Rectangle())
        .shadow(color: Color.black.opacity(0.4), radius: 24, x: 0, y: 12)
    }
}
