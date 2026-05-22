import SwiftUI

struct PermissionsStep: View {
    let onFinish: (_ skipped: Bool) -> Void

    @EnvironmentObject private var permissions: PermissionManager
    @State private var pendingMic = false
    @State private var pendingScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant Permissions")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
                Text("Nod needs access to your microphone and system audio to record meetings. All processing happens locally.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
            }

            VStack(spacing: 10) {
                PermissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    description: "Capture what you say during the meeting.",
                    status: permissions.microphone,
                    isPending: pendingMic,
                    onEnable: requestMicrophone,
                    onOpenSettings: permissions.openMicrophoneSettings
                )

                PermissionRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    description: "Required to capture system audio from your meeting app.",
                    status: permissions.screenRecording,
                    isPending: pendingScreen,
                    onEnable: requestScreenRecording,
                    onOpenSettings: permissions.openScreenRecordingSettings
                )
            }

            if permissions.screenRecording == .denied {
                Text("If you just granted Screen Recording, you may need to restart the app for it to take effect.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, -4)
            }

            Spacer(minLength: 0)

            HStack {
                Button(action: { onFinish(true) }) {
                    Text("Skip for now")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { onFinish(false) }) {
                    Text(allGranted ? "Finish" : "Continue Anyway")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Capsule(style: .continuous).fill(continueTint))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(28)
    }

    private var allGranted: Bool {
        permissions.microphone == .authorized && permissions.screenRecording == .authorized
    }

    private var continueTint: LinearGradient {
        if allGranted {
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.75, blue: 0.50), Color(red: 0.25, green: 0.65, blue: 0.85)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.18), Color.white.opacity(0.10)],
            startPoint: .leading,
            endPoint: .trailing
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
