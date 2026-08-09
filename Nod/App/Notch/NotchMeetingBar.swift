import SwiftUI

// MARK: - The meeting bar

/// The whole point of this redesign: one surface, visible for the entire
/// meeting, that never has to be clicked open to find out whether the mic
/// still works or to ask something. `.tucked` (swiped into the notch) and the
/// finished `.recap` card are the only other things a live recording ever
/// shows instead of this.
///
/// Header row first, always; `expansion` grows underneath it for Notes or
/// Ask — never a second window, never a modal.
struct NotchMeetingBar: View {
    let panel: MeetingBarPanel
    @ObservedObject var session: MeetingSession
    /// A plain reference, not `@ObservedObject`: nothing here reads
    /// `audioCapture` directly, only `NotchMicMenuButton` does, and it mirrors
    /// the two properties it needs into local state on its own rather than
    /// resubscribing this whole bar to `inputLevel`'s ten-times-a-second
    /// publishes.
    let audioCapture: AudioCaptureService
    let onToggleAsk: () -> Void
    let onToggleNotes: () -> Void
    let onSubmitAsk: (String) -> Void
    let onSummarize: () -> Void
    /// Nil on a display with no cut-out — there is nowhere to tuck the bar
    /// into, so the button that would do it doesn't exist rather than doing
    /// nothing when pressed. The trackpad swipe is the same action; this is
    /// the click-driven way to reach it without trusting gesture recognition
    /// alone.
    let onCollapse: (() -> Void)?

    private var paused: Bool {
        session.meeting == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            expansion
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

    // MARK: Left — what this is

    private var left: some View {
        HStack(spacing: 6) {
            MeetingActivityDot(paused: paused)
            NotchMicMenuButton(session: session, audioCapture: audioCapture)
            MarqueeText(
                text: title,
                font: .system(size: 11.5, weight: .semibold),
                color: Theme.Palette.ink,
                width: 68
            )
        }
    }

    /// The offer's own title when the recording started from one; otherwise
    /// there is nothing to call it yet, so the kind stands in ("Meeting",
    /// "Voice note").
    private var title: String {
        session.liveTitle ?? session.selectedKind.title
    }

    // MARK: Center — duration and what Nod is doing

    /// The clock and status double as the pause/resume control — one tap
    /// target for the one thing this group is already telling you about,
    /// rather than a fourth button squeezed in beside Ask/Notes/End.
    private var center: some View {
        Button(action: session.toggleRecording) {
            HStack(spacing: 6) {
                Text(session.elapsedClock)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .fixedSize()
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundStyle(paused ? Theme.Palette.warning : Theme.Palette.ink)
        }
        .buttonStyle(.pressable)
        .help(paused ? "Resume" : "Pause")
        .accessibilityLabel(paused ? "Resume recording" : "Pause recording")
    }

    /// Nil for the ordinary case — the dot is already saying "this is live,"
    /// and repeating "Listening…" next to it read as noise. Only surfaces
    /// when something actually deviates from that: paused, or the Ask box
    /// working on an answer.
    private var statusText: String? {
        if case .ask(.loading) = panel { return "Thinking…" }
        if paused { return "Paused" }
        return nil
    }

    // MARK: Right — the three things worth doing right now

    private var right: some View {
        HStack(spacing: 4) {
            MeetingBarButton(title: "Ask", isActive: isAskOpen, action: onToggleAsk)
            MeetingBarButton(title: "Notes", isActive: panel == .notes, action: onToggleNotes)
            MeetingBarEndButton(action: session.endMeeting)
            if let onCollapse {
                NotchGlyphButton(systemName: "nc-chevron-up", help: "Tuck into the notch", action: onCollapse)
            }
        }
    }

    private var isAskOpen: Bool {
        if case .ask = panel { return true }
        return false
    }

    // MARK: Expansion — Ask or Notes, grown below the header

    @ViewBuilder
    private var expansion: some View {
        switch panel {
        case .passive:
            EmptyView()
        case .notes:
            MeetingNotesPanel(findings: session.analyst.findings)
        case let .ask(phase):
            MeetingAskPanel(phase: phase, onSubmit: onSubmitAsk, onSummarize: onSummarize)
        }
    }
}

// MARK: - Activity dot

/// The recording-is-live indicator — paired with the status text rather than
/// standing alone, so nobody has to learn what a pulsing dot means on its
/// own. Real, not decorative: it stops pulsing the moment the recording is
/// actually paused.
private struct MeetingActivityDot: View {
    let paused: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(paused ? Theme.Palette.warning : Theme.Palette.brand)
            .frame(width: 7, height: 7)
            .opacity(paused ? 1 : (pulse ? 1 : 0.45))
            .animation(paused ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Marquee title

/// The meeting title, in a fixed window: short titles just sit there, a title
/// wider than `width` scrolls left then right on a loop instead of ending in
/// a hard-clipped "…" — a real calendar event's title is exactly the case
/// static truncation reads worst on. The trailing (and, mid-scroll, leading)
/// edge fades rather than cutting the letters off mid-stroke.
///
/// Measures its own natural width via a `GeometryReader` riding along in the
/// background — the standard SwiftUI trick for "how wide would this be
/// unconstrained" — then only animates when that's actually wider than the
/// window. Respects Reduce Motion: a title that doesn't fit still shows
/// (leading-aligned, hard clipped) rather than never revealing its tail, but
/// nothing moves on its own.
private struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let width: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var scrolledBack = false

    private var overflow: CGFloat {
        max(0, textWidth - width)
    }

    private var scrolls: Bool {
        overflow > 0.5 && !reduceMotion
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.onAppear { textWidth = proxy.size.width }
                }
            )
            .offset(x: scrolls && scrolledBack ? -overflow : 0)
            .animation(
                scrolls
                    ? .linear(duration: max(1.2, Double(overflow) / 24)).repeatForever(autoreverses: true).delay(0.6)
                    : nil,
                value: scrolledBack
            )
            .onAppear { scrolledBack = true }
            .onChange(of: text) { _ in
                // A new meeting's title starts still, not mid-scroll from the
                // last one's length.
                scrolledBack = false
                textWidth = 0
                DispatchQueue.main.async { scrolledBack = true }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
            .mask(fadeMask)
    }

    /// Only fades where the text can actually be cut — a title that fits
    /// entirely gets no mask at all, so it isn't dimmed for nothing.
    @ViewBuilder
    private var fadeMask: some View {
        if scrolls {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 6)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 10)
            }
        } else {
            Rectangle()
        }
    }
}

// MARK: - Right-side buttons

/// Ask/Notes — small, equal-weight text buttons rather than icon glyphs: both
/// are asks the user makes of Nod, not transport state, so they read better
/// named than guessed at from a symbol.
private struct MeetingBarButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(isActive ? Theme.Palette.brand : Theme.Palette.ink.opacity(0.85))
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(isActive ? Theme.Palette.brand.opacity(0.16) : Theme.Palette.surfaceStrong)
                )
        }
        .buttonStyle(.pressable)
    }
}

/// End — same size as its siblings, tinted so it stays identifiable without
/// taking up more room than "Ask" or "Notes" do.
private struct MeetingBarEndButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("End")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Theme.Palette.controlEnd)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.controlEndSurface.opacity(0.4))
                )
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("End meeting")
    }
}

// MARK: - Notes

/// The live findings-so-far, surfaced rather than re-derived: `findings` is
/// the same standing memory `LiveMeetingAnalyst` already grounds the recap on,
/// just read here instead of only at the end of the meeting.
private struct MeetingNotesPanel: View {
    let findings: [LiveFinding]

    private var standing: [LiveFinding] {
        findings.filter { $0.state == .standing }
    }

    private var decisionCount: Int {
        standing.filter { $0.kind == .decision }.count
    }

    private var actionCount: Int {
        standing.filter { $0.kind == .action }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LIVE NOTES")
                .font(.system(size: 9.5, weight: .bold))
                .kerning(0.6)
                .foregroundStyle(Theme.Palette.muted.opacity(0.9))

            if standing.isEmpty {
                Text("Nothing flagged yet.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(standing) { finding in
                            HStack(alignment: .top, spacing: 7) {
                                Circle()
                                    .fill(Theme.Palette.muted.opacity(0.7))
                                    .frame(width: 3, height: 3)
                                    .padding(.top, 5.5)
                                Text(finding.text)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(Theme.Palette.graphite)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
                .frame(maxHeight: 180)

                HStack {
                    Text("\(decisionCount) decision\(decisionCount == 1 ? "" : "s")")
                    Spacer(minLength: 0)
                    Text("\(actionCount) action item\(actionCount == 1 ? "" : "s")")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
            }
        }
    }
}

// MARK: - Ask

/// The free-text box plus whatever it's showing — a fresh field, a spinner,
/// an answer, or a failure. The field itself never goes away once Ask is
/// open, so answering one question and asking the next reads as one
/// conversation rather than a result screen you have to back out of.
private struct MeetingAskPanel: View {
    let phase: AskPhase
    let onSubmit: (String) -> Void
    let onSummarize: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            result
            inputRow
            if case .composing = phase {
                suggestions
            }
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .composing:
            EmptyView()
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .progressViewStyle(.circular)
                    .tint(Theme.Palette.muted)
                Text("Thinking…")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Theme.Palette.muted)
            }
        case let .answered(question, answer):
            VStack(alignment: .leading, spacing: 4) {
                Text(question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                Text(answer)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .failed(question):
            Text("Couldn't answer \u{201C}\(question)\u{201D} — try again.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.Palette.muted)
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask anything about this meeting…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Theme.Palette.ink)
                .focused($focused)
                .onSubmit(submit)
            Button(action: submit) {
                Image("nc-paper-plane-2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(canSubmit ? Theme.Palette.brand : Theme.Palette.muted.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Send question")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
    }

    private var suggestions: some View {
        HStack(spacing: 8) {
            chip("What did we decide?")
            chip("Who owns this?")
            Button(action: onSummarize) {
                Text("Summarize")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .buttonStyle(.pressable)
        }
    }

    private func chip(_ text: String) -> some View {
        Button { onSubmit(text) } label: {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
                .lineLimit(1)
        }
        .buttonStyle(.pressable)
    }

    private var canSubmit: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        let question = draft
        draft = ""
        onSubmit(question)
    }
}
