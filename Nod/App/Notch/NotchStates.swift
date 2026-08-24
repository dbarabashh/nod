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
                NotchGlyphButton(icon: "nc-xmark", help: "Not now", action: onDismiss)
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
            Image(offer.isRicher ? "nc-calendar-days" : "nc-video")
                .icon(13)
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

/// "Noted — send the updated deck before Friday." Or, hedged:
/// "Might be — probably have that by Friday."
///
/// The only card Nod raises on its own while somebody is mid-conversation. A
/// strict finding is built to be read without being answered: it is already in
/// the meeting's record and reaches the summary whether or not anybody looks at
/// it, which is what lets its glyph be dismissed without consequence — a glance
/// away costs nothing. A soft one is the exception: the same glyph is this
/// finding's only "no," so tapping it actually drops it — see
/// `LiveMeetingAnalyst.dismissNotice(userRejected:)`.
///
/// A revision reads differently on purpose. "Changed —" is the one thing here
/// the room itself may not have registered, and stating it flatly alongside a
/// new task would waste the only moment Nod knows something the user doesn't.
struct NotchNotice: View {
    /// The three ways this card can read, in one place rather than one
    /// judgement repeated per string — a revision outranks tier because a
    /// finding that changed its mind is never also the one under review.
    private enum Style: Equatable {
        case revision
        case soft
        case strict

        init(_ finding: LiveFinding) {
            if finding.revisionOf != nil {
                self = .revision
            } else if finding.tier == .soft {
                self = .soft
            } else {
                self = .strict
            }
        }

        var icon: String {
            switch self {
            case .revision: "nc-refresh-2"
            case .soft: "nc-msgs"
            case .strict: "nc-circle-check"
            }
        }

        var lead: String {
            switch self {
            case .revision: "Changed"
            case .soft: "Might be"
            case .strict: "Noted"
            }
        }

        var dismissHelp: String {
            self == .soft ? "Not this" : "Dismiss"
        }
    }

    let finding: LiveFinding
    let onDismiss: () -> Void

    private var style: Style {
        Style(finding)
    }

    /// The gap between when this was said and when the card appears is exactly
    /// what makes a notice read as stale once the room has moved on — this
    /// names that gap instead of leaving the user to guess it from the topic
    /// already having changed.
    private static func relativeLabel(_ spokenAt: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(spokenAt)))
        guard seconds >= 60 else { return "just now" }
        return "\(seconds / 60)m ago"
    }

    /// Icon at 12pt with no fixed frame, main line at 12.5pt semibold — the
    /// same weights `DemoCardHead` uses for every proactive card in the
    /// scripted demo, so a real notice reads as the same kind of moment
    /// instead of visibly bigger and boxed. `style.lead` is its own small
    /// eyebrow line (the same treatment `NotchMeetingBar`'s "LIVE NOTES"
    /// label uses) rather than an em-dash prefix on the finding itself.
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(style.icon)
                .icon(12)
                .foregroundStyle(Theme.Palette.brand)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(style.lead.uppercased())
                        .font(.system(size: 9.5, weight: .bold))
                        .kerning(0.6)
                        .foregroundStyle(Theme.Palette.muted.opacity(0.9))
                    if let spokenAt = finding.spokenAt {
                        Text(Self.relativeLabel(spokenAt))
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(Theme.Palette.muted.opacity(0.65))
                    }
                }
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
            NotchGlyphButton(icon: "nc-xmark", help: style.dismissHelp, action: onDismiss)
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
/// Observes the level on its own rather than taking it from its parent: it
/// changes about ten times a second, and read one level up it would rebuild the
/// whole surrounding card — clock, transport, capsule fills and all — at that
/// rate. Here only the five capsules invalidate.
struct NotchLevelMeter: View {
    @ObservedObject var level: InputLevel
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: level.value)
        .animation(.standard(reduceMotion: reduceMotion), value: paused)
    }

    /// Perceptual, not linear: conversational speech sits low in the range, and
    /// mapping it straight through leaves the meter looking dead for a whole call.
    private var easedAmplitude: CGFloat {
        guard !paused else { return 0 }
        return pow(CGFloat(min(1, max(0, level.value))), 0.45)
    }
}

/// The microphone: mute on the glyph, the device list under the chevron beside
/// it. A pull-down button with a primary action, in the shape AppKit gives one
/// — the mute is the button, the indicator opens the menu — drawn by hand
/// because SwiftUI's own `Menu(primaryAction:)` only draws its indicator
/// through a system button style, and the bezel that comes with it resizes the
/// glyph to the menu cell's rules instead of this row's 20pt chrome.
///
/// Two hit regions rather than one control with two gestures: the press-and-hold
/// this replaced announced nothing on screen, so the device list may as well not
/// have existed. It is also why the chevron is a control of its own to
/// VoiceOver — a single `Menu` with a primary action exposes one element, and
/// the half that switches microphone would have no name to read.
///
/// `MicrophoneSettingsSection` holds the same choice for when no meeting is
/// running; both write through `switchInput`, which rebinds a live engine.
///
/// A `Menu`, not `Button` + `.popover`: the notch surface is a non-activating
/// borderless panel, and `.popover` needs a real key window to anchor
/// against — inside this one it falls back to a full-surface dimming overlay
/// instead of a small anchored bubble. `Menu` is backed by `NSMenu`, which has
/// no such dependency.
///
/// Not `private`: `NotchMeetingBar.swift` uses it directly in the
/// always-visible bar's header.
struct NotchMicControl: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var audioCapture: AudioCaptureService

    var body: some View {
        HStack(spacing: 0) {
            muteButton
            // The seam a split button has, at the row's own border weight: with
            // one capsule behind both halves and no rule between them, nothing
            // says the chevron is a second target rather than decoration on the
            // first.
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(width: 1, height: 12)
            deviceMenu
        }
        // Sized to the glyph row's 20pt circles rather than to the hit frames,
        // which are taller: the pair has to read as one control the same height
        // as its siblings, not as a bar that grew.
        .background(Capsule().fill(Theme.Palette.surfaceStrong).frame(height: 20))
        .accessibilityElement(children: .contain)
    }

    /// The wider half of the two. Mute is pressed several times a call; the
    /// device list is opened once a meeting at most, and on the rare occasion
    /// the aim lands on the wrong side, opening a menu is the cheaper mistake.
    private var muteButton: some View {
        Button(action: session.toggleMic) {
            Image(muteIcon)
                .icon(9)
                .foregroundColor(muteTint)
                .frame(width: 23, height: 20)
        }
        .buttonStyle(.pressable(scale: 0.90))
        .linkCursor()
        .frame(height: 24)
        .contentShape(Rectangle())
        .glyphTooltip(muteHelp)
    }

    private var deviceMenu: some View {
        Menu {
            MicrophoneInputPicker(
                devices: audioCapture.availableInputs,
                selectedUID: audioCapture.preferredInputUID,
                onSelect: { newUID in Task { await audioCapture.switchInput(to: newUID) } }
            )
            .pickerStyle(.inline)
        } label: {
            Image("nc-chevron-down")
                .icon(7)
                .foregroundColor(Theme.Palette.muted)
                .frame(width: 15, height: 20)
        }
        // Pinned rather than left to the label: `menuStyle(.button)` still
        // sizes the cell to its own rules, and an unpinned chevron half grows
        // past the capsule the mute half is sharing with it.
        .plainMenuChrome()
        .frame(width: 15, height: 24)
        .contentShape(Rectangle())
        .glyphTooltip(deviceHelp)
    }

    private var hasProblem: Bool {
        audioCapture.micError != nil
    }

    private var muteIcon: String {
        if hasProblem { return "nc-triangle-warning" }
        return session.micMuted ? "nc-mic-slash" : "nc-mic"
    }

    private var muteTint: Color {
        if hasProblem { return Theme.Palette.warning }
        return session.micMuted ? Theme.Palette.controlMicMuted : Theme.Palette.muted
    }

    private var muteHelp: String {
        audioCapture.micError ?? (session.micMuted ? "Unmute" : "Mute")
    }

    /// Names the device: a chevron says "there is a list here", not which
    /// microphone is live, so this is the only way to find that out without
    /// opening the menu.
    private var deviceHelp: String {
        let devices = audioCapture.availableInputs
        if let name = devices.name(forUID: audioCapture.preferredInputUID) {
            return "Microphone: \(name)"
        }
        return devices.systemDefaultName.map { "Microphone: \($0) (system default)" } ?? "Choose microphone"
    }
}

/// The other half of "is this recording actually working" — the half nothing
/// used to show.
///
/// `NotchMicControl` has always warned about the microphone; a system-audio
/// failure only ever reached `Log.audio` and an analytics event, so a call
/// recorded with the far side missing looked exactly like a healthy one.
/// Present only while it is actually broken: a warning glyph that lives on the
/// row permanently would stop meaning anything.
struct NotchSystemAudioAlert: View {
    /// The kind being recorded, not the session: a voice note captures no
    /// system audio, so a stale failure from the previous meeting says nothing
    /// about this one.
    let kind: SessionKind
    @ObservedObject var audioCapture: AudioCaptureService
    let permissions: PermissionManager

    var body: some View {
        if let failure, kind.capturesSystem {
            // A button only where pressing it can achieve something. The other
            // failures are already being retried, and a control that opens a
            // settings pane which has nothing to do with the problem is worse
            // than no control.
            if failure.isUserFixable {
                NotchGlyphButton(
                    icon: "nc-triangle-warning",
                    help: "Nod isn't hearing the other side. Click to allow Screen Recording.",
                    tint: Theme.Palette.warning,
                    action: permissions.openScreenRecordingSettings
                )
            } else {
                Image("nc-triangle-warning")
                    .icon(9)
                    .foregroundColor(Theme.Palette.warning)
                    .notchGlyphChrome()
                    .glyphTooltip("Nod isn't hearing the other side. Reconnecting.")
            }
        }
    }

    private var failure: SystemAudioFailure? {
        audioCapture.systemAudioError
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
    var isLoading = false
    var error: String?
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
                    isLoading: isLoading || session.isStartingRecording || session.isFinishingTranscription,
                    action: onStart
                )

                if let error {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.GlassButton.text)
                } else if let icon {
                    Image(icon)
                        .icon(12)
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
        .disabled(isLoading)
        .linkCursor()
    }
}

extension View {
    /// The notch's small circular glyph chrome — a 20×20 dot on
    /// `surfaceStrong`, its content shape trimmed to match. Shared by
    /// `NotchGlyphButton` and `NotchLanguageMenuButton` so the notch's
    /// various round trigger controls read as one family regardless of
    /// whether the content inside is an icon or a text chip.
    func notchGlyphChrome() -> some View {
        frame(width: 20, height: 20)
            .background(Circle().fill(Theme.Palette.surfaceStrong))
            .contentShape(Circle())
    }
}

/// The notch's small circular glyph control — collapse, dismiss. Shared so the
/// close affordance doesn't change size, chrome or press behaviour depending on
/// which state happens to be showing.
/// A glyph button that copies and flashes a check.
///
/// Its own view, not a `copied` flag on the card that hosts it: the flag is
/// `@State`, so on the card it would re-run that card's whole body twice per
/// tap — and the recap card's body parses the entire summary markdown on every
/// pass. Here the toggle invalidates one 9pt glyph.
///
/// `text` is a closure for the same reason: the payload is built when the
/// button is pressed, not on every redraw of whatever contains it.
/// Whether Nod shows up in a screen share, from the bar itself.
///
/// The same preference the Settings toggle writes — this is not a second
/// setting, it is the one setting where it is needed. Off is the default and
/// the safe state, and the moment you find out you wanted it on is the moment
/// you are already sharing, which is exactly when Settings is the wrong place
/// to have to go.
struct NotchShareVisibilityButton: View {
    @ObservedObject var preference: PanelSharingPreference

    var body: some View {
        NotchGlyphButton(
            icon: "nc-stack-perspective",
            help: preference.visibleWhenSharing ? "Shown in screen shares" : "Hidden from screen shares",
            // One glyph, tinted, rather than a pair: there is no honest second
            // Nucleo icon for "hidden from capture", and swapping to an
            // unrelated one reads as a different control.
            tint: preference.visibleWhenSharing ? Theme.Palette.brand : Theme.Palette.muted,
            action: { preference.visibleWhenSharing.toggle() }
        )
    }
}

struct NotchCopyGlyphButton: View {
    let text: () -> String
    var onCopy: () -> Void = {}

    @State private var copied = false
    @State private var flash: Task<Void, Never>?

    var body: some View {
        NotchGlyphButton(
            icon: copied ? "nc-check" : "nc-files-2",
            help: copied ? "Copied" : "Copy summary",
            action: copy
        )
    }

    private func copy() {
        NSPasteboard.copyText(text())
        onCopy()
        // Cancelled rather than left to run: without this, a second tap inside
        // the hold window leaves the first task to clear the check while the
        // user is still looking at the second one.
        flash?.cancel()
        flash = Task {
            await flashConfirmation(set: { copied = true }, reset: { copied = false }, for: 1.5)
        }
    }
}

struct NotchGlyphButton: View {
    let icon: String
    let help: String
    /// Carries state on the glyph itself where a control has two readings and
    /// no honest second icon — muted, or shown-in-screen-shares.
    var tint: Color = Theme.Palette.muted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon)
                .icon(9)
                .foregroundColor(tint)
                .notchGlyphChrome()
        }
        .buttonStyle(.pressable(scale: 0.90))
        .linkCursor()
        // Not `.help`: AppKit's tooltip needs the window to take key focus, and
        // this panel deliberately never does — so the system one never appeared
        // on the notch at all. Compact: one line over a 20pt glyph.
        .glyphTooltip(help)
    }
}
