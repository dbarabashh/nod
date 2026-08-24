import SwiftUI

/// Shown on the way to Start when the recording wants system audio and macOS
/// hasn't given us Screen Recording.
///
/// Without it the capture begins anyway and quietly keeps only the user's own
/// microphone: `SCShareableContent` throws, `AudioCaptureService` files the
/// error into `systemAudioError`, and the user finds out at the recap that half
/// the call is missing. This is the one place that turns that into a question
/// they can answer.
struct SystemAudioAccessPrompt: View {
    @ObservedObject var permissions: PermissionManager
    let kind: SessionKind
    let onEnable: () -> Void
    let onRecordAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("nc-triangle-warning")
                    .icon(18)
                    .foregroundStyle(Theme.Palette.warning)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }

            Text(message)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.graphite)
                .fixedSize(horizontal: false, vertical: true)

            if permissions.requestedScreenRecordingThisSession {
                RelaunchCard(
                    hint: PermissionManager.relaunchHint,
                    actionLabel: "Relaunch",
                    failure: permissions.lastRelaunchError,
                    onRelaunch: permissions.relaunch
                )
            }

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: onRecordAnyway) {
                    Text(recordAnywayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.graphite)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Button(action: onEnable) {
                    Text(enableTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String {
        kind == .media ? "Nod can't hear this" : "Nod will only hear you"
    }

    private var message: String {
        kind == .media
            ? "Screen Recording is off, so Nod can't hear what's playing. It records speaker audio, not your screen."
            : "Screen Recording is off, so Nod hears only you. It records speaker audio, not your screen."
    }

    private var enableTitle: String {
        permissions.canPromptForScreenRecording ? "Enable Screen Recording" : "Open Settings"
    }

    private var recordAnywayTitle: String {
        kind == .media ? "Record anyway" : "Record me only"
    }
}

#Preview {
    SystemAudioAccessPrompt(
        permissions: PermissionManager(),
        kind: .meeting,
        onEnable: {},
        onRecordAnyway: {},
        onCancel: {}
    )
    .padding(20)
    .frame(width: 380)
    .background(Theme.Palette.surface)
}
