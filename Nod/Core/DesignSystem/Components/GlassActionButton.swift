import SwiftUI

/// The single call to action at the foot of a surface: a label, a corner arrow,
/// and the glass capsule the app uses for anything that leaves the screen it is
/// on.
///
/// Written once because it had been written twice — the day's briefing and the
/// scripted demo of it sat in the two branches of the same route and drew the
/// same nine lines each, which is exactly how two versions of one button end up
/// disagreeing about a padding.
struct GlassActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Image("nc-arrow-up-right")
                    .icon(9)
            }
            .foregroundStyle(Theme.GlassButton.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassButtonSurface(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    GlassActionButton(title: "Review every open action") {}
        .padding(24)
        .background(Theme.Palette.bg)
}
