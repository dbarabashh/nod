import SwiftUI

/// One choosable context in the switcher.
///
/// A struct rather than a helper method because the row owns hover state, and a
/// `some View` helper cannot hold any.
///
/// Selection is the surface itself — fill plus a hairline border — with no tick
/// beside it. Once the row is visibly chosen the mark restates what the shape
/// already says, and it was the one thin glyph on a card of heavier type. Safe
/// for `differentiateWithoutColor` because the signal is a fill, not a hue;
/// VoiceOver hears it from the `.isSelected` trait below, which is where that
/// belongs anyway.
struct ContextRow: View {
    let title: String
    let subtitle: String
    /// The name to take an initial from. `nil` is the personal context, which
    /// gets a person rather than a letter — it is not one organization among
    /// several, it is the absence of one.
    let monogram: String?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radii.chip)
                    .stroke(isSelected ? Theme.Palette.borderStrong : .clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: Color {
        if isSelected { return Theme.Palette.surfaceStrong }
        return isHovering ? Theme.Palette.surface : .clear
    }

    @ViewBuilder
    private var badge: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip)
        ZStack {
            shape.fill(isSelected ? Theme.Palette.surfaceStrong : Theme.Palette.surface)
            shape.stroke(Theme.Palette.border, lineWidth: 0.5)
            if let monogram, let initial = monogram.trimmingCharacters(in: .whitespaces).first {
                Text(String(initial).uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            } else {
                Image("nc-user")
                    .icon(12)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}
