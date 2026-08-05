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
    /// A call is running and nobody has answered the offer to record it.
    case invitation(ConferencingApp)
    /// Capturing, at rest — a pulse and the elapsed clock.
    case capturing
    /// Capturing, opened — the transport controls.
    case controls
    /// Idle, opened by hotkey or menu bar — pick what to capture and start.
    case launch
    /// Confirming which language the output comes back in, on the way to Start.
    case languageConfirm
    /// The recording disclaimer, before the first capture ever runs.
    case consent
    /// Something that needs an answer and then goes away again.
    case alert(NotchAlert)
}

/// The transient states: raised over whatever the notch was showing, and gone
/// once answered.
enum NotchAlert: Equatable {
    case autoEnd(AutoEndPrompt)
    case saveFailed(String)
}

extension NotchPresentation {
    /// Identity for SwiftUI. Without it a state change is one view updating in
    /// place, and content that updates in place never runs a transition — the
    /// emergence animation would simply not fire.
    var contentID: String {
        switch self {
        case .updateRequired: "updateRequired"
        case .dormant: "dormant"
        case let .invitation(app): "invitation.\(app.rawValue)"
        case .capturing: "capturing"
        case .controls: "controls"
        case .launch: "launch"
        case .languageConfirm: "languageConfirm"
        case .consent: "consent"
        case .alert(.autoEnd): "alert.autoEnd"
        case .alert(.saveFailed): "alert.saveFailed"
        }
    }

    /// Whether this state is opened up rather than resting on the menu bar.
    /// Drives outside-click dismissal, the drop shadow, and whether the height
    /// comes from the content or from the hardware.
    var isOpen: Bool {
        switch self {
        case .dormant, .capturing: false
        case .updateRequired, .invitation, .controls, .launch, .languageConfirm, .consent, .alert: true
        }
    }

    /// The whole surface's width, including the flare margin the top curves
    /// need on a notched Mac.
    func surfaceWidth(in geometry: NotchGeometry) -> CGFloat {
        let flare = geometry.flare * 2
        return switch self {
        case .updateRequired: 400
        case .dormant: geometry.collapsedSize.width + flare
        case .capturing: geometry.collapsedSize.width + flare + 124
        case .invitation: 384
        case .controls: 340
        case .launch: 384
        case .languageConfirm: 340
        case .consent: 380
        case .alert: 396
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
        case .dormant, .capturing:
            geometry.collapsedSize.height
        case .updateRequired, .invitation, .controls, .launch,
             .languageConfirm, .consent, .alert:
            nil
        }
    }

    /// How rounded the bottom corners are. The resting surface takes its radius
    /// from the cut-out it is covering so the two read as one shape; an opened
    /// one is a card and rounds like one.
    func bottomRadius(in geometry: NotchGeometry) -> CGFloat {
        isOpen ? Theme.Radii.card : geometry.collapsedSize.height / 3
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
