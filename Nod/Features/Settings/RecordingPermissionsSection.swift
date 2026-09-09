import SwiftUI

/// The two macOS grants a recording is built on, and what Nod loses without
/// each.
///
/// Onboarding used to be the only place that ever mentioned them, and it can be
/// walked past in two seconds. Someone who did that had no way left to find out
/// why their meetings only ever contained their own voice — a revoked grant
/// looked exactly like a working one from inside the app.
struct RecordingPermissionsSection: View {
    @ObservedObject var permissions: PermissionManager

    var body: some View {
        SettingsCard {
            SettingsRow(
                icon: "nc-mic",
                title: "Microphone",
                subtitle: micSubtitle
            ) {
                trailing(for: permissions.microphone, enable: requestMicrophone, openSettings: permissions.openMicrophoneSettings)
            }

            SettingsRowDivider()

            SettingsRow(
                icon: "nc-stack-perspective",
                title: "Screen Recording",
                subtitle: screenSubtitle
            ) {
                trailing(
                    for: permissions.screenRecording,
                    enable: requestScreenRecording,
                    openSettings: permissions.openScreenRecordingSettings
                )
            }

            // macOS hands a fresh grant to the next process, not to this one, so
            // the row above keeps reading "Not allowed" however many times it is
            // pressed. Without this the user is left toggling a switch in System
            // Settings that appears to do nothing.
            if permissions.requestedScreenRecordingThisSession, permissions.screenRecording != .authorized {
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-refresh-2",
                    title: "Restart to finish",
                    subtitle: permissions.relaunchMessage
                ) {
                    Button("Relaunch", action: permissions.relaunch)
                        .controlSize(.small)
                }
            }
        }
    }

    private var micSubtitle: String {
        permissions.microphone == .authorized
            ? "Nod records your own voice."
            : "Without it Nod records nothing you say."
    }

    private var screenSubtitle: String {
        permissions.screenRecording == .authorized
            ? "Nod records the other people on a call. It captures speaker audio, not your screen."
            : "Without it Nod hears only you, and calls come back missing everyone else."
    }

    @ViewBuilder
    private func trailing(
        for status: PermissionStatus,
        enable: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        switch status {
        case .authorized:
            HStack(spacing: 5) {
                Image("nc-check")
                    .icon(11)
                Text("Allowed")
                    .font(.system(size: 12))
            }
            .foregroundStyle(Theme.Palette.muted)
        case .notDetermined:
            Button("Allow", action: enable)
                .controlSize(.small)
        case .denied:
            Button("Open Settings", action: openSettings)
                .controlSize(.small)
        }
    }

    private func requestMicrophone() {
        Task { _ = await permissions.requestMicrophone() }
    }

    private func requestScreenRecording() {
        Task { _ = await permissions.requestScreenRecording() }
    }
}

#Preview {
    RecordingPermissionsSection(permissions: PermissionManager())
        .padding(20)
        .frame(width: 560)
        .background(Theme.Palette.surface)
}
