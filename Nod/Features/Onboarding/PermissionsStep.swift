import SwiftUI

struct PermissionsStep: View {
    let strings: OnboardingStrings
    let onFinish: (_ skipped: Bool) -> Void

    @EnvironmentObject private var permissions: PermissionManager
    @EnvironmentObject private var telemetry: OnboardingTelemetry
    @State private var pendingMic = false
    @State private var pendingScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(strings.permissionsTitle)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(strings.permissionsSubtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 28)

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "nc-mic",
                    title: strings.micTitle,
                    description: strings.micDescription,
                    status: permissions.microphone,
                    isPending: pendingMic,
                    enableLabel: strings.actionEnable,
                    openSettingsLabel: strings.actionOpenSettings,
                    grantedLabel: strings.statusGranted,
                    onEnable: requestMicrophone,
                    onOpenSettings: permissions.openMicrophoneSettings
                )

                PermissionRow(
                    icon: "nc-stack-perspective",
                    title: strings.screenTitle,
                    description: strings.screenDescription,
                    status: permissions.screenRecording,
                    isPending: pendingScreen,
                    enableLabel: strings.actionEnable,
                    openSettingsLabel: strings.actionOpenSettings,
                    grantedLabel: strings.statusGranted,
                    onEnable: requestScreenRecording,
                    onOpenSettings: permissions.openScreenRecordingSettings
                )
            }

            // Pre-emptive copy lives here as one quiet line, not a banner.
            // Hidden once the user has granted SR or asked us to skip it.
            if permissions.screenRecording != .authorized {
                HStack(spacing: 6) {
                    Image("nc-shield-check")
                        .icon(10.5)
                    Text(strings.screenPreemptiveBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .padding(.top, 14)
                .padding(.horizontal, 2)
            }

            if needsRelaunch {
                RelaunchCard(
                    hint: strings.actionRelaunchHint,
                    actionLabel: strings.actionRelaunch,
                    failure: permissions.lastRelaunchError,
                    onRelaunch: {
                        Task {
                            await telemetry.relaunchClicked()
                            permissions.relaunch()
                        }
                    }
                )
                .padding(.top, 16)
            }

            HStack {
                Button(action: { onFinish(true) }) {
                    Text(strings.actionSkip)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.inkSecondary)
                }
                .buttonStyle(.plain)

                Spacer()

                ContinueButton(
                    label: allGranted ? strings.actionContinue : strings.actionContinueAnyway,
                    isPrimary: allGranted,
                    tint: continueTint,
                    action: { onFinish(false) }
                )
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: needsRelaunch) { needed in
            if needed { telemetry.relaunchPrompted() }
        }
        .onChange(of: permissions.lastRelaunchError) { error in
            if let error { telemetry.relaunchFailed(error) }
        }
    }

    private var allGranted: Bool {
        permissions.microphone == .authorized && permissions.screenRecording == .authorized
    }

    /// Shown as soon as we've asked — not only once the grant is visible. A TCC
    /// entry added while this process runs stays invisible to it, so "did that
    /// work?" is a question only a fresh process can answer. Gating the card on
    /// `.authorized` meant it never appeared for anyone.
    private var needsRelaunch: Bool {
        permissions.requestedScreenRecordingThisSession
    }

    private var continueTint: AnyShapeStyle {
        if allGranted {
            return AnyShapeStyle(Theme.Gradients.buttonBrand)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color.white.opacity(0.5), Color.white.opacity(0.4)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func requestMicrophone() {
        Task {
            pendingMic = true
            telemetry.permissionRequested(.microphone)
            let granted = await permissions.requestMicrophone()
            telemetry.permissionResolved(.microphone, granted: granted)
            pendingMic = false
        }
    }

    private func requestScreenRecording() {
        Task {
            pendingScreen = true
            telemetry.permissionRequested(.screenRecording)
            switch await permissions.requestScreenRecording() {
            case .authorized:
                telemetry.permissionResolved(.screenRecording, granted: true)
            case .pendingRelaunch:
                telemetry.screenRecordingPendingRelaunch()
            }
            pendingScreen = false
        }
    }
}

/// Continue/Continue-Anyway button. Default-action shortcut binds only when
/// permissions are actually granted — Enter shouldn't silently bypass missing
/// mic/screen access.
private struct ContinueButton: View {
    let label: String
    let isPrimary: Bool
    let tint: AnyShapeStyle
    let action: () -> Void

    var body: some View {
        Group {
            if isPrimary {
                button.keyboardShortcut(.defaultAction)
            } else {
                button
            }
        }
    }

    private var button: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.GlassButton.text)
                .frame(width: 180)
                .padding(.vertical, 11)
                .background(Capsule(style: .continuous).fill(tint))
                .shadow(color: isPrimary ? Color.black.opacity(0.22) : .clear, radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
    }
}
