import SwiftUI

// MARK: - Update required

/// Blocking screen shown when the running build is below the server
/// `minimum_build` — a backend change has made this version unusable, so the
/// only path forward is to update. Covers the whole panel and eats input.
struct UpdateRequiredOverlay: View {
    let onUpdate: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundColor(DesignTokens.Palette.electricBlue)
                Text("Update to keep using Nod")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(
                    "This version is out of date. Update to the latest to keep recording and summarizing — your meetings are saved to your account, so nothing is lost."
                )
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                Button(action: onUpdate) {
                    Text("Update & Relaunch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.GlassButton.text)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: 280)
            .background(
                ZStack {
                    PanelMaterial()
                    Color.black.opacity(0.25)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            )
            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 8)
            .padding(16)
        }
    }
}

// MARK: - Update banner

/// Dismissible nudge for a build below `recommended_build` but still usable.
struct UpdateBanner: View {
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(DesignTokens.Palette.electricBlue)
            Text("A new version of Nod is available")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("Update", action: onUpdate)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DesignTokens.Palette.electricBlue)
                .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ZStack {
                PanelMaterial()
                Color.black.opacity(0.18)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

// MARK: - Save error toast

struct SaveErrorToast: View {
    let message: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)

            Text(message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(2)

            Spacer(minLength: 8)

            if canRetry {
                Button(action: onRetry) {
                    Text("Retry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.Palette.muted)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(
            ZStack {
                PanelMaterial()
                Theme.Palette.bgSoft.opacity(0.50)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }
}

// MARK: - Inactivity (forgot-to-stop) prompt

/// Raised after a stretch of silence on both streams: asks whether the meeting
/// is over. If ignored, the session auto-ends (trimmed to the last speech) when
/// the countdown elapses — so a walked-away user doesn't record hours of dead
/// air. "Keep recording" is the prominent action for a user who's still here.
struct InactivityPrompt: View {
    let secondsRemaining: Int
    /// Kind-aware "keep going" label (e.g. "Keep listening") — never "recording".
    let keepTitle: String
    let onKeep: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.warning)

            VStack(alignment: .leading, spacing: 1) {
                Text("Still there?")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("No audio for a while — ending in \(Self.clock(secondsRemaining))")
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
            .buttonStyle(.plain)

            Button(action: onKeep) {
                Text(keepTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 480)
        .background(
            ZStack {
                PanelMaterial()
                Theme.Palette.bgSoft.opacity(0.50)
            }
            .clipShape(Capsule(style: .continuous))
        )
        .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)
    }

    private static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
