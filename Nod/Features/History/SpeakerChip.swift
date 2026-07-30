import SwiftUI

/// Who said a transcript line. While diarization and the naming pass are still
/// deciding, it shows a placeholder instead of a label: in that window the same
/// row reads `Them`, then `Speaker 2`, then `Eric`, and text that rewrites
/// itself under the reader looks like a bug rather than progress.
struct SpeakerChip: View {
    let label: String
    let tint: Color
    let isResolving: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        chip
            // The label also changes without the view changing — `Speaker 2`
            // becomes a name — and a hard text swap is the same glitch in
            // miniature.
            .contentTransition(.opacity)
            .animation(.standard(reduceMotion: reduceMotion), value: isResolving)
            .animation(.standard(reduceMotion: reduceMotion), value: label)
    }

    /// Redacting the real chip rather than drawing a stand-in capsule: same
    /// typography, same padding, so the row doesn't reflow when the answer
    /// lands on top of it.
    private var chip: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.4)
            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule(style: .continuous).fill(tint))
            .redacted(reason: isResolving ? .placeholder : [])
            .opacity(isResolving ? pulseOpacity : 1)
            // A slow oscillation reads as calm rather than nagging, but past
            // ~5s per cycle it reads as a rendering fault — so, a heartbeat.
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = isResolving }
            .onChange(of: isResolving) { pulsing = $0 }
            .accessibilityLabel(isResolving ? "Identifying who is speaking" : label)
    }

    private var pulseOpacity: Double {
        guard !reduceMotion else { return 0.5 }
        return pulsing ? 0.75 : 0.35
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 14) {
        SpeakerChip(label: "Them", tint: Theme.Palette.cyan.opacity(0.18), isResolving: true)
        SpeakerChip(label: "Them · Speaker 2", tint: Theme.Palette.cyan.opacity(0.18), isResolving: false)
        SpeakerChip(label: "Eric Johnson", tint: Theme.Palette.cyan.opacity(0.18), isResolving: false)
        SpeakerChip(label: "Me", tint: Theme.Palette.violet.opacity(0.18), isResolving: false)
    }
    .padding(24)
    .background(Theme.Palette.surface)
}
