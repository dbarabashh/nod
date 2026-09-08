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
struct PolicyFooter: View {
    let primary: TitledAction
    var secondary: TitledAction?
    var isBusy = false

    var body: some View {
        HStack(spacing: 12) {
            link

            Spacer(minLength: 12)

            if let secondary {
                Button(secondary.title, action: secondary.action)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .disabled(isBusy)
                    .linkCursor()
            }

            Button(action: primary.action) {
                Text(primary.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .foregroundStyle(Theme.GlassButton.text)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy)
            .linkCursor()
        }
    }

    private var link: some View {
        Link("Privacy policy", destination: EmailConsentLinks.privacy)
            .font(.system(size: 11.5, weight: .medium))
    }
}

#Preview {
    VStack(spacing: 24) {
        PolicyFooter(primary: TitledAction("Save choices") {}, secondary: TitledAction("Not now") {})
        PolicyFooter(primary: TitledAction("Continue") {})
    }
    .padding(24)
    .frame(width: 520)
    .background(WindowBackdrop())
}
