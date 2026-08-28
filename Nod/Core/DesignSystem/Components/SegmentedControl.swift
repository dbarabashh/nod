import SwiftUI

/// Segmented control in our own palette. `.pickerStyle(.segmented)` paints its
/// selection with the macOS system accent — blue on a default Mac — which is
/// off-palette everywhere in Nod and doesn't match the violet-tinted switches it
/// sits beside in Settings.
struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    var animation: Animation = .easeOut(duration: 0.18)

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                // A `Button`, not a tap gesture: a gesture is invisible to
                // VoiceOver and to Full Keyboard Access, so the segments were
                // reachable by mouse alone.
                Button {
                    select(option)
                } label: {
                    Text(title(option))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.muted)
                        // A segment narrower than its word wrapped it —
                        // "Weekd/ays" under a pill sized for one line.
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.Palette.surfaceStrong)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    private func select(_ option: Value) {
        guard selection != option else { return }
        withAnimation(reduceMotion ? nil : animation) { selection = option }
    }
}

#Preview {
    struct Harness: View {
        @State private var choice = "Notch"

        var body: some View {
            SegmentedControl(selection: $choice, options: ["Notch", "Floating panel"]) { $0 }
                .frame(width: 190)
                .padding()
                .background(Theme.Palette.bg)
        }
    }
    return Harness()
}
