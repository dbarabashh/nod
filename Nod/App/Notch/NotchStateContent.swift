import SwiftUI

/// What sits inside the notch silhouette for the current state.
///
/// Split from `NotchView` so the shape and its animation stay one small thing:
/// this file is the only place that knows what any given state looks like.
struct NotchStateContent: View {
    @ObservedObject var model: NotchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            // Applied once from `isOpen` rather than case by case: written out
            // per state it was a second copy of the open/closed list, kept in
            // step by hand.
            .modifier(OpenedCard(geometry: model.geometry, isOpen: model.presentation.isOpen))
            // Pinned to the target width immediately, opted out of `NotchView`'s
            // ambient morph spring: without this, a wrapped label lays itself out
            // fresh at every interpolated width while the surface grows around
            // it, and the word-wrap jumping mid-flight is what reads as the
            // text gluing together rather than the surface simply widening
            // around already-settled text. `NotchView`'s own `.frame` still
            // animates the surface (and therefore the mask) at its usual pace;
            // this only freezes what the *content* is laid out against.
            .frame(width: model.presentation.surfaceWidth(in: model.geometry))
            .transaction { $0.animation = nil }
            .id(model.presentation.contentID)
            .transition(.notchContent(reduceMotion: reduceMotion))
            .environment(\.colorScheme, .dark)
            .overlay(alignment: .top) { gestureZone }
    }

    /// The notch's own swipe-to-hide/reveal hotspot — sized to the actual
    /// hardware cut-out, not the wider bar around it, and only ever mounted
    /// on a display that has one. See `NotchGestureZone`.
    @ViewBuilder
    private var gestureZone: some View {
        if model.geometry.hasCutout, showsGestureZone {
            NotchGestureZone(onSwipeUp: model.hideMeetingBar, onSwipeDown: model.revealMeetingBar)
                .frame(width: model.geometry.cutoutWidth, height: model.geometry.cutoutHeight)
        }
    }

    private var showsGestureZone: Bool {
        switch model.presentation {
        case .tucked, .meetingBar: true
        case .updateRequired, .dormant, .offer, .noticed, .recap, .launch,
             .languageConfirm, .consent, .alert, .demo: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case .updateRequired:
            UpdateRequiredNotice(onUpdate: model.updateGate.startUpdate)
        case .dormant:
            // Zero-sized, not `Color.clear`: a bare `Color` has no intrinsic
            // size and expands to whatever it is offered, so without a cut-out
            // to pin the width against it filled the entire canvas and painted
            // an empty black slab under the menu bar.
            Color.clear.frame(width: 0, height: 0)
        case .tucked:
            NotchTucked(
                session: model.session,
                audioCapture: model.audioCapture,
                geometry: model.geometry
            )
        case let .noticed(finding):
            NotchNotice(finding: finding, onDismiss: model.rejectNotice)
        case let .offer(offer):
            NotchOffer(
                offer: offer,
                userName: model.userName,
                context: model.callContext,
                mutableApp: model.offers.mutableApp,
                onStart: model.acceptOffer,
                onDismiss: model.declineOffer,
                onMute: model.muteOffer
            )
        case let .meetingBar(panel):
            NotchMeetingBar(
                panel: panel,
                session: model.session,
                audioCapture: model.audioCapture,
                language: model.language,
                onToggleAsk: model.toggleAsk,
                onToggleNotes: model.toggleNotes,
                onSubmitAsk: model.submitAsk,
                onSummarize: model.askSummarize,
                onOpenLibrary: model.openLibrary,
                onCollapse: model.geometry.hasCutout ? { model.hideMeetingBar() } : nil
            )
        case let .recap(state):
            NotchRecapCard(state: state, onClose: model.session.dismissEndedMeeting)
        case .launch:
            NotchLaunch(session: model.session, onStart: model.requestStart)
        case .languageConfirm:
            languageConfirm
        case .consent:
            ConsentDisclaimerView(
                strings: .english,
                onCancel: model.cancelGate,
                onAcknowledge: model.acknowledgeConsent
            )
        case let .alert(alert):
            alertBody(alert)
        case let .demo(stage):
            DemoStageView(stage: stage, director: model.demo, geometry: model.geometry)
        }
    }

    // MARK: - Gates and alerts

    private var languageConfirm: some View {
        MeetingLanguagePrompt(
            language: Binding(
                get: { model.language.current },
                set: { model.language.current = $0 }
            ),
            askEachTime: $model.askLanguageEachTime,
            onStart: model.confirmLanguage,
            onCancel: model.cancelGate
        )
    }

    @ViewBuilder
    private func alertBody(_ alert: NotchAlert) -> some View {
        switch alert {
        case let .autoEnd(prompt):
            InactivityPrompt(
                prompt: prompt,
                keepTitle: model.session.selectedKind.continueActionTitle,
                onKeep: model.session.keepRecording,
                onEnd: model.session.endMeeting
            )
        case let .saveFailed(message):
            SaveErrorToast(
                message: message,
                canRetry: true,
                onRetry: model.session.retryPendingSaves,
                onDismiss: model.session.dismissSaveError
            )
        }
    }
}

// MARK: - Tucked indicator

/// What's left showing once the meeting bar is swiped away into the notch: on
/// a notched Mac the middle of this surface is an opaque cut-out, so the level
/// meter goes to its left and the clock to its right. Never the default —
/// only reachable via `NotchGestureZone`'s swipe-up, and only where there is a
/// cut-out to tuck into.
///
/// Its own view, observing the session and the capture service directly,
/// because both the clock and the meter have to redraw continuously — read
/// through the notch model they would subscribe to the wrong object and sit
/// frozen at 00:00.
private struct NotchTucked: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var audioCapture: AudioCaptureService
    let geometry: NotchGeometry

    /// Straddling the cut-out, the two halves are anchored to the surface's
    /// **outer** edges: anchored inward the slack lands on the outside, and
    /// since a five-bar meter and a five-glyph clock are never the same width,
    /// the outer margins come out visibly unequal.
    ///
    /// Without a cut-out there is nothing to straddle, so they simply sit
    /// together. Spreading them then would leave a gap of empty black in the
    /// middle exactly where the hardware isn't.
    var body: some View {
        HStack(spacing: geometry.hasCutout ? 0 : 8) {
            NotchLevelMeter(
                audioCapture: audioCapture,
                paused: session.meeting == .paused,
                barWidth: 2,
                span: 9
            )
            .frame(maxWidth: geometry.hasCutout ? .infinity : nil, alignment: .leading)

            if geometry.hasCutout {
                Color.clear.frame(width: geometry.cutoutWidth)
            }

            Text(session.elapsedClock)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(session.meeting == .paused ? Theme.Palette.warning : Theme.Palette.ink)
                .monospacedDigit()
                .fixedSize()
                .frame(maxWidth: geometry.hasCutout ? .infinity : nil, alignment: .trailing)
        }
        .padding(.horizontal, geometry.flare + 12)
    }
}

// MARK: - Layout helpers

/// Padding for an opened state: clear of the hardware cut-out at the top, and
/// clear of the flare margin the notch silhouette's top curves occupy. A resting
/// state lays itself out inside the cut-out and takes none of it.
private struct OpenedCard: ViewModifier {
    let geometry: NotchGeometry
    let isOpen: Bool

    func body(content: Content) -> some View {
        content
            .padding(.top, isOpen ? topInset : 0)
            .padding(.horizontal, isOpen ? geometry.flare + 14 : 0)
            .padding(.bottom, isOpen ? 14 : 0)
    }

    private var topInset: CGFloat {
        geometry.hasCutout ? geometry.collapsedSize.height + 8 : 12
    }
}
