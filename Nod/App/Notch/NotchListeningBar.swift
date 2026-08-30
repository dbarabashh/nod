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
        MeetingBarHeader { left } center: { center } right: { right }
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
    /// The caption rides alongside rather than replacing the clock, and outlives
    /// the recording it belongs to: a question asked in the last seconds of a
    /// meeting is still being answered after the host presses End.
    private var center: some View {
        HStack(spacing: 6) {
            // A clock says "you are following this". While the request is still
            // unanswered, or after it was refused, that is exactly what is not
            // true yet.
            if !rooms.hasEnded, !room.isPending, !room.isDenied {
                TimelineView(.periodic(from: room.startedAt, by: 1)) { context in
                    Text(ElapsedClock.text(seconds: Int(context.date.timeIntervalSince(room.startedAt))))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .fixedSize()
                }
            }
            if panel.isAnswering {
                MeetingBarCaption(text: "Thinking…")
            }
        }
        .foregroundStyle(Theme.Palette.ink)
    }

    /// Ask and Notes mean exactly what they mean while recording. `Leave` sits
    /// where `End` sits on the other bar, and is plain rather than emphasized:
    /// leaving a room takes nothing away from anybody, so dressing it as the
    /// destructive action the End button is would misstate what it does.
    private var right: some View {
        HStack(spacing: 4) {
            MeetingBarButton(
                title: "Ask",
                isActive: panel.isAsk,
                hasUnread: panel.isAnswerUnseen,
                action: onToggleAsk
            )
            MeetingBarButton(title: "Notes", isActive: panel.isNotes, action: onToggleNotes)
            MeetingBarButton(title: "Leave", isActive: false) {
                Task { await rooms.leave() }
            }
            NotchGlyphButton(icon: "nc-chevron-up", help: geometry.tuckLabel, action: onCollapse)
        }
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
        if room.isPending {
            MeetingBarStatusLine(
                icon: "nc-volume-up",
                text: "Asked \(room.hostName) to let you listen…",
                tint: Theme.Palette.cyan
            )
        } else if room.isDenied {
            MeetingBarStatusLine(icon: "nc-xmark", text: "\(room.hostName) declined")
        } else if let summary = rooms.finalSummary {
            MeetingBarStatusLine(icon: "nc-check", text: "\(room.hostName) finished the meeting")
            MeetingBarProse(text: summary)
        } else if rooms.isAwaitingSummary {
            MeetingBarStatusLine(icon: "nc-check", text: "Recording stopped — preparing the summary…")
        } else if rooms.hasEnded {
            MeetingBarStatusLine(icon: "nc-check", text: "Recording stopped")
        }
    }

    /// The same two panels the recording bar grows, given the same data: the
    /// host's findings arrive through `meeting_live_findings`, so Notes says one
    /// thing in a meeting rather than one thing per machine.
    private var expansion: some View {
        MeetingBarExpansion(
            panel: panel,
            findings: rooms.findings,
            // Findings are the meeting's and get mirrored; open loops are the
            // host's own list, and a listener seeing what somebody else still
            // owes is the account boundary this product does not cross.
            loops: [],
            // Integrations belong to the account that authorized them. A
            // listener is on somebody else's meeting with their own account,
            // and this bar has no lookup to reach either one's products with.
            canReachTools: false,
            onSubmit: onSubmitAsk,
            onSummarize: onSummarize,
            // A listener has no lookup and so nothing that could ask to write.
            // Answered rather than defaulted, so the day one appears here the
            // buttons are wired rather than silently inert.
            onApprove: {},
            onDeny: {}
        )
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

    /// Straddles the cut-out the same way `NotchTucked` does: on a notched Mac
    /// the middle of this surface is opaque hardware, so the two halves anchor
    /// to the outer edges and the hole is reserved rather than drawn through.
    /// Without one there is nothing to straddle, and spreading them would leave
    /// a gap of black exactly where the notch isn't.
    ///
    /// No explicit height: `NotchPresentation.surfaceHeight` already pins the
    /// resting states to the cut-out, and a second answer here could only
    /// disagree with it.
    var body: some View {
        HStack(spacing: geometry.hasCutout ? 0 : 8) {
            Image("nc-volume-up")
                .icon(11)
                .accessibilityHidden(true)
                .foregroundStyle(Theme.Palette.cyan)
                .frame(maxWidth: geometry.hasCutout ? .infinity : nil, alignment: .leading)

            if geometry.hasCutout {
                Color.clear.frame(width: geometry.cutoutWidth)
            }

            Text(room.hostName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: geometry.hasCutout ? .infinity : nil, alignment: .trailing)
        }
        .padding(.horizontal, geometry.flare + 12)
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
            panel: MeetingBarPanel(),
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
            panel: MeetingBarPanel(),
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
