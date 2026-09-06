import SwiftUI

/// The primary glass pill in the sizes the app draws it at: an inline form's
/// submit, a settings sheet's footer, a full-screen retry. Every fill, label
/// colour and border comes from `Theme.GlassButton`; only the measurements
/// change with the size.
struct GlassPillButton: View {
    enum Size {
        case compact
        case regular
        case large

        var style: Theme.TextStyle {
            self == .compact ? Theme.Typography.secondary : Theme.Typography.uiEmphasis
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: Theme.Space.x3
            case .regular: Theme.Space.x4
            case .large: Theme.Space.x6
            }
        }

        /// One value for the padding above and below and for the gap after the
        /// icon — they were two switches over the same cases returning the same
        /// numbers, which is one decision written twice.
        var innerSpacing: CGFloat {
            self == .compact ? Theme.Space.x1 : Theme.Space.x2
        }
    }

    let title: String
    let size: Size
    let leadingIcon: String?
    let trailingIcon: String?
    let shortcut: KeyboardShortcut?
    /// Shows a spinner before the title and refuses presses while true. The
    /// label stays, so the button keeps its name for VoiceOver and its width.
    let isLoading: Bool
    let tint: GlassButtonTint
    let action: () -> Void

    init(
        _ title: String,
        size: Size = .regular,
        leadingIcon: String? = nil,
        trailingIcon: String? = nil,
        shortcut: KeyboardShortcut? = nil,
        isLoading: Bool = false,
        tint: GlassButtonTint = .ink,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.size = size
        self.leadingIcon = leadingIcon
        self.trailingIcon = trailingIcon
        self.shortcut = shortcut
        self.isLoading = isLoading
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.innerSpacing) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(tint.text)
                } else if let leadingIcon {
                    Image(leadingIcon).icon(Theme.Control.iconMicro)
                }
                Text(title)
                    .textStyle(size.style.weight(.semibold))
                if let trailingIcon {
                    Image(trailingIcon).icon(Theme.Control.iconMicro)
                }
            }
            .foregroundStyle(tint.text)
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.innerSpacing)
            .glassButtonSurface(Capsule(style: .continuous), tint: tint)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .disabled(isLoading)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        GlassPillButton("Create in Linear", size: .compact) {}
        GlassPillButton("Open NOD-12", size: .compact, trailingIcon: "nc-arrow-up-right") {}
        GlassPillButton("Start", size: .compact) {}
        GlassPillButton("Invite people", leadingIcon: "nc-plus") {}
        GlassPillButton("Send invite", size: .regular, shortcut: .defaultAction) {}
        GlassPillButton("Add 1 000 · 10 US$", size: .compact, tint: .brand) {}
        GlassPillButton("Retry", size: .large) {}
        GlassPillButton("Disabled", size: .regular) {}
            .disabled(true)
        GlassPillButton("Opening checkout", size: .compact, isLoading: true) {}
    }
    .padding(24)
    .background(Theme.Palette.bg)
}
