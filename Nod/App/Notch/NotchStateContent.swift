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
        // The swipe folds a listening bar away exactly as it folds a recording
        // one — same gesture, same flag, same resting shape.
        case .tucked, .meetingBar, .listening, .listeningTucked: true
        case .updateRequired, .dormant, .offer, .liveRoom, .noticed, .recalled, .recap, .launch,
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
        case let .liveRoom(room, alsoOffered):
            LiveRoomCard(
                room: room,
                isJoining: model.rooms.isJoining,
                onJoin: model.joinLiveRoom,
                onDismiss: model.rooms.forgetRoom,
                onRecordInstead: alsoOffered ? { model.acceptOffer() } : (nil as (() -> Void)?)
            )
        case let .listening(room, panel):
            NotchListeningBar(
                rooms: model.rooms,
                room: room,
                panel: panel,
                language: model.language,
                onToggleAsk: model.toggleAsk,
                onToggleNotes: model.toggleNotes,
                onSubmitAsk: model.submitAsk,
                onSummarize: model.askSummarize,
                onCollapse: model.hideMeetingBar,
                onOpenLibrary: model.openLibrary,
                geometry: model.geometry
            )
        case let .listeningTucked(room):
            NotchListeningTucked(room: room, geometry: model.geometry)
        case let .noticed(finding):
            NotchNotice(finding: finding, onDismiss: model.rejectNotice)
        case let .recalled(recall):
            NotchRecall(
                recall: recall,
                onOpenSource: { model.openRecallSource(recall) },
                onDismiss: model.dismissRecall
            )
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
                rooms: model.rooms,
                panel: panel,
                session: model.session,
                audioCapture: model.audioCapture,
                language: model.language,
                onToggleAsk: model.toggleAsk,
                onToggleNotes: model.toggleNotes,
                onSubmitAsk: model.submitAsk,
                onSummarize: model.askSummarize,
                onOpenLibrary: model.openLibrary,
                onCollapse: { model.hideMeetingBar() },
                panelSharing: model.panelSharing,
                geometry: model.geometry
            )
        case let .recap(state):
            NotchRecapCard(
                state: state,
                onClose: model.session.dismissEndedMeeting,
                onExpand: model.openMeeting,
                onCopy: model.session.recordRecapCopied
            )
        case .launch:
            NotchLaunch(
                session: model.session,
                isLoading: model.isRequestingRecording,
                error: model.recordingStartError,
                onStart: model.requestStart
            )
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
        case .allowance:
            StarterAllowanceGate(
                billing: model.billing,
                recommendPro: model.shouldRecommendProUpgrade,
                onDismiss: model.dismissAllowanceGate,
                onUpgrade: model.openSubscriptionFromAllowanceGate,
                onTopUp: model.buyStarterTopUp
            )
        }
    }
}

/// Shown when a healthy Starter plan has spent this period's hours. It sells the
/// two honest ways forward and says out loud that a meeting in progress is never
/// interrupted — because that is the promise the enforcement is built around.
private struct StarterAllowanceGate: View {
    @ObservedObject var billing: BillingService
    let recommendPro: Bool
    let onDismiss: () -> Void
    let onUpgrade: () -> Void
    let onTopUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image("nc-hourglass")
                    .icon(17)
                    .foregroundStyle(Theme.Palette.warning)
                Text("You've used this period's hours")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
            }

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let error = billing.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()

                Spacer(minLength: 0)

                Button("Upgrade to Pro", action: onUpgrade)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .linkCursor()

                NotchActionButton(
                    title: "Buy 5 hours · $12",
                    isLoading: billing.isStartingTopUp,
                    action: onTopUp
                )
            }
        }
    }

    private var detail: String {
        recommendPro
            ? "You've already topped up this period, so Pro's unlimited hours are probably the cheaper answer. A meeting already in progress is never stopped."
            : "Add 5 meeting hours for $12, or move to Pro for unlimited hours. A meeting already in progress is never stopped."
    }
}

// MARK: - Tucked indicator

/// What's left showing once the meeting bar is swiped away into the notch: on
/// a notched Mac the middle of this surface is an opaque cut-out, so the level
/// meter goes to its left and the clock to its right. Never the default —
/// reached by the bar's own chevron, or by `NotchGestureZone`'s swipe-up where
/// there is a cut-out to swipe over. A click anywhere on it brings the bar
/// back (`NotchView` → `toggleOpen`), which is the only way out on a floating
/// panel, where the gesture zone is not mounted.
///
/// Its own view, observing the session directly, because the clock has to
/// redraw continuously — read through the notch model it would subscribe to the
/// wrong object and sit frozen at 00:00. `audioCapture` is a plain reference:
/// the only thing read off it is `inputLevel`, which `NotchLevelMeter` observes
/// on its own.
private struct NotchTucked: View {
    @ObservedObject var session: MeetingSession
    let audioCapture: AudioCaptureService
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
            inputIndicator
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

    /// Muted replaces the meter rather than tinting it: mute zeroes
    /// `inputLevel`, so the bars flatten either way and a flat meter is exactly
    /// what a quiet room looks like. Tucked away, this is the whole of what the
    /// screen says about the microphone — with only the meter there, "they
    /// can't hear me" looks identical to "nobody is talking".
    @ViewBuilder
    private var inputIndicator: some View {
        if session.micMuted {
            Image("nc-mic-slash")
                .icon(11)
                .foregroundColor(Theme.Palette.controlMicMuted)
        } else {
            NotchLevelMeter(
                level: audioCapture.inputLevel,
                paused: session.meeting == .paused,
                barWidth: 2,
                span: 9
            )
        }
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
