import SwiftUI

/// Three dots, one swelling at a time — "working on it", as a shape rather than
/// as punctuation.
///
/// It replaces the trailing "…" on the states that really are mid-flight. An
/// ellipsis is a typographic convention borrowed from menus, where it means "a
/// dialog follows"; on a progress line it is a still image pretending to be
/// motion. This moves, which is the whole claim it is making.
///
/// Written here rather than pulled in: the shape is a well-worn idiom, but the
/// obvious implementation of it on GitHub ships with no licence file at all, so
/// there is no grant to rely on and nothing to copy from.
struct ThreeBalls: View {
    var diameter: CGFloat = 4
    var color: Color = Theme.Palette.brand
    /// How long one dot holds its turn. The full cycle is three of these.
    var beat: TimeInterval = 0.28

    @State private var lit = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let count = 3
    /// How far the resting dots shrink. Far enough to read as a travelling
    /// pulse, not so far that the row looks like it is losing dots.
    private static let resting: CGFloat = 0.55

    var body: some View {
        HStack(spacing: diameter * 0.6) {
            ForEach(0 ..< Self.count, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: diameter, height: diameter)
                    .scaleEffect(scale(index))
                    .opacity(opacity(index))
            }
        }
        // Motion is the entire content, so with it off the row holds still at
        // full strength rather than animating faintly — a slower version of the
        // thing somebody asked not to see is not an accommodation.
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: beat)) {
                    lit = (lit + 1) % Self.count
                }
            }
        }
    }

    private func scale(_ index: Int) -> CGFloat {
        guard !reduceMotion else { return 1 }
        return index == lit ? 1 : Self.resting
    }

    private func opacity(_ index: Int) -> Double {
        guard !reduceMotion else { return 1 }
        return index == lit ? 1 : 0.45
    }
}

#Preview {
    HStack(spacing: 12) {
        Text("Looking for relevant context")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.Palette.ink)
        ThreeBalls()
    }
    .padding(24)
    .background(Theme.Palette.bg)
}
