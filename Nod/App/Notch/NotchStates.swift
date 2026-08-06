import AppKit
import SwiftUI

// MARK: - Detected call

/// "Zoom call detected — record it?", hanging off the menu bar.
///
/// One action and two ways to say no. A detector that reads the room wrong is
/// only tolerable if declining costs as little as accepting, and if the second
/// decline is permanent.
struct NotchInvitation: View {
    let app: ConferencingApp
    /// What Nod already knows about this call. Empty is the ordinary case — a
    /// first conversation, or a meeting nothing on this Mac can put a name to.
    let context: CallContext
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onMute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(app.displayName) call detected")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    subtitle
                }
                Spacer(minLength: 0)
                NotchGlyphButton(systemName: "xmark", help: "Not now", action: onDismiss)
            }
            actions
        }
    }

    /// What Nod knows, when it knows something; what it is about to do
    /// otherwise. Never both — a recognised meeting shown alongside a
    /// description of the product buries the half the user has not seen before.
    ///
    /// Who is on the call leads when the calendar knows it. That is the question
    /// being answered in the two seconds before someone clicks Start, and it is
    /// the one thing here that no other surface in the app can tell them.
    @ViewBuilder
    private var subtitle: some View {
        if context.isEmpty {
            line("Nod will transcribe it and write the summary.", weight: .regular, tint: Theme.Palette.muted)
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

    /// The app's own icon, so the surface is recognisable before it is read.
    @ViewBuilder
    private var icon: some View {
        if let image = AppDirectory.icon(for: AppDirectory.identity(forBundleID: app.rawValue)) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "video.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.brand)
                .frame(width: 24, height: 24)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            NotchActionButton(title: "Start transcription", action: onStart)

            Button(action: onMute) {
                Text("Never for \(app.displayName)")
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
/// Built to the same rhythm as `NotchInvitation` — glyph, what this is, what it
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
