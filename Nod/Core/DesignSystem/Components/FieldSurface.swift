import SwiftUI

/// The app's own text-field chrome, replacing `.roundedBorder`'s AppKit bezel
/// and blue focus ring: a chip-radius surface whose hairline firms up when the
/// field has focus.
extension View {
    func fieldSurface(focused: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .stroke(
                            focused ? Theme.Palette.borderStrong : Theme.Palette.border,
                            lineWidth: focused ? 1 : 0.5
                        )
                )
        )
    }
}

#Preview {
    VStack(spacing: 12) {
        TextField("Project name", text: .constant(""))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .fieldSurface(focused: false)
        TextField("Project name", text: .constant("Focused"))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .fieldSurface(focused: true)
    }
    .padding(20)
    .frame(width: 320)
    .background(WindowBackdrop())
}
