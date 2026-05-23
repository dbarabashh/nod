import SwiftUI

struct PermissionsStep: View {
    let strings: OnboardingStrings
    let onFinish: (_ skipped: Bool) -> Void

    @EnvironmentObject private var permissions: PermissionManager
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
                    .foregroundStyle(Theme.Palette.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 28)

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
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
                    icon: "rectangle.on.rectangle",
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
                    Image(systemName: "lock.shield")
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
                        onRelaunch: permissions.relaunch
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

            Spacer(minLength: 0)

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
    }

    private var allGranted: Bool {
        permissions.microphone == .authorized && permissions.screenRecording == .authorized
    }

    private var needsRelaunch: Bool {
        permissions.requestedScreenRecordingThisSession && permissions.screenRecording == .authorized
    }

    private var continueTint: AnyShapeStyle {
        if allGranted {
            return AnyShapeStyle(Theme.Gradients.buttonSuccess)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [Color.white.opacity(0.16), Color.white.opacity(0.09)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }

    private func requestMicrophone() {
        Task {
            pendingMic = true
            _ = await permissions.requestMicrophone()
            pendingMic = false
        }
    }

    private func requestScreenRecording() {
        Task {
            pendingScreen = true
            _ = await permissions.requestScreenRecording()
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
                .foregroundStyle(Theme.Palette.ink)
                .frame(width: 180)
                .padding(.vertical, 11)
                .background(Capsule(style: .continuous).fill(tint))
                .shadow(color: isPrimary ? Theme.Palette.cyan.opacity(0.3) : .clear, radius: 14, x: 0, y: 8)
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
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.cyan)

            Text(hint)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Button(action: onRelaunch) {
                Text(actionLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule(style: .continuous).fill(Theme.Gradients.buttonSuccess))
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
