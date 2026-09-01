import SwiftUI

/// A tinted glyph and word — "Connected", "Turned off" — standing where a row's
/// control would otherwise be, for a state that needs no action.
struct StatusLabel: View {
    let icon: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(icon)
                .icon(10)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(tint)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        StatusLabel(icon: "nc-check", title: "Connected", tint: Theme.Palette.success)
        StatusLabel(icon: "nc-lock", title: "Turned off", tint: Theme.Palette.warning)
    }
    .padding(24)
    .background(Theme.Palette.bg)
}
