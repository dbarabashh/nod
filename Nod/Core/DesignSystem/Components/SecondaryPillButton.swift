import SwiftUI

/// The quiet pill beside a glass one — "Ask Nod" next to "Take action" — and,
/// with `isSelected` driven by state, a row of category tabs where only the
/// chosen one keeps its fill.
struct SecondaryPillButton: View {
    enum Size {
        case compact
        case tab

        var horizontalPadding: CGFloat {
            switch self {
            case .compact: 11
            case .tab: 10
            }
        }
    }

    let title: String
    let size: Size
    let isSelected: Bool
    let action: () -> Void

    init(_ title: String, size: Size = .compact, isSelected: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.size = size
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.6))
                .padding(.horizontal, size.horizontalPadding)
                .padding(.vertical, 5)
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
    VStack(alignment: .leading, spacing: 12) {
        SecondaryPillButton("Ask Nod") {}
        HStack(spacing: 6) {
            SecondaryPillButton("All", size: .tab, isSelected: true) {}
            SecondaryPillButton("Sales", size: .tab, isSelected: false) {}
            SecondaryPillButton("Product", size: .tab, isSelected: false) {}
        }
    }
    .padding(24)
    .background(Theme.Palette.bg)
}
