import SwiftUI

/// The meeting bar, for the person who joined somebody else's recording.
///
/// Deliberately the same bar. Same header shape, same Ask, same Notes, same
/// fold-away glyph — because listening to a meeting and recording one are the
/// same activity from where the user sits: following what is being said. The
/// difference is authority, not activity, and it shows up in exactly one place
/// — this person can leave, they cannot end it. Two visually distinct surfaces
/// for one activity would be two things to learn and two things to keep in step.
///
/// What is *not* here is the transcript. It used to be the only thing this
/// surface showed, and it was wrong twice over. Nobody who joins a call twenty
/// minutes late wants to read it — they want what it amounted to, which is what
/// Ask and Notes are. And unbounded, it grew the hosting view until the panel
/// asked to be resized by a layout pass that then asked for another one, which
/// AppKit eventually refuses: `NSGenericException`, mid-meeting, 2026-08-16.
struct NotchListeningBar: View {
    @ObservedObject var rooms: RoomListenerService
    let room: JoinedRoom
    let panel: MeetingBarPanel
    /// The output language, read/write for the same reason the meeting bar's
    /// header carries it: an answer in the wrong language is worth fixing
    /// without leaving the surface that produced it.
    @ObservedObject var language: LanguagePreference
    let onToggleAsk: () -> Void
    let onToggleNotes: () -> Void
    let onSubmitAsk: (String) -> Void
    let onSummarize: () -> Void
    let onCollapse: () -> Void
    let onOpenLibrary: () -> Void
    let geometry: NotchGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                utilities
                header
            }
            .padding(.top, -4)
            ending
            expansion
        }
    }

    /// No mic control and no share-visibility toggle, unlike the recording bar:
    /// this machine is capturing nothing, so both would be controls over
    /// something that is not happening.
    private var utilities: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            NotchLanguageMenuButton(language: language)
            NotchGlyphButton(icon: "nc-window-pointer", help: "Open Nod window", action: onOpenLibrary)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            left
            Spacer(minLength: 4)
            center
            Spacer(minLength: 4)
            right
        }
    }

    private var left: some View {
        HStack(spacing: 6) {
            Image("nc-volume-up")
                .icon(11)
                .accessibilityHidden(true)
                .foregroundStyle(rooms.hasEnded ? Theme.Palette.muted : Theme.Palette.cyan)
            MarqueeText(
                text: room.hostName,
                font: .system(size: 11.5, weight: .semibold),
                color: Theme.Palette.ink,
                width: 68
            )
        }
    }

    /// Counts the host's meeting, not this person's visit to it — somebody who
    /// joined at minute twenty is in a meeting that has been running twenty
    /// minutes, and a clock starting at zero would quietly disagree with the
    /// clock the host is looking at.
    ///
    /// Gone once the recording stops, rather than frozen at its last value: a
    /// clock is how long this has been running, and nothing is running. The line
    /// underneath is what matters at that point.
    @ViewBuilder
    private var center: some View {
        if !rooms.hasEnded {
            TimelineView(.periodic(from: room.startedAt, by: 1)) { context in
                Text(ElapsedClock.text(seconds: Int(context.date.timeIntervalSince(room.startedAt))))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .fixedSize()
                    .foregroundStyle(Theme.Palette.ink)
            }
        }
    }

    /// Ask and Notes mean exactly what they mean while recording. `Leave` sits
    /// where `End` sits on the other bar, and is plain rather than emphasized:
    /// leaving a room takes nothing away from anybody, so dressing it as the
    /// destructive action the End button is would misstate what it does.
    private var right: some View {
        HStack(spacing: 4) {
            MeetingBarButton(title: "Ask", isActive: isAskOpen, action: onToggleAsk)
            MeetingBarButton(title: "Notes", isActive: panel == .notes, action: onToggleNotes)
            MeetingBarButton(title: "Leave", isActive: false) {
                Task { await rooms.leave() }
            }
            NotchGlyphButton(icon: "nc-chevron-up", help: tuckHelp, action: onCollapse)
        }
    }

    private var tuckHelp: String {
        geometry.hasCutout ? "Tuck into the notch" : "Minimize"
    }

    private var isAskOpen: Bool {
        if case .ask = panel { return true }
        return false
    }

    /// What the host pressing End looks like from here.
    ///
    /// Three states rather than one, because "the read closed" and "there is
    /// nothing to show" are not the same thing and the old surface said both by
    /// going quiet. Somebody who followed a call for twenty minutes and watched
    /// it blank at the exact moment the summary was being written had no way to
    /// tell a finished meeting from a broken app.
    @ViewBuilder
    private var ending: some View {
        if let summary = rooms.finalSummary {
            endingNote("\(room.hostName) finished the meeting", tint: Theme.Palette.muted)
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
        } else if rooms.isAwaitingSummary {
            endingNote("Recording stopped — preparing the summary…", tint: Theme.Palette.muted)
        } else if rooms.hasEnded {
            endingNote("Recording stopped", tint: Theme.Palette.muted)
        }
    }

    private func endingNote(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image("nc-check")
                .icon(11)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
    }

    /// The same two panels the recording bar grows, given the same data: the
    /// host's findings arrive through `meeting_live_findings`, so Notes says one
    /// thing in a meeting rather than one thing per machine.
    @ViewBuilder
    private var expansion: some View {
        switch panel {
        case .passive:
            EmptyView()
        case .notes:
            MeetingNotesPanel(findings: rooms.findings)
        case let .ask(phase):
            MeetingAskPanel(phase: phase, onSubmit: onSubmitAsk, onSummarize: onSummarize)
        }
    }
}

/// Listening, folded away — the resting shape for somebody who is following a
/// meeting rather than recording one.
///
/// Its own view rather than a flag on `NotchTucked`, which is built around a
/// recording: a mic level, a pause state, an elapsed clock this machine owns.
/// None of those are true here, and a shared view would spend its life asking
/// which of the two it was.
struct NotchListeningTucked: View {
    let room: JoinedRoom
    let geometry: NotchGeometry

    var body: some View {
        HStack(spacing: 8) {
            Image("nc-volume-up")
                .icon(11)
                .accessibilityHidden(true)
                .foregroundStyle(Theme.Palette.cyan)
            Text(room.hostName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: geometry.collapsedSize.height)
        .accessibilityLabel("Listening to \(room.hostName)")
    }
}

#if DEBUG
    private let previewRoom = JoinedRoom(
        listenerID: UUID(),
        hostName: "Alina",
        hostMeetingID: UUID(),
        startedAt: Date().addingTimeInterval(-900)
    )

    #Preview("Listening") {
        NotchListeningBar(
            rooms: .preview(joined: previewRoom),
            room: previewRoom,
            panel: .passive,
            language: LanguagePreference(),
            onToggleAsk: {},
            onToggleNotes: {},
            onSubmitAsk: { _ in },
            onSummarize: {},
            onCollapse: {},
            onOpenLibrary: {},
            geometry: .island
        )
        .frame(width: 396)
        .padding()
        .background(WindowBackdrop())
    }

    #Preview("Host finished") {
        NotchListeningBar(
            rooms: .preview(joined: previewRoom, ended: true, summary: "Pricing moved to the 12th; Alina is writing the migration note."),
            room: previewRoom,
            panel: .passive,
            language: LanguagePreference(),
            onToggleAsk: {},
            onToggleNotes: {},
            onSubmitAsk: { _ in },
            onSummarize: {},
            onCollapse: {},
            onOpenLibrary: {},
            geometry: .island
        )
        .frame(width: 396)
        .padding()
        .background(WindowBackdrop())
    }
#endif
