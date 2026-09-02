import SwiftUI

/// The primary glass pill in the sizes the app draws it at: an inline form's
/// submit, a settings sheet's footer, a full-screen retry. Every fill, label
/// colour and border comes from `Theme.GlassButton`; only the measurements
/// change with the size.
struct GlassPillButton: View {
    enum Size {
        case compact
        // Only the sidebar's quick-start rows: a pill a half-point smaller so a
        // row with a "Start" stays the height of the rows without one.
        case row
        case regular
        case sheet
        case large

        var fontSize: CGFloat {
            switch self {
            case .compact: 12
            case .row: 11.5
            case .regular, .sheet: 12.5
            case .large: 13
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: 12
            case .row, .regular: 14
            case .sheet: 16
            case .large: 20
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .compact, .row: 5
            case .regular, .sheet: 8
            case .large: 9
            }
        }

        var iconSize: CGFloat {
            switch self {
            case .compact, .row: 8
            case .regular, .sheet: 10
            case .large: 11
            }
        }

        var iconSpacing: CGFloat {
            switch self {
            case .compact, .row: 4
            case .regular, .sheet, .large: 6
            }
        }
    }

    let title: String
    let size: Size
    let leadingIcon: String?
    let trailingIcon: String?
    let shortcut: KeyboardShortcut?
    let action: () -> Void

    init(
        _ title: String,
        size: Size = .regular,
        leadingIcon: String? = nil,
        trailingIcon: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.size = size
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.iconSpacing) {
                if let leadingIcon {
                    Image(leadingIcon).icon(size.iconSize)
                }
                Text(title)
                    .font(.system(size: size.fontSize, weight: .semibold))
                if let trailingIcon {
                    Image(trailingIcon).icon(size.iconSize)
                }
            }
            .foregroundStyle(Theme.GlassButton.text)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .glassButtonSurface(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        GlassPillButton("Create in Linear", size: .compact) {}
        GlassPillButton("Open NOD-12", size: .compact, trailingIcon: "nc-arrow-up-right") {}
        GlassPillButton("Start", size: .row) {}
        GlassPillButton("Invite people", leadingIcon: "nc-plus") {}
        GlassPillButton("Send invite", size: .sheet, shortcut: .defaultAction) {}
        GlassPillButton("Retry", size: .large) {}
        GlassPillButton("Disabled", size: .sheet) {}
            .disabled(true)
    }
    .padding(24)
    .background(Theme.Palette.bg)
}
