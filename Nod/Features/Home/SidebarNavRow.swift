import SwiftUI

enum SidebarRowTone {
    case standard
    /// A row that offers rather than goes somewhere — "Add project".
    case quiet
}

/// The look of one sidebar row, without the click: a 16pt leading slot, the
/// title with an optional second line, and whatever trails it, on a chip that
/// only shows while the row is the place you are.
///
/// Split from `SidebarNavRow` for the one row that cannot be a button — a chat
/// row's delete confirmation has to sit *beside* the row's hit area, not inside
/// it, or confirming a delete also opens the chat being deleted.
/// A sidebar row's own geometry, named so the row and the test that measures it
/// read the same numbers. `SidebarFitTests` used to carry its own copy and was
/// three points out of step the day it landed — which is the failure mode the
/// test exists to prevent, one level up.
enum SidebarRowMetrics {
    static let inset = Theme.Space.x2
    /// What a row spends before its title: its inset either side, the icon
    /// slot, and the gap after it.
    static let chrome = inset * 2 + Theme.Control.icon + Theme.Space.x2
}

struct SidebarRowLabel<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let tone: SidebarRowTone
    /// Two lines already give a row its height, so a row with a subtitle asks
    /// for less than the single-line default.
    let verticalPadding: CGFloat
    private let leading: Leading
    private let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        tone: SidebarRowTone = .standard,
        verticalPadding: CGFloat = 7,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isSelected = isSelected
        self.tone = tone
        self.verticalPadding = verticalPadding
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Space.x2) {
            leading
                .frame(width: Theme.Control.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .textStyle(isSelected ? Theme.Typography.uiEmphasis : Theme.Typography.ui)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SidebarRowMetrics.inset)
        .padding(.vertical, verticalPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
                .opacity(isSelected ? 1 : 0)
        )
        .contentShape(Rectangle())
    }

    private var tint: Color {
        if isSelected { return Theme.Palette.ink }
        return tone == .quiet ? Theme.Palette.muted : Theme.Palette.inkSecondary
    }
}

extension SidebarRowLabel where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        tone: SidebarRowTone = .standard,
        verticalPadding: CGFloat = 7,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            tone: tone,
            verticalPadding: verticalPadding,
            leading: leading
        ) { EmptyView() }
    }
}

/// One destination in the window's sidebar. Shared by the list above and the
/// footer band below, which used to hold two copies of the same seven modifiers.
struct SidebarNavRow<Leading: View, Trailing: View>: View {
    private let label: SidebarRowLabel<Leading, Trailing>
    private let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        tone: SidebarRowTone = .standard,
        verticalPadding: CGFloat = 7,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        label = SidebarRowLabel(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            tone: tone,
            verticalPadding: verticalPadding,
            leading: leading,
            trailing: trailing
        )
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(.plain)
    }
}

extension SidebarNavRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        isSelected: Bool = false,
        tone: SidebarRowTone = .standard,
        verticalPadding: CGFloat = 7,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> Leading
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            isSelected: isSelected,
            tone: tone,
            verticalPadding: verticalPadding,
            action: action,
            leading: leading
        ) { EmptyView() }
    }
}

extension SidebarNavRow where Leading == SidebarRowGlyph, Trailing == EmptyView {
    init(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) {
        self.init(title: title, isSelected: isSelected, action: action) { SidebarRowGlyph(icon) }
    }
}

/// The glyph a destination row leads with.
struct SidebarRowGlyph: View {
    let icon: String

    init(_ icon: String) {
        self.icon = icon
    }

    var body: some View {
        Image(icon).icon(12.5)
    }
}

#Preview {
    VStack(spacing: 2) {
        SidebarNavRow(title: "Today", icon: "nc-sparkle-3", isSelected: true, action: {})
        SidebarNavRow(title: "Memory", icon: "nc-layers-3", isSelected: false, action: {})
        SidebarNavRow(title: "Launch", subtitle: "3 sessions · 2h ago", verticalPadding: 5) {} leading: {
            Circle().fill(Theme.Palette.brand).frame(width: 8, height: 8)
        } trailing: {
            Image("nc-users").icon(10).foregroundStyle(Theme.Palette.muted)
        }
        SidebarNavRow(title: "Add project", tone: .quiet) {} leading: {
            Image("nc-plus").icon(11)
        }
        SidebarRowLabel(title: "What did I promise?", isSelected: true) {
            Image("nc-msgs").icon(11)
        }
    }
    .padding(10)
    .frame(width: HomeSidebar.width)
    .background(Theme.Palette.bg)
}
