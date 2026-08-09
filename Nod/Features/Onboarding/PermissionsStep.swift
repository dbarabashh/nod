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
                    .foregroundStyle(Theme.GlassButton.text)
                Text(strings.permissionsSubtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
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
                        .font(.system(size: 10.5, weight: .medium))
                    Text(strings.screenPreemptiveBody)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
                .padding(.top, 14)
                .padding(.horizontal, 2)
            }

            if needsRelaunch {
                VStack(alignment: .leading, spacing: 6) {
                    RelaunchCard(
                        hint: strings.actionRelaunchHint,
                        actionLabel: strings.actionRelaunch,
                        onRelaunch: {
                            Task {
                                await telemetry.relaunchClicked()
                                permissions.relaunch()
                            }
                        }
                    )
                    if let relaunchError = permissions.lastRelaunchError {
                        Text("Couldn't relaunch automatically (\(relaunchError)). Please quit Nod and reopen it manually.")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(Theme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 2)
                    }
                }
                .padding(.top, 16)
            }

            HStack {
                Button(action: { onFinish(true) }) {
                    Text(strings.actionSkip)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
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

private struct RelaunchCard: View {
    let hint: String
    let actionLabel: String
    let onRelaunch: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("nc-refresh-2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.cyan)

            Text(hint)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.GlassButton.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onRelaunch) {
                Text(actionLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                .fill(Theme.Palette.cyan.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radii.surface, style: .continuous)
                        .stroke(Theme.Palette.cyan.opacity(0.4), lineWidth: 0.6)
                )
        )
    }
}
