import SwiftUI

/// Inline confirm/cancel pair for in-place destructive confirms (delete label,
/// clear chat history) — a danger-filled circle next to a neutral surface
/// circle, no modal or alert. The prompt label stays at the call site since its
/// wording differs.
struct InlineConfirmButtons: View {
    let confirmIcon: String
    let confirmHelp: String
    let cancelHelp: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onConfirm) {
                Image(systemName: confirmIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.Palette.danger))
            }
            .buttonStyle(.plain)
            .help(confirmHelp)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.Palette.surface))
                    .overlay(Circle().stroke(Theme.Palette.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(cancelHelp)
        }
    }
}
