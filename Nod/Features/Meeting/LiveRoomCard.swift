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
                Text("\(room.hostName) is recording this meeting")
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

/// The host's transcript while it is still being written, for somebody who is
/// listening rather than recording.
struct LiveRoomTranscript: View {
    @ObservedObject var rooms: RoomListenerService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// No default: the output language is a preference the app already owns
    /// (`LanguagePreference`), and a view quietly answering it for itself is how
    /// one surface ends up speaking a different language from the rest.
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            missed
            if rooms.entries.isEmpty {
                Text("Waiting for the first thing to be said…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(rooms.entries) { entry in
                                line(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .onChange(of: rooms.entries.last?.id) { last in
                        guard let last else { return }
                        if reduceMotion {
                            proxy.scrollTo(last, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
    }

    /// The whole reason for arriving late: not the wall of what was said, but
    /// what it amounted to.
    @ViewBuilder
    private var missed: some View {
        if let summary = rooms.catchUp {
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
        } else if !rooms.entries.isEmpty {
            Button { Task { await rooms.catchMeUp(language: language) } } label: {
                Text(rooms.isCatchingUp ? "Catching up…" : "What did I miss?")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(rooms.isCatchingUp)
            .linkCursor()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let room = rooms.joined {
            HStack(spacing: 6) {
                Image("nc-volume-up")
                    .icon(11)
                    .accessibilityHidden(true)
                Text(rooms.hasEnded
                    ? "\(room.hostName) stopped recording"
                    : "Listening to \(room.hostName)")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer(minLength: 8)
                Button("Leave") { Task { await rooms.leave() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
            }
            .foregroundStyle(rooms.hasEnded ? Theme.Palette.muted : Theme.Palette.cyan)
        }
    }

    private func line(_ entry: LiveTranscriptEntry) -> some View {
        (Text("\(entry.label): ").bold().foregroundColor(Theme.Palette.muted)
            + Text(entry.text))
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.ink.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    #Preview("Listening") {
        LiveRoomTranscript(rooms: .preview(joined: JoinedRoom(
            listenerID: UUID(),
            hostName: "Alina",
            hostMeetingID: UUID(),
            startedAt: Date().addingTimeInterval(-900)
        )), language: .english)
            .frame(width: 460, height: 220)
            .padding()
            .background(WindowBackdrop())
    }
#endif
