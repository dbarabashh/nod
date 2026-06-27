import SwiftUI

struct StatusRow: View {
    let meeting: MeetingState
    let micMuted: Bool
    var showMic: Bool = true
    let onRecordToggle: () -> Void
    let onMicToggle: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(action: onRecordToggle) {
                Image(systemName: meeting == .paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(meeting == .paused
                        ? Theme.Palette.controlResume
                        : .white.opacity(0.85))
            }

            if showMic {
                StatusIcon(action: onMicToggle) {
                    Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(micMuted
                            ? Theme.Palette.controlMicMuted
                            : .white.opacity(0.85))
                }
            }

            Spacer(minLength: 0)

            Button(action: onEnd) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("End")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(Theme.Palette.controlEnd)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Theme.Palette.controlEndSurface.opacity(0.4))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Theme.Palette.controlEnd.opacity(0.4), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct StatusIcon<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.Palette.controlSurface)
                content
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.black.opacity(0.25), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}
