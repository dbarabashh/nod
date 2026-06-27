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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(meeting == .paused
                        ? Theme.Palette.controlResume
                        : .white.opacity(0.85))
            }

            if showMic {
                StatusIcon(action: onMicToggle) {
                    Image(systemName: micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            content
                // Sized to match the End pill's height in the same row.
                .frame(width: 28, height: 28)
                // Same frosted glass as the status-header section, sized to the
                // control — so pause / mute read as part of the panel surface
                // rather than solid dark chips floating on top of it.
                .background(
                    PanelMaterial()
                        .clipShape(shape)
                )
        }
        .buttonStyle(.plain)
    }
}
