import SwiftUI

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let status: PermissionStatus
    let isPending: Bool
    let enableLabel: String
    let openSettingsLabel: String
    let grantedLabel: String
    let onEnable: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                                .stroke(Theme.Palette.border, lineWidth: 0.5)
                        )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(description)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            actionView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var actionView: some View {
        switch status {
        case .authorized:
            StatusBadge(text: grantedLabel, color: Theme.Palette.success)
        case .denied:
            ActionButton(title: openSettingsLabel, tint: AnyShapeStyle(Theme.Gradients.buttonBrand), action: onOpenSettings)
        case .notDetermined:
            ActionButton(
                title: enableLabel,
                tint: AnyShapeStyle(Theme.Gradients.buttonBrand),
                isPending: isPending,
                action: onEnable
            )
        }
    }
}

private struct ActionButton: View {
    let title: String
    let tint: AnyShapeStyle
    var isPending: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isPending {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(tint))
        }
        .buttonStyle(.plain)
        .disabled(isPending)
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(color.opacity(0.18)))
    }
}
