import SwiftUI

/// One destination in the window's sidebar. Shared by the list above and the
/// footer band below, which used to hold two copies of the same seven modifiers.
struct SidebarNavRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    /// How much is waiting behind this destination. Nil, or zero, draws nothing.
    var badge: Int?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(icon)
                    .icon(12.5)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Spacer(minLength: 0)
                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }
            .foregroundStyle(isSelected ? Theme.Palette.ink : Theme.Palette.ink.opacity(0.72))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                    .fill(Theme.Palette.surfaceStrong)
                    .opacity(isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
