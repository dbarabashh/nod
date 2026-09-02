import SwiftUI

/// A small quiet pill beside a row's title — a capability, a category. Says
/// what kind of thing this is, never its state.
struct TagPill: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Theme.Palette.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.Palette.surfaceStrong))
    }
}

#Preview {
    HStack(spacing: 7) {
        Text("Linear")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.Palette.ink)
        TagPill("Tasks")
        TagPill("Productivity")
    }
    .padding(20)
    .background(Theme.Palette.bg)
}
