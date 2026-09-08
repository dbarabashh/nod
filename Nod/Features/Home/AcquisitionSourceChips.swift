import SwiftUI

/// Where this person heard of Nod, as a row of chips: a tap is the answer.
/// Social and product chips carry the brand's mark; the two that are not a
/// product are words alone.
struct AcquisitionSourceChips: View {
    @Binding var selected: AcquisitionSource?

    var body: some View {
        WrapRow(spacing: 6) {
            ForEach(AcquisitionSource.asked) { source in
                SourceChip(
                    title: source.title,
                    brandImageName: source.brandImageName,
                    isSelected: source == selected
                ) {
                    selected = source
                }
            }
        }
    }
}

private struct SourceChip: View {
    let title: String
    let brandImageName: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    @ViewBuilder
    private var fill: some View {
        if isSelected {
            Capsule(style: .continuous).fill(Theme.GlassButton.fill)
        } else {
            Capsule(style: .continuous).fill(isHovered ? Theme.Palette.surfaceStrong.opacity(0.8) : Theme.Palette.surfaceStrong)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let brandImageName {
                    Image(brandImageName)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 13, height: 13)
                }
                Text(title)
                    .textStyle(Theme.Typography.uiEmphasis)
            }
            .foregroundStyle(isSelected ? Theme.GlassButton.text : Theme.Palette.ink)
            .padding(.leading, brandImageName == nil ? 12 : 10)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(fill)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Theme.Palette.overlay.opacity(isSelected ? 0 : 0.1), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview {
    AcquisitionSourceChips(selected: .constant(.reddit))
        .padding()
        .frame(width: 520)
}
