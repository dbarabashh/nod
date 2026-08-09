import SwiftUI

/// What the notch surface is showing right now.
///
/// One value drives both the silhouette and its content, so the surface can
/// never be sized for one state while rendering another — the mismatch that
/// made the old floating panel need a manual repaint on every reshape.
enum NotchPresentation: Equatable {
    /// The build is below the server's minimum and can no longer record.
    /// Outranks everything: it is the only state that has to stop a capture
    /// from starting at all.
    case updateRequired
    /// Out of the way: the bare cut-out with no Nod chrome on it at all.
    case dormant
    /// Nod is asking whether to record — from the calendar, or from a call it
    /// can see running. One state, because it is one question: two of them
    /// meant one meeting could be asked about twice.
    case offer(MeetingOffer)
    /// Capturing, and Nod has something to say about what was just said. The
    /// only state the app raises on its own while the user is mid-conversation,
    /// which is why `LiveMeetingAnalyst` is strict about what reaches it.
    case noticed(LiveFinding)
    /// The meeting bar, tucked away into the hardware cut-out — a pulse and the
    /// elapsed clock, nothing else. Only reachable on a notched display, and
    /// only by the user's own swipe-up over the notch (`NotchModel`'s gesture
    /// state); recording is unaffected either way. Never the default: see
    /// `.meetingBar` for that.
    case tucked
    /// Capturing — the meeting bar itself, visible for the whole recording
    /// rather than behind a click. One case for all three panels
    /// (`MeetingBarPanel`) rather than a state per panel: switching panels is
    /// a resize of the same surface, not a different surface arriving.
    case meetingBar(MeetingBarPanel)
    /// Idle, and a meeting just ended — the recap, live as it streams in.
    /// Raised on its own, the same way `.noticed` is: the whole point is that
    /// the user sees it without having to open anything. Goes away when the
    /// user dismisses it or starts another recording.
    case recap(RecapState)
    /// Idle, opened by hotkey or menu bar — pick what to capture and start.
    case launch
    /// Confirming which language the output comes back in, on the way to Start.
    case languageConfirm
    /// The recording disclaimer, before the first capture ever runs.
    case consent
    /// Something that needs an answer and then goes away again.
    case alert(NotchAlert)
    /// A frame of the scripted demo. Routed through the same enum as everything
    /// else so it inherits the silhouette, the springs and the fold-between
    /// transition rather than being a second notch bolted alongside the first.
    case demo(DemoStage)
}

/// The transient states: raised over whatever the notch was showing, and gone
/// once answered.
enum NotchAlert: Equatable {
    case autoEnd(AutoEndPrompt)
    case saveFailed(String)
}

/// The meeting bar's own panel, expanded below the always-visible header row
/// (title/timer/status/Ask/Notes/End) or not expanded at all. A discriminated
/// state rather than an `isAskOpen`/`isNotesOpen`/`askPhase` trio of
/// independent flags — the three are mutually exclusive by construction (only
/// one thing can be expanded under the bar at a time), so a trio would only
/// invite a combination the UI was never designed to render.
enum MeetingBarPanel: Equatable {
    /// Nothing expanded — just the header row.
    case passive
    /// The live findings-so-far, as bullets, with real counts.
    case notes
    /// The Ask box, wherever it is in typing → asking → answered.
    case ask(AskPhase)

    var contentID: String {
        switch self {
        case .passive: "passive"
        case .notes: "notes"
        case let .ask(phase): "ask.\(phase.contentID)"
        }
    }

    /// Kept close to what every other opened state on this surface already
    /// uses (340-400pt, see `NotchPresentation.surfaceWidth`) rather than the
    /// wider system-surface sizing this design started from — a bar that
    /// dwarfs the notch it grew out of reads as a window, not a continuation
    /// of it. Sized to fit the header's own content (dot, mic, title, clock,
    /// status, Ask/Notes/End, the tuck chevron) without any of it wrapping —
    /// narrower than this and the buttons start compressing into a vertical
    /// letter-stack rather than staying on one line. Notes/Ask ask for a
    /// little more only because they add a second block of content below
    /// the header.
    var surfaceWidth: CGFloat {
        switch self {
        case .passive: 420
        case .notes: 440
        case .ask: 450
        }
    }
}

/// Where the Ask box is in its one-shot round trip. One shape for a typed
/// question, a tapped suggestion chip, and "Summarize" alike — all three are
/// "some text goes to the live analyst, some text comes back."
enum AskPhase: Equatable {
    case composing
    case loading
    case answered(question: String, answer: String)
    /// Keeps the question that failed, so retrying doesn't ask the user to
    /// retype it.
    case failed(question: String)

    var contentID: String {
        switch self {
        case .composing: "composing"
        case .loading: "loading"
        case .answered: "answered"
        case .failed: "failed"
        }
    }
}

/// Where the recap card is, mirroring `MeetingStore`'s own generating/ready/
/// failed states rather than introducing a second copy of them — `NotchModel`
/// resolves one of these straight from `meetingStore` each time it changes.
enum RecapState: Equatable {
    case generating
    case ready(Meeting)
    case failed(String)

    var contentID: String {
        switch self {
        case .generating: "generating"
        case let .ready(meeting): "ready.\(meeting.id.uuidString)"
        case .failed: "failed"
        }
    }
}

extension NotchPresentation {
    /// Identity for SwiftUI. Without it a state change is one view updating in
    /// place, and content that updates in place never runs a transition — the
    /// emergence animation would simply not fire.
    var contentID: String {
        switch self {
        case .updateRequired: "updateRequired"
        case .dormant: "dormant"
        case let .offer(offer): "offer.\(offer.identity)"
        case let .noticed(finding): "noticed.\(finding.id.uuidString)"
        case .tucked: "tucked"
        case let .meetingBar(panel): "meetingBar.\(panel.contentID)"
        case let .recap(state): "recap.\(state.contentID)"
        case .launch: "launch"
        case .languageConfirm: "languageConfirm"
        case .consent: "consent"
        case .alert(.autoEnd): "alert.autoEnd"
        case .alert(.saveFailed): "alert.saveFailed"
        case let .demo(stage): stage.contentID
        }
    }

    /// Whether this state is a full card, as opposed to a line or the bare
    /// surface. Only a card has to get out of the way before the next thing
    /// arrives — see `NotchModel.apply`.
    var occupiesCard: Bool {
        guard case let .demo(stage) = self else { return isOpen }
        return stage.form == .card
    }

    /// Whether this state is opened up rather than resting on the menu bar.
    /// Drives outside-click dismissal, the drop shadow, and whether the height
    /// comes from the content or from the hardware.
    var isOpen: Bool {
        switch self {
        case .dormant, .tucked: false
        case .updateRequired, .offer, .noticed, .meetingBar, .recap, .launch, .languageConfirm, .consent, .alert: true
        case let .demo(stage): stage.form != .resting
        }
    }

    /// The whole surface's width, or nil to let the content decide.
    ///
    /// A resting state is only pinned when there is a cut-out to straddle: the
    /// width has to reach past the hardware on both sides, so it is computed
    /// from the hole. Without a hole there is nothing to reach past, and a
    /// pinned width just leaves a gap of empty black in the middle where the
    /// notch used to be — so the content sizes itself instead.
    func surfaceWidth(in geometry: NotchGeometry) -> CGFloat? {
        let flare = geometry.flare * 2
        switch self {
        case .updateRequired: return 400
        case .offer: return 384
        case .noticed, .recap: return 360
        case let .meetingBar(panel): return panel.surfaceWidth
        case .launch: return 384
        case .languageConfirm: return 340
        case .consent: return 380
        case .alert: return 396
        case .dormant:
            return geometry.hasCutout ? geometry.collapsedSize.width + flare : nil
        case .tucked:
            return geometry.hasCutout ? geometry.collapsedSize.width + flare + 124 : nil
        case let .demo(stage):
            guard stage.form == .resting else { return stage.surfaceWidth }
            guard geometry.hasCutout else { return nil }
            // Both halves are `maxWidth: .infinity`, so the surface has to carry
            // the cut-out, the bar's own padding, and twice the wider half —
            // which is the label side. Derived from the label itself: the tail
            // of a word that does not fit is drawn under the hardware rather
            // than truncated, so nothing on screen says it went wrong.
            return geometry.collapsedSize.width + flare
                + DemoRestingBar.inset * 2
                + stage.restingSideWidth * 2
        }
    }

    /// A fixed height, or nil to let the content decide.
    ///
    /// Only the two resting states pin a height: they have to cover the cut-out
    /// exactly, and one pixel of daylight around a hardware notch is instantly
    /// visible. Everything opened is content-sized, so a wrapped line or a
    /// larger system text size grows the surface instead of being clipped by it.
    func surfaceHeight(in geometry: NotchGeometry) -> CGFloat? {
        // Exhaustive, not `default: nil`: a new *resting* state added later
        // would otherwise silently take its content's height instead of the
        // cut-out's, and leave daylight around the hardware notch.
        switch self {
        case .dormant, .tucked:
            geometry.collapsedSize.height
        case .updateRequired, .offer, .noticed, .meetingBar, .recap, .launch,
             .languageConfirm, .consent, .alert:
            nil
        case let .demo(stage):
            stage.form == .resting ? geometry.collapsedSize.height : nil
        }
    }

    /// How rounded the corners are.
    ///
    /// An opened surface is a card either way. At rest the two cases diverge:
    /// over a cut-out the radius has to match the hardware's own curvature, so
    /// it is derived from the cut-out's height and stays a shallow rounding.
    /// Free-floating there is nothing to match, and a shallow rounding on a
    /// 26pt bar reads as a rounded rectangle rather than the pill it should be —
    /// so it goes fully round.
    func bottomRadius(in geometry: NotchGeometry) -> CGFloat {
        guard !isOpen else { return Theme.Radii.card }
        let height = geometry.collapsedSize.height
        return geometry.hasCutout ? height / 3 : height / 2
    }
}

/// The springs the surface morphs on.
///
/// Three, not one, because opening and closing are not the same gesture:
/// something arriving may overshoot and settle, something leaving may not — a
/// bounce on the way out reads as the surface being reluctant to go. Between two
/// opened states it is neither arriving nor leaving, so it only needs to be
/// quick.
///
/// The springs the surface morphs on — the "balanced" tuning from the reference
/// notch implementation, which is the feel this surface was designed against.
///
/// Deliberately **not** the app's `.momentum` / `.standard` tokens, close as
/// they look. Those are tuned for controls moving inside a window; at 0.32
/// response a whole surface changing shape arrives flat.
///
/// Three of them, because the directions are not symmetric. The one number that
/// matters most is that **closing is slower than opening** (0.55 against 0.45):
/// a surface that snaps shut at the speed it opened reads as being yanked away,
/// where a longer close reads as it settling back into the bezel.
enum NotchAnimation {
    /// Shared damping. Below 1 by enough to carry a little overshoot — that
    /// overshoot is what gives the surface weight instead of looking redrawn.
    private static let damping: Double = 0.77

    static func morph(from old: NotchPresentation, to new: NotchPresentation, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return .easeInOut(duration: 0.12) }
        if !old.isOpen, new.isOpen { return opening }
        if old.isOpen, !new.isOpen { return closing }
        return converting
    }

    /// Opening up out of the bezel.
    static let opening = Animation.spring(response: 0.45, dampingFraction: damping)

    /// Folding back into it. Longer, and on SwiftUI's own damping rather than
    /// ours, so it comes to rest without a second bounce.
    static let closing = Animation.spring(response: 0.55)

    /// Between two opened states, and for the resting geometry — neither
    /// arriving nor leaving, just rearranging.
    static let converting = Animation.spring(response: 0.47)

    /// How long the surface rests folded shut between two opened states. Long
    /// enough that the fold reads as complete — cut short, the two halves
    /// overlap and it goes back to looking like a resize.
    static let hideShowDelay: TimeInterval = 0.34

    /// Content entering and leaving. The same spring both ways: the surface
    /// around it is already asymmetric, and giving the content its own
    /// asymmetry on top made the two disagree about when the morph was over.
    static let contentTransition = Animation.spring(response: 0.45, dampingFraction: damping)
}

extension AnyTransition {
    /// How content enters and leaves the surface.
    ///
    /// Asymmetric, because the two directions have different jobs. Arriving,
    /// content scales up out of the top edge as a blur clears — that is what
    /// makes it read as emerging *from* the notch instead of being
    /// cross-dissolved on top of it.
    ///
    /// Leaving, it does **not** scale: the surface is closing over it at the
    /// same moment, and content shrinking inside a shrinking surface is the
    /// doubled-up collapse that reads as the card being crushed. It only blurs
    /// and fades, quickly, so it is gone before the silhouette finishes — what
    /// the eye is left with is the notch closing, not a card being folded away.
    static func notchContent(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(
                active: NotchContentEmergence(blur: 10, scale: 0.62),
                identity: NotchContentEmergence(blur: 0, scale: 1)
            )
            .combined(with: .opacity)
            .animation(NotchAnimation.contentTransition),
            removal: .modifier(
                active: NotchContentEmergence(blur: 8, scale: 1),
                identity: NotchContentEmergence(blur: 0, scale: 1)
            )
            .combined(with: .opacity)
            .animation(NotchAnimation.contentTransition)
        )
    }
}

private struct NotchContentEmergence: ViewModifier {
    let blur: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 1, y: scale, anchor: .top)
            .blur(radius: blur)
    }
}
