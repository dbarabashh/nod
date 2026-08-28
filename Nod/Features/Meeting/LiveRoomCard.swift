import SwiftUI

/// An offer to listen to a meeting a colleague is already recording.
///
/// Joining is a button and never a default: the host is told the moment somebody
/// arrives, so it must happen because a person decided to, not because a window
/// appeared.
struct LiveRoomCard: View {
    let room: LiveRoom
    var isJoining = false
    let onJoin: () -> Void
    let onDismiss: () -> Void
    /// Offered only when the calendar was about to ask this person to record the
    /// same meeting. Joining is the better answer nearly always — one recording
    /// of a call is enough — but "nearly" is not "always", and the person who
    /// wants their own copy should not have to wait for this card to time out to
    /// get it.
    var onRecordInstead: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("nc-volume-up")
                .icon(14)
                .accessibilityHidden(true)
                .foregroundStyle(Theme.Palette.cyan)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(room.hostName.map { "\($0) is recording this meeting" }
                    ?? "Someone is recording this meeting")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Join to follow along and ask what you missed. You won't be recording, and nothing is kept when they stop.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Button(action: onJoin) {
                    Text(isJoining ? "Joining…" : "Join")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isJoining)
                .linkCursor()

                if let onRecordInstead {
                    Button("Record my own", action: onRecordInstead)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .linkCursor()
                }

                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
    }
}

#if DEBUG
    #Preview("Offer") {
        LiveRoomCard(
            room: LiveRoom(hostName: "Alina", startedAt: Date().addingTimeInterval(-900)),
            onJoin: {},
            onDismiss: {}
        )
        .frame(width: 460)
        .padding()
        .background(WindowBackdrop())
    }

    /// The ordinary case for anybody whose calendar the server cannot read: a
    /// recording exists, and who is making it is not this card's to say.
    #Preview("Offer, host withheld") {
        LiveRoomCard(
            room: LiveRoom(hostName: nil, startedAt: Date().addingTimeInterval(-900)),
            onJoin: {},
            onDismiss: {}
        )
        .frame(width: 460)
        .padding()
        .background(WindowBackdrop())
    }

    #Preview("Joining") {
        LiveRoomCard(
            room: LiveRoom(hostName: "Alina", startedAt: Date().addingTimeInterval(-900)),
            isJoining: true,
            onJoin: {},
            onDismiss: {}
        )
        .frame(width: 460)
        .padding()
        .background(WindowBackdrop())
    }

#endif
