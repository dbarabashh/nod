import SwiftUI

/// Raised after a stretch of silence on both streams: asks whether the meeting
/// is over. Ignored, the session auto-ends (trimmed back to the last speech)
/// when the countdown elapses, so a user who walked away doesn't record hours of
/// dead air. "Keep recording" is the prominent action, because the user who is
/// still here is the one who has to act.
struct InactivityPrompt: View {
    let prompt: AutoEndPrompt
    /// Kind-aware "keep going" label (e.g. "Keep listening") — never "recording".
    let keepTitle: String
    let onKeep: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(prompt.icon)
                .icon(12)
                .foregroundStyle(Theme.Palette.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text(prompt.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(prompt.detail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }

            Spacer(minLength: 8)

            Button(action: onEnd) {
                Text("End")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.pressable)

            NotchActionButton(title: keepTitle, action: onKeep)
        }
    }
}

/// A meeting that couldn't be pushed to the server. Retryable rather than fatal:
/// the transcript is already in the durable outbox, so this is about telling the
/// user their recap is late, not that it is lost.
struct SaveErrorToast: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image("nc-triangle-warning")
                .icon(12)
                .foregroundStyle(Theme.Palette.warning)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(2)

            Spacer(minLength: 8)

            if canRetry {
                NotchActionButton(title: "Retry", action: onRetry)
            }

            NotchGlyphButton(icon: "nc-xmark", help: "Dismiss", action: onDismiss)
        }
    }
}

/// The running build is below the server's `minimum_build` — a backend change
/// has made this version unusable. Shown as the notch's top-priority state
/// because it has to block a capture from starting, and the notch is the only
/// thing standing between the user and one.
struct UpdateRequiredNotice: View {
    let onUpdate: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image("nc-circle-arrow-down")
                .icon(20)
                .foregroundColor(DesignTokens.Palette.electricBlue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Update to keep using Nod")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Theme.Palette.ink)
                Text("This version is out of date. Your sessions are saved to your account — nothing is lost.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            NotchActionButton(title: "Update", action: onUpdate)
        }
    }
}
