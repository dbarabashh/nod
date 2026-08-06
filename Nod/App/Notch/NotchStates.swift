import AppKit
import SwiftUI

// MARK: - The offer to record

/// "Hey Dima — Analytics Platform Catch Up starts now. With Leo and Anna."
///
/// One card for the one question, however Nod came to ask it. From the calendar
/// it can greet the user by name and say who the meeting is with; from a running
/// call it has only the app. Two cards meant one meeting could be asked about
/// twice, which is the thing a proactive app can least afford.
///
/// One action and two ways to say no — a detector that reads the room wrong is
/// only tolerable if declining costs as little as accepting, and if the second
/// decline is permanent.
///
/// Nothing here claims Nod is already working. It says the *meeting* is under
/// way, never that the assistant is — because at this moment it is not: no audio
/// is captured and nothing is read until Start is pressed, which is the promise
/// `privacy.md` § 3.10(c) makes in those words.
struct NotchOffer: View {
    let offer: MeetingOffer
    /// The user's first name, when the profile has one. Without it the greeting
    /// drops rather than saying "Hey there" — a stand-in name is worse than no
    /// name, because it is the one word that proves this was meant for them.
    let userName: String?
    /// What Nod already knows about this meeting. Empty is the ordinary case — a
    /// first conversation, or one nothing on this Mac can put a name to.
    let context: CallContext
    /// The app "Never for …" would silence, when the offer names one.
    let mutableApp: ConferencingApp?
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onMute: (ConferencingApp) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    subtitle
                }
                Spacer(minLength: 0)
                NotchGlyphButton(systemName: "xmark", help: "Not now", action: onDismiss)
            }
            actions
        }
    }

    private var title: String {
        guard case let .scheduled(meeting) = offer else { return "Meeting in progress" }
        guard let userName else { return "\(meeting.title) starts now" }
        return "Hey \(userName) — \(meeting.title) starts now"
    }

    /// What Nod knows, when it knows something; what it is about to do
    /// otherwise. Never both — a recognised meeting shown alongside a
    /// description of the product buries the half the user has not seen before.
    @ViewBuilder
    private var subtitle: some View {
        if context.isEmpty {
            line("I'll follow along and surface anything useful.", weight: .regular, tint: Theme.Palette.muted)
        } else {
            if let withLine = context.withLine {
                line(withLine, weight: .medium, tint: Theme.Palette.ink.opacity(0.78))
            }
            if let brief = context.brief {
                line(brief, weight: .regular, tint: Theme.Palette.muted)
            }
        }
    }

    private func line(_ text: String, weight: Font.Weight, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: weight))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The app's own icon when a running call is what told us, so the surface is
    /// recognisable before it is read. A calendar entry has no app to show.
    @ViewBuilder
    private var icon: some View {
        if case let .detected(call) = offer,
           let image = AppDirectory.icon(for: AppDirectory.identity(forBundleID: call.app.rawValue)) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: offer.isRicher ? "calendar.badge.clock" : "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 24, height: 24)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            NotchActionButton(title: "Start transcription", action: onStart)

            if let mutableApp {
                Button { onMute(mutableApp) } label: {
                    Text("Never for \(mutableApp.displayName)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.pressable)
                .linkCursor()
            }
        }
    }
}

// MARK: - What Nod just heard

/// "Noted — send the updated deck before Friday."
///
/// The only card Nod raises on its own while somebody is mid-conversation, so
/// it is built to be read without being answered: no buttons, no decision, gone
/// on its own in a few seconds. What it says is already in the meeting's record
/// and reaches the summary whether or not anybody looks at it, which is what
/// lets it be dismissed without consequence — a glance away costs nothing.
///
/// A revision reads differently on purpose. "Changed —" is the one thing here
/// the room itself may not have registered, and stating it flatly alongside a
/// new task would waste the only moment Nod knows something the user doesn't.
struct NotchNotice: View {
    let finding: LiveFinding
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: finding.revisionOf == nil ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(lead)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                Text(finding.text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let deadline = finding.deadline {
                    Text(deadline)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                }
            }

            Spacer(minLength: 0)
            NotchGlyphButton(systemName: "xmark", help: "Dismiss", action: onDismiss)
        }
    }

    private var lead: String {
        finding.revisionOf == nil ? "Noted" : "Changed"
    }
}

// MARK: - Live input level

/// The live microphone level, as five bars that move with what Nod is hearing.
///
/// The one genuinely live thing on the surface: a static dot says a recording
/// exists, this says it is *working*, which is the question a user glances up to
/// answer mid-call. Flat and amber while paused, because a meter still dancing
/// when nothing is being captured is a lie.
/// Subscribes to the capture service itself rather than taking a level from its
/// parent: `inputLevel` publishes about ten times a second, and read one level
/// up it would rebuild the whole surrounding card — clock, transport, capsule
/// fills and all — at that rate. Here only the five capsules invalidate.
struct NotchLevelMeter: View {
    @ObservedObject var audioCapture: AudioCaptureService
    let paused: Bool
    let barWidth: CGFloat
    let span: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Taller in the middle, so the bars read as one waveform rather than five
    /// independent indicators.
    private static let weights: [CGFloat] = [0.5, 0.8, 1.0, 0.72, 0.44]
    private static let floorHeight: CGFloat = 3

    var body: some View {
        // Hoisted: the eased amplitude is the same for every bar, so computing
        // it per bar meant five `pow` calls per level update.
        let eased = easedAmplitude

        return HStack(spacing: barWidth) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(paused ? Theme.Palette.warning : Theme.Palette.brand)
                    .frame(width: barWidth, height: Self.floorHeight + span * weight * eased)
            }
        }
        .frame(height: span + Self.floorHeight, alignment: .center)
        // Ad-hoc on purpose: a continuous meter tracking a signal isn't a UI
        // state change, so the design system's springs don't apply to it. The
        // paused flip below is one, and uses the token.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: audioCapture.inputLevel)
        .animation(.standard(reduceMotion: reduceMotion), value: paused)
    }

    /// Perceptual, not linear: conversational speech sits low in the range, and
    /// mapping it straight through leaves the meter looking dead for a whole call.
    private var easedAmplitude: CGFloat {
        guard !paused else { return 0 }
        return pow(CGFloat(min(1, max(0, audioCapture.inputLevel))), 0.45)
    }
}

// MARK: - Transport controls

/// The opened capture state: that Nod is hearing something, for how long, and
/// the three things you can do about it.
///
/// No status word. The meter says it is listening more convincingly than the
/// word "Listening" did, and the clock is the thing people actually come to read.
struct NotchControls: View {
    @ObservedObject var session: MeetingSession
    /// Not observed here — handed straight to `NotchLevelMeter`, which is the
    /// only thing that reads it and the only thing that should redraw with it.
    let audioCapture: AudioCaptureService
    let onCollapse: () -> Void

    private var paused: Bool {
        session.meeting == .paused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            transport
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            NotchLevelMeter(audioCapture: audioCapture, paused: paused, barWidth: 2, span: 11)
                .frame(width: 29, height: 29)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )

            Spacer(minLength: 8)

            // The one big number. Sized like the clock in a Live Activity
            // rather than like a caption: at a glance across the desk, this is
            // the whole reason to look up.
            Text(session.elapsedClock)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundColor(paused ? Theme.Palette.warning : Theme.Palette.brand)
                .monospacedDigit()
                .fixedSize()

            NotchGlyphButton(systemName: "chevron.up", help: "Collapse", action: onCollapse)
        }
    }

    private var transport: some View {
        HStack(spacing: 10) {
            NotchControlButton(
                systemName: paused ? "play.fill" : "pause.fill",
                tint: paused ? Theme.Palette.controlResume : Theme.Palette.ink.opacity(0.85),
                help: paused ? "Resume" : "Pause",
                action: session.toggleRecording
            )

            NotchControlButton(
                systemName: session.micMuted ? "mic.slash.fill" : "mic.fill",
                tint: session.micMuted ? Theme.Palette.controlMicMuted : Theme.Palette.ink.opacity(0.85),
                help: session.micMuted ? "Unmute" : "Mute",
                action: session.toggleMic
            )

            Spacer(minLength: 0)

            Button(action: session.endMeeting) {
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
            .buttonStyle(.pressable)
        }
    }
}

private struct NotchControlButton: View {
    let systemName: String
    let tint: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
        }
        .buttonStyle(.pressable(scale: 0.92))
        .help(help)
    }
}

// MARK: - Start

/// The idle opened state.
///
/// Built to the same rhythm as `NotchOffer` — glyph, what this is, what it
/// will do, then the action — so the surface the user summons and the surface
/// that offers itself read as one thing. A single full-width button filling the
/// notch said nothing except "press me", which is a lot of screen for one verb.
struct NotchLaunch: View {
    @ObservedObject var session: MeetingSession
    let onStart: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            NotchCollector(size: 46)

            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ready to pick things up")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    Text("Nod follows the conversation and comes back with what needs doing.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Theme.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NotchActionButton(
                    title: session.selectedKind.startActionTitle,
                    icon: session.selectedKind.icon,
                    action: onStart
                )
            }

            Spacer(minLength: 0)
        }
    }
}

extension MeetingSession {
    /// The elapsed time as `mm:ss`, for the two places the notch shows a clock.
    var elapsedClock: String {
        String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

/// The notch's affirmative action, wherever it appears — Start, Keep, Retry,
/// Update, Acknowledge.
///
/// One component because the notch is one card to the user: hand-rolled per
/// state, the same button changed size and weight as the surface morphed
/// between them. Sized to its label rather than stretched to the surface — a
/// button as wide as the notch reads as the notch itself being the button.
///
/// The optional glyph is deliberately never a red record dot: red is the active
/// capture state, and a red dot on the *start* affordance reads for a beat as
/// "already recording".
struct NotchActionButton: View {
    let title: String
    var icon: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(Theme.GlassButton.text)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassButtonSurface(Capsule(style: .continuous))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .linkCursor()
    }
}

/// The notch's small circular glyph control — collapse, dismiss. Shared so the
/// close affordance doesn't change size, chrome or press behaviour depending on
/// which state happens to be showing.
struct NotchGlyphButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Theme.Palette.muted)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.Palette.surfaceStrong))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable(scale: 0.90))
        .linkCursor()
        .help(help)
    }
}
