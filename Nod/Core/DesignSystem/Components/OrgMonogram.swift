import SwiftUI

/// The square initial that stands for an organization or a person.
///
/// `nil` — or a name with no letter in it — falls back to a person glyph, which
/// is what the personal context is: not one organization among several, the
/// absence of one.
struct OrgMonogram: View {
    let name: String?
    var size: CGFloat = 24
    /// An outline rather than a filled tile, for somebody who has only been
    /// invited. The difference is legible before the words are read.
    var isMuted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
        ZStack {
            shape.fill(isMuted ? .clear : Theme.Palette.surfaceStrong)
            shape.stroke(Theme.Palette.border, lineWidth: 0.5)
            if let initial {
                Text(initial)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(isMuted ? Theme.Palette.muted : Theme.Palette.ink)
            } else {
                Image("nc-user")
                    .icon(size * 0.46)
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initial: String? {
        guard let first = name?.trimmingCharacters(in: .whitespaces).first else { return nil }
        return String(first).uppercased()
    }
}

#Preview {
    HStack(spacing: 12) {
        OrgMonogram(name: "Acme", size: 32)
        OrgMonogram(name: nil)
        OrgMonogram(name: "dima@acme.com", size: 26, isMuted: true)
    }
    .padding()
    .background(Theme.Palette.bg)
}
