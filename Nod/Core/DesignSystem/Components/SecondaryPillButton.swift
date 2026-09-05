import SwiftUI

/// The quiet pill beside a glass one — "Ask Nod" next to "Take action" — and,
/// with `isSelected` driven by state, a row of category tabs where only the
/// chosen one keeps its fill. What separates a tab from a pill is the fill,
/// not its measurements: there used to be a `Size` for it, and once both cases
/// sat on the grid they were the same component twice.
struct SecondaryPillButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, isSelected: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .textStyle(isSelected ? Theme.Typography.uiEmphasis : Theme.Typography.ui)
                .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.6))
                .padding(.horizontal, Theme.Space.x3)
                .padding(.vertical, Theme.Space.x1)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Theme.Palette.surfaceStrong : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Theme.Space.x3) {
        SecondaryPillButton("Ask Nod") {}
        HStack(spacing: Theme.Space.x2) {
            SecondaryPillButton("All", isSelected: true) {}
            SecondaryPillButton("Sales", isSelected: false) {}
            SecondaryPillButton("Product", isSelected: false) {}
        }
    }
    .padding(Theme.Space.x6)
    .background(Theme.Palette.bg)
}
