import SwiftUI

// MARK: - Settings row primitives

/// A rounded card grouping one or more `SettingsRow`s, separated by
/// `SettingsRowDivider`. Matches the grouped look used across the app.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard()
    }
}

/// The app's standard grouped-surface container: a translucent fill with a
/// hairline border at the card radius. Shared by every settings card.
extension View {
    func surfaceCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }
}

/// One setting: leading icon, title + subtitle, and a trailing control.
struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Hairline divider between rows in a `SettingsCard`, indented past the icon.
struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .overlay(Theme.Palette.border)
            .padding(.leading, 58)
    }
}
