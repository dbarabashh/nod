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
    /// A question being spoken, or answered, while the surface stays at rest:
    /// the pill says listening, then thinking, and only the answer opens it.
    case voice(VoiceAskPhase)
    /// Nod is asking whether to record — from the calendar, or from a call it
    /// can see running. One state, because it is one question: two of them
    /// meant one meeting could be asked about twice.
    case offer(MeetingOffer)
    /// Capturing, and Nod has something to say about what was just said. The
    /// only state the app raises on its own while the user is mid-conversation,
    /// which is why `LiveMeetingAnalyst` is strict about what reaches it.
    case noticed(LiveFinding)
    /// A colleague is recording this meeting. `alsoOffered` is true when the
    /// calendar was about to ask this person to record it themselves — the card
    /// keeps that answer reachable rather than swallowing it.
    case liveRoom(LiveRoom, alsoOffered: Bool)
    /// Capturing, and something the user settled in an earlier session bears on
    /// what is being said now. The only state that speaks about a meeting the
    /// user is not currently in, which is why `LiveMeetingAnalyst+Recall` is
    /// stricter about reaching it than anything else in the app.
    case recalled(LiveRecall)
    /// Capturing, and somebody in the room asked Nod something out loud. The
    /// only state here the user requested, which is why it outranks both of the
    /// ones above it: they interrupt, this one answers.
    /// The meeting bar, tucked away into the hardware cut-out — a pulse and the
    /// elapsed clock, nothing else. Only reachable on a notched display, and
    /// only by the user's own swipe-up over the notch (`NotchModel`'s gesture
    /// state); recording is unaffected either way. Never the default: see
    /// `.meetingBar` for that.
    case tucked(MeetingBarRole)
    /// Capturing — the meeting bar itself, visible for the whole recording
    /// rather than behind a click. One case for all three panels
    /// (`MeetingBarPanel`) rather than a state per panel: switching panels is
    /// a resize of the same surface, not a different surface arriving.
    ///
    /// And one case for both sides of the meeting, for the same reason: a
    /// listener's bar is this bar with `End` swapped for `Leave`. It was briefly
    /// two more cases, and every question the surface asks — does a click close
    /// it, does the panel swap animate, does the tucked pill come back — had to
    /// be answered twice by hand. Two of them were answered wrong, and the
    /// second one stranded a listener in a pill with no way out.
    case meetingBar(MeetingBarRole, MeetingBarPanel)
    /// Idle, and a meeting just ended — the recap, live as it streams in.
    /// Raised on its own, the same way `.noticed` is: the whole point is that
    /// the user sees it without having to open anything. Goes away when the
    /// user dismisses it or starts another recording.
    case recap(RecapState)
    /// Idle, opened by hotkey or menu bar — pick what to capture and start.
    case launch
    /// Idle, and the person has a question — for the sessions, the calendar,
    /// and whatever has been on screen. The one idle state that takes the
    /// keyboard.
    case ask
    /// The second half of onboarding, run in the notch: permissions, the
    /// calendar, and the first question. Outranks everything but the demo and
    /// a required update, because nothing else can happen until it is done.
    case setup(NotchSetupStage)
    /// Confirming which language the output comes back in, on the way to Start.
    case languageConfirm
    /// The recording disclaimer, before the first capture ever runs.
    case consent
    /// Screen Recording is missing and the recording about to start wants
    /// system audio. Asked before capture rather than reported after it, which
    /// is what a silent `systemAudioError` amounted to.
    case systemAudioAccess
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
    case allowance
}

/// Which side of the meeting the bar belongs to.
///
/// The bar is the same object either way — same header, same Ask, same Notes,
/// same fold-away. What differs is authority: the person recording can end the
/// meeting, the person listening can only leave it. Carrying that as a value
/// rather than as a parallel set of presentation cases is what keeps every
/// question the notch asks about "a bar is showing" answerable once.
enum MeetingBarRole: Equatable {
    case host
    case listening(JoinedRoom)

    var room: JoinedRoom? {
        guard case let .listening(room) = self else { return nil }
        return room
    }

    /// Identifies the *side*, not the room: a listener's surface does not become
    /// a different surface because the host's meeting id differs, and making it
    /// one would refire the emergence animation on every rejoin.
    var contentID: String {
        switch self {
        case .host: "host"
        case .listening: "listening"
        }
    }
}

/// The meeting bar's own panel: what is expanded below the always-visible
/// header row (title/timer/status/Ask/Notes/End), and where the Ask box stands
/// whether or not it is the thing expanded.
///
/// Two facts, not one. `expansion` alone is a discriminated state rather than
/// an `isAskOpen`/`isNotesOpen` pair — only one thing can be expanded under the
/// bar at a time, so a pair would only invite a combination the UI was never
/// designed to render. `ask` sits beside it rather than inside `.ask` because a
/// question outlives the panel it was typed into: an answer that takes a while
/// to come back used to be dropped on arrival if the user had looked at Notes
/// or clicked away meanwhile, leaving an empty field to retype into.
struct MeetingBarPanel: Equatable {
    /// What is expanded under the header row, if anything.
    enum Expansion: Equatable {
        /// Nothing expanded — just the header row.
        case passive
        /// The live findings-so-far, as bullets, with real counts.
        case notes
        /// The Ask box, showing whatever `ask` says.
        case ask
    }

    var expansion: Expansion = .passive
    /// A write the Ask box wants to make, waiting on the person.
    ///
    /// On the panel rather than reached for by the view, for the same reason
    /// the findings are: the bar is drawn from one value, and a card that
    /// appeared from somewhere else would be the one piece of it a snapshot
    /// could not reproduce.
    var approval: ChatToolGate.Pending?
    /// Typing → asking → answered, kept across every expansion change until the
    /// next recording starts.
    var ask: AskPhase = .composing
    /// The held key's question, while it is being heard or written down. On
    /// the panel for the reason `approval` is: the bar is drawn from one value.
    var voice: VoiceAskPhase = .idle
    /// An answer arrived while the box was not the thing on screen, so nobody
    /// has laid eyes on it yet. Drives the mark on the Ask button — without it
    /// the answer this panel now keeps alive would be waiting behind a button
    /// that looks exactly like it did before anybody asked anything.
    private(set) var isAnswerUnseen = false

    /// Whether the Ask box is what is expanded. Asked by both bars, so it lives
    /// on the panel rather than being restated as a private helper on each.
    var isAsk: Bool {
        expansion == .ask
    }

    var isNotes: Bool {
        expansion == .notes
    }

    /// A question is out and its answer is still coming, whatever the bar
    /// happens to be showing meanwhile.
    var isAnswering: Bool {
        ask == .loading
    }

    /// A question waiting on the person rather than on a product. Worth telling
    /// apart from `isAnswering`: one is a spinner, the other is a decision
    /// nobody has made yet, and folding the panel away while it stands leaves
    /// the meeting's work unfinished.
    var isAwaitingApproval: Bool {
        approval != nil
    }

    /// A question is on its way. Nothing has been missed yet.
    mutating func startAsking() {
        ask = .loading
        isAnswerUnseen = false
    }

    /// The finished ask, landed. An answer the user watched arrive needs no
    /// mark; one that landed behind a folded panel or the Notes list does.
    mutating func land(_ phase: AskPhase) {
        ask = phase
        isAnswerUnseen = !isAsk
    }

    /// Opening the box is reading what is in it.
    mutating func expand(_ next: Expansion) {
        expansion = next
        if isAsk { isAnswerUnseen = false }
    }

    /// Identity is the expanded panel alone — not the phase inside it. An
    /// answer landing while Notes is open updates the bar in place rather than
    /// re-emerging it, and the Ask box keeps a half-typed follow-up question
    /// across its own composing → loading → answered run: re-identifying the
    /// surface throws that view's state away, which is the same "type it
    /// again" this panel exists to prevent.
    var contentID: String {
        switch expansion {
        case .passive: "passive"
        case .notes: "notes"
        case .ask: "ask"
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
        switch expansion {
        case .passive: 420
        case .notes: 440
        case .ask: 450
        }
    }
}

/// Where the Ask box is in its one-shot round trip. One shape for a typed
/// question, a tapped suggestion chip, and "Summarize" alike — all three are
/// "some text goes to the live analyst, some text comes back."
/// Where a spoken question is: the key is down and the microphone is open,
/// or the key is up and the clip is on its way to text. `idle` between.
enum VoiceAskPhase: Equatable {
    case idle
    case listening
    case transcribing
    /// The words are understood and the answer is being worked out.
    case thinking
    /// The voice is saying these words. Escape cuts it off.
    case speaking(String)
    /// Nothing usable came of the hold, and why, for a moment before the
    /// field comes back — a row that simply vanished would say nothing.
    case failed(String)
}

extension VoiceAskPhase {
    var isSpeaking: Bool {
        if case .speaking = self { return true }
        return false
    }

    /// The pill's one word for the phase.
    var restingLabel: String {
        switch self {
        case .idle, .listening: "Listening…"
        case .transcribing, .thinking: "Thinking…"
        case .speaking: "Speaking…"
        case let .failed(reason): reason
        }
    }

    /// Half the pill: the label side, measured, and never narrower than the
    /// indicator on the other side. Both halves stretch equally, so a word
    /// wider than its half would be drawn under the hardware, not truncated —
    /// which is how "Listening…" went missing.
    var restingSideWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let text = (restingLabel as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return max(text, 40)
    }
}

enum AskPhase: Equatable {
    case composing
    case loading
    case answered(question: String, answer: String)
    /// Keeps the question that failed, so retrying doesn't ask the user to
    /// retype it.
    case failed(question: String)
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
        case .voice: "voice"
        case let .offer(offer): "offer.\(offer.identity)"
        case let .liveRoom(room, _): "liveRoom.\(room.hostName ?? "someone")"
        case let .noticed(finding): "noticed.\(finding.id.uuidString)"
        case let .recalled(recall): "recalled.\(recall.id.uuidString)"
        case let .tucked(role): "tucked.\(role.contentID)"
        case let .meetingBar(role, panel): "meetingBar.\(role.contentID).\(panel.contentID)"
        case let .recap(state): "recap.\(state.contentID)"
        case .launch: "launch"
        case .ask: "ask"
        case let .setup(stage): "setup.\(stage.rawValue)"
        case .languageConfirm: "languageConfirm"
        case .consent: "consent"
        case .systemAudioAccess: "systemAudioAccess"
        case .alert(.autoEnd): "alert.autoEnd"
        case .alert(.saveFailed): "alert.saveFailed"
        case .alert(.allowance): "alert.allowance"
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
        case .dormant, .tucked, .voice: false
        case .updateRequired, .offer, .liveRoom, .noticed, .recalled, .meetingBar, .recap, .launch, .ask, .setup,
             .languageConfirm, .consent, .systemAudioAccess, .alert: true
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
        case .liveRoom: return 396
        case .noticed, .recalled, .recap: return 360
        case let .meetingBar(_, panel): return panel.surfaceWidth
        case .launch: return 384
        case .ask: return 440
        case let .setup(stage): return stage == .calendar ? 440 : 400
        case .languageConfirm: return 340
        case .consent: return 380
        case .systemAudioAccess: return 400
        case .alert: return 396
        case .dormant:
            return geometry.hasCutout ? geometry.collapsedSize.width + flare : nil
        case .tucked:
            return geometry.hasCutout ? geometry.collapsedSize.width + flare + 124 : nil
        case let .voice(phase):
            return geometry.hasCutout ? geometry.collapsedSize.width + flare + 24 + phase.restingSideWidth * 2 : nil
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
        case .dormant, .tucked, .voice:
            geometry.collapsedSize.height
        case .updateRequired, .offer, .liveRoom, .noticed, .recalled, .meetingBar, .recap, .launch, .ask, .setup,
             .languageConfirm, .consent, .systemAudioAccess, .alert:
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
