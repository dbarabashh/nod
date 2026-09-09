import SwiftUI

// MARK: - Grouped-surface row primitives

//
// In `Core/` rather than `Features/Settings/` despite the names: the shape
// started there, but `ToolApprovalCard` and the getting-started checklist draw
// it too, and `Core` may not reach into a feature to get it.

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

/// How much a card wants to be looked at. `strong` is for the one card on a
/// screen that leads — the same shape, a step further forward.
enum SurfaceEmphasis {
    case standard
    case strong

    var fill: Color {
        self == .strong ? Theme.Palette.surfaceStrong : Theme.Palette.surface
    }

    var stroke: Color {
        self == .strong ? Theme.Palette.borderStrong : Theme.Palette.border
    }
}

/// The app's standard grouped-surface container: a translucent fill with a
/// hairline border at the card radius. Shared by every settings card.
extension View {
    func surfaceCard(emphasis: SurfaceEmphasis = .standard) -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(emphasis.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                        .stroke(emphasis.stroke, lineWidth: 0.5)
                )
        )
    }
}

/// One row: something on the left, title + subtitle, and a trailing control.
///
/// The leading view is generic because the three surfaces that draw this row
/// disagree about it and about nothing else — settings puts the glyph in a
/// chip, the calendar step shows a product's own mark, the checklist shows a
/// bare glyph that turns into a tick. Everything to the right of it is the same
/// row, and was being hand-copied to change that one corner.
struct SettingsRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    var titleStyle: TitleStyle = .standard
    /// `muted` is opaque slate, tuned for the app's own dark surfaces. A row on
    /// a coloured ground — the welcome sky — needs the subtitle to be the ink at
    /// reduced weight instead, or it sinks into the background.
    var subtitleTone: SettingsSubtitleTone = .muted
    var alignment: VerticalAlignment = .center
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    enum TitleStyle {
        case standard
        /// A finished checklist row: the title is struck through and steps
        /// back, and the subtitle is dropped — it was instructions for
        /// something already done.
        case done
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            leading()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(titleStyle == .done ? Theme.Palette.muted : Theme.Palette.ink)
                    .strikethrough(titleStyle == .done)
                if let subtitle, titleStyle != .done {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(subtitleTone.color)
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

extension SettingsRow where Leading == SettingsRowIcon {
    /// The settings shape: the glyph in its chip. What 50-odd call sites want,
    /// and the reason the generic form has this shorthand.
    init(
        icon: String,
        title: String,
        subtitle: String?,
        subtitleTone: SettingsSubtitleTone = .muted,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            subtitleTone: subtitleTone,
            leading: { SettingsRowIcon(icon) },
            trailing: trailing
        )
    }
}

enum SettingsSubtitleTone {
    case muted
    case secondary

    var color: Color {
        self == .muted ? Theme.Palette.muted : Theme.Palette.inkSecondary
    }
}

/// The chip a settings row draws its glyph in.
struct SettingsRowIcon: View {
    let icon: String

    init(_ icon: String) {
        self.icon = icon
    }

    var body: some View {
        Image(icon)
            .icon(14)
            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
            )
    }
}

/// Hairline divider between rows in a `SettingsCard`, indented past the icon.
/// The inset is a parameter because a row with a smaller leading view leaves
/// the default starting past its own title.
struct SettingsRowDivider: View {
    var indent: CGFloat = 58

    var body: some View {
        Divider()
            .overlay(Theme.Palette.border)
            .padding(.leading, indent)
    }
}

/// The "nothing here yet" line inside a `SettingsCard`, aligned with its rows.
struct SettingsEmptyRow: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
    }
}
