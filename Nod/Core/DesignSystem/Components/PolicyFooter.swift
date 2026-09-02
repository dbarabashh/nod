import SwiftUI

enum EmailConsentLinks {
    /// `nod-landing` serves every policy under `/policies/…`; a bare `/privacy`
    /// is not a route.
    static let privacy = URL(string: "https://hellonod.app/policies/privacy")
        ?? URL(fileURLWithPath: "/")
}

/// The foot of a consent ask: the policy it is bound to on the left, and on the
/// right the way to decline beside the way to accept. Every ask says it the
/// same way so nobody has to re-read the row.
///
/// `onboarding` is the wide, fixed-width primary of the welcome sky, where the
/// link and "Not now" take the ink; `prompt` is the padded primary of a card
/// over the main window, where "Not now" is muted and the link keeps the
/// system's link colour.
struct PolicyFooter: View {
    enum Style {
        case onboarding
        case prompt
    }

    let primary: TitledAction
    var secondary: TitledAction?
    var isBusy = false
    var style: Style = .prompt

    var body: some View {
        HStack(spacing: 12) {
            link

            Spacer(minLength: 12)

            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(secondaryColor)
                    .disabled(isBusy)
                    .linkCursor()
            }

            Button(action: primary.action) {
                primaryLabel
                    .foregroundStyle(Theme.GlassButton.text)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
            .linkCursor()
        }
    }

    @ViewBuilder
    private var primaryLabel: some View {
        switch style {
        case .onboarding:
            Text(primary.title)
                .font(.system(size: 13.5, weight: .semibold))
                .frame(width: 150)
                .padding(.vertical, 10)
        case .prompt:
            Text(primary.title)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
    }

    /// The system's own link colour on a card; on the welcome sky it takes the
    /// ink, where an accent-blue link vanishes into the blue behind it.
    @ViewBuilder
    private var link: some View {
        let link = Link("Privacy policy", destination: EmailConsentLinks.privacy)
            .font(.system(size: 11.5, weight: .medium))
        switch style {
        case .onboarding: link.foregroundStyle(Theme.Palette.inkSecondary)
        case .prompt: link
        }
    }

    private var secondaryColor: Color {
        switch style {
        case .onboarding: Theme.Palette.inkSecondary
        case .prompt: Theme.Palette.muted
        }
    }
}

#Preview {
    VStack(spacing: 24) {
        PolicyFooter(primary: TitledAction("Finish setup") {}, secondary: TitledAction("Not now") {}, style: .onboarding)
        PolicyFooter(primary: TitledAction("Save choices") {}, secondary: TitledAction("Not now") {})
        PolicyFooter(primary: TitledAction("Continue") {})
    }
    .padding(24)
    .frame(width: 520)
    .background(WindowBackdrop())
}
