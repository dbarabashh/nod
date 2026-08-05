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
            .id(model.presentation.contentID)
            .transition(.notchContent(reduceMotion: reduceMotion))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch model.presentation {
        case .updateRequired:
            UpdateRequiredNotice(onUpdate: model.updateGate.startUpdate)
        case .dormant:
            Color.clear
        case .capturing:
            NotchCapturing(
                session: model.session,
                audioCapture: model.audioCapture,
                geometry: model.geometry
            )
        case let .invitation(app):
            NotchInvitation(
                app: app,
                onStart: model.acceptInvitation,
                onDismiss: model.declineInvitation,
                onMute: { model.muteInvitation(app) }
            )
        case .controls:
            NotchControls(
                session: model.session,
                audioCapture: model.audioCapture,
                onCollapse: model.close
            )
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

// MARK: - Resting capture indicator

/// The one state that has to work around the hardware: on a notched Mac the
/// middle of this surface is an opaque cut-out, so the level meter goes to its
/// left and the clock to its right.
///
/// Its own view, observing the session and the capture service directly,
/// because both the clock and the meter have to redraw continuously — read
/// through the notch model they would subscribe to the wrong object and sit
/// frozen at 00:00.
private struct NotchCapturing: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var audioCapture: AudioCaptureService
    let geometry: NotchGeometry

    /// Both halves are anchored to the surface's **outer** edges, not to the
    /// cut-out. Anchored inward, the slack lands on the outside — and since the
    /// two are never the same width, a five-bar meter against a five-glyph
    /// clock, the outer margins come out visibly unequal.
    var body: some View {
        HStack(spacing: 0) {
            NotchLevelMeter(
                audioCapture: audioCapture,
                paused: session.meeting == .paused,
                barWidth: 2,
                span: 9
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if geometry.hasCutout {
                Color.clear.frame(width: geometry.cutoutWidth)
            }

            Text(session.elapsedClock)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(session.meeting == .paused ? Theme.Palette.warning : Theme.Palette.ink)
                .monospacedDigit()
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .trailing)
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
