import SwiftUI

/// The second half of onboarding, run where Nod lives. The window asked who
/// this is; the notch asks for what it needs, one thing per card, and ends on
/// the first question — answered for real, from the calendar and the sessions
/// the account already has.
enum NotchSetupStage: String, Equatable, CaseIterable {
    case intro
    case microphone
    case systemAudio
    case ambient
    case calendar
    case ready
    case firstAsk

    /// The asks, in order — the ones the progress marks count.
    static let asks: [NotchSetupStage] = [.microphone, .systemAudio, .ambient, .calendar]

    var next: NotchSetupStage? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// Where this ask sits among the asks, or nil for the cards that are not one.
    var askIndex: Int? {
        Self.asks.firstIndex(of: self)
    }
}

// MARK: - The card

/// One setup card: what this permission lets Nod do, in one line; the one thing
/// it will not do, in another; and the action. Centred, unlike the rest of the
/// notch, because it is the one moment the surface is talking *to* the person
/// rather than reporting to them.
struct NotchSetupCard<Actions: View, Detail: View>: View {
    let stage: NotchSetupStage
    let title: String
    let subtitle: String
    let onLeave: () -> Void
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    init(
        stage: NotchSetupStage,
        title: String,
        subtitle: String,
        onLeave: @escaping () -> Void,
        @ViewBuilder detail: @escaping () -> Detail = { EmptyView() },
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.stage = stage
        self.title = title
        self.subtitle = subtitle
        self.onLeave = onLeave
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                NotchGlyphButton(icon: "nc-xmark", help: "Finish later", action: onLeave)
            }
            .padding(.bottom, 2)

            if let index = stage.askIndex {
                NotchSetupProgress(current: index, count: NotchSetupStage.asks.count)
                    .padding(.bottom, 12)
            }

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            detail()

            actions()
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Where you are among the asks: one short bar per ask, the ones done or
/// current lit in the brand blue.
struct NotchSetupProgress: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index <= current ? Theme.Palette.brand : Theme.Palette.surfaceStrong)
                    .frame(width: 30, height: 3)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// The quiet way out of a card — "Skip", "Not now", "Continue anyway".
struct NotchSetupSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.Palette.muted)
            .linkCursor()
    }
}

// MARK: - Stages

struct NotchSetupIntro: View {
    let geometry: NotchGeometry
    let onStart: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .intro,
            title: geometry.hasCutout ? "I live in your notch now." : "I live up here now.",
            subtitle: "A few permissions and I'm ready.",
            onLeave: onLeave
        ) {
            NotchActionButton(title: "Let's start", action: onStart)
        }
    }
}

struct NotchSetupMicrophone: View {
    @ObservedObject var permissions: PermissionManager
    let isRequesting: Bool
    let onGrant: () -> Void
    let onSkip: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .microphone,
            title: "This lets me hear your side.",
            subtitle: "Only while a session is recording. Never in between.",
            onLeave: onLeave
        ) {
            VStack(spacing: 10) {
                switch permissions.microphone {
                case .authorized:
                    NotchActionButton(title: "Continue", icon: "nc-check", action: onSkip)
                case .denied:
                    NotchActionButton(title: "Open Settings", action: permissions.openMicrophoneSettings)
                case .notDetermined:
                    NotchActionButton(title: "Grant Microphone", icon: "nc-mic", isLoading: isRequesting, action: onGrant)
                }
                if permissions.microphone != .authorized {
                    NotchSetupSecondaryButton(title: "Skip", action: onSkip)
                }
            }
        }
    }
}

struct NotchSetupSystemAudio: View {
    @ObservedObject var permissions: PermissionManager
    let isRequesting: Bool
    let onAllow: () -> Void
    let onRelaunch: () -> Void
    let onSkip: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .systemAudio,
            title: "This lets me hear the other side.",
            subtitle: "macOS calls it Screen Recording. It's the audio your Mac plays — never your screen.",
            onLeave: onLeave,
            detail: { relaunchHint },
            actions: {
                VStack(spacing: 10) {
                    switch permissions.screenRecording {
                    case .authorized:
                        NotchActionButton(title: "Continue", icon: "nc-check", action: onSkip)
                    case .denied where permissions.requestedScreenRecordingThisSession:
                        NotchActionButton(title: "Quit & Relaunch Nod", action: onRelaunch)
                    case .denied:
                        NotchActionButton(title: "Open Settings", action: permissions.openScreenRecordingSettings)
                    case .notDetermined:
                        NotchActionButton(title: "Allow", icon: "nc-volume-up", isLoading: isRequesting, action: onAllow)
                    }
                    if permissions.screenRecording != .authorized {
                        NotchSetupSecondaryButton(
                            title: permissions.requestedScreenRecordingThisSession ? "Continue anyway" : "Skip",
                            action: onSkip
                        )
                    }
                }
            }
        )
    }

    /// A TCC entry added while this process runs stays invisible to it, so
    /// "did that work?" is a question only a fresh process can answer.
    @ViewBuilder
    private var relaunchHint: some View {
        if permissions.screenRecording != .authorized, permissions.requestedScreenRecordingThisSession {
            VStack(spacing: 4) {
                Text(PermissionManager.relaunchHint)
                if let error = permissions.lastRelaunchError {
                    Text(PermissionManager.relaunchFailureMessage(error))
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.Palette.warning)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
        }
    }
}

/// The ambient ask. Every line here is one `privacy.md` § 3.10(b) makes, and
/// the switch it flips is the same one Settings and the sidebar control flip:
/// off until this click, bounded, and the person's to pause or delete.
struct NotchSetupAmbient: View {
    @ObservedObject var screenContext: ScreenContextService
    let onTurnOn: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .ambient,
            title: "This lets me see what you're working on.",
            subtitle: "Text from the window in front of you, kept \(screenContext.retentionDays) days, never an image. "
                + "Off until you say so, and yours to pause or delete any time.",
            onLeave: onLeave,
            detail: { waitingForTrust },
            actions: {
                VStack(spacing: 10) {
                    if screenContext.isRunning {
                        NotchActionButton(title: "Continue", icon: "nc-check", action: onContinue)
                    } else if screenContext.needsAccessibility {
                        NotchActionButton(title: "Open System Settings", action: AccessibilityAccess.openSystemSettings)
                        NotchSetupSecondaryButton(title: "Continue without it", action: onContinue)
                    } else {
                        NotchActionButton(title: "Turn on", icon: "nc-stack-perspective", action: onTurnOn)
                        NotchSetupSecondaryButton(title: "Not now", action: onSkip)
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var waitingForTrust: some View {
        if screenContext.needsAccessibility {
            Text("Add Nod under Accessibility. I'll notice the moment it's on.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.warning)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
    }
}

/// The calendar ask, in the notch. The rows and every sentence are
/// `CalendarOptionList`'s and `CalendarCopy`'s — the words are policy-bound,
/// and this is the third surface to say them, not a third copy.
struct NotchSetupCalendar: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var integrations: IntegrationService
    let onContinue: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .calendar,
            title: "Which meeting am I in?",
            subtitle: "A calendar tells me what it's called, when it runs and who's invited — "
                + "so notes land on the right meeting and I can say one is starting.",
            onLeave: onLeave,
            detail: {
                VStack(spacing: 8) {
                    CalendarOptionList(calendar: calendar, integrations: integrations)
                    Text(CalendarCopy.assurance)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = integrations.lastError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 12)
            },
            actions: {
                NotchActionButton(title: isAnswered ? "Continue" : "Not now", action: onContinue)
            }
        )
        .task { await integrations.refresh() }
        .onDisappear { integrations.cancelPending() }
    }

    private var isAnswered: Bool {
        CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations)
    }
}

struct NotchSetupReady: View {
    let onTry: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .ready,
            title: "All set.",
            subtitle: "Ask me about your day, your sessions, or what's on your screen.",
            onLeave: onLeave
        ) {
            NotchActionButton(title: "Try it", icon: "nc-sparkle-3", action: onTry)
        }
    }
}

/// The gated last step: Finish lights up only once a real question has come
/// back answered. The product can be used before the flow lets go of it.
struct NotchSetupFirstAsk: View {
    @ObservedObject var chat: KnowledgeChatStore
    /// How many messages the thread had when this card appeared, so an older
    /// answer never reads as the reply to what was just typed.
    let baseline: Int
    let shortcut: String
    let canAskAcrossSessions: Bool
    let onSubmit: (String) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onFinish: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .firstAsk,
            title: "This is how you ask me",
            subtitle: "Press \(shortcut) anywhere, or type here. I'll answer from your calendar and your sessions.",
            onLeave: onLeave,
            detail: {
                VStack(alignment: .leading, spacing: 10) {
                    NotchAskAnswer(
                        chat: chat,
                        baseline: baseline,
                        canAskAcrossSessions: canAskAcrossSessions,
                        maxAnswerHeight: 160,
                        onOpenMeeting: onOpenMeeting
                    )
                    NotchAskComposer(
                        isSending: chat.isSending,
                        suggestions: ["What's on my calendar today?", "What did I do this week?"],
                        onSubmit: onSubmit
                    )
                }
                .padding(.top, 14)
            },
            actions: {
                HStack(spacing: 14) {
                    NotchSetupSecondaryButton(title: "Skip", action: onLeave)
                    NotchActionButton(title: "Finish", action: onFinish)
                        .disabled(!hasAnswer)
                        .opacity(hasAnswer ? 1 : 0.45)
                }
            }
        )
    }

    private var hasAnswer: Bool {
        chat.answer(after: baseline) != nil && !chat.isSending
    }
}

// MARK: - Routing

/// Which setup card the model is on, drawn with the model's own handlers.
struct NotchSetupContent: View {
    @ObservedObject var model: NotchModel
    let stage: NotchSetupStage

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .intro:
            NotchSetupIntro(geometry: model.geometry, onStart: model.advanceSetup, onLeave: model.finishSetup)
        case .microphone:
            NotchSetupMicrophone(
                permissions: model.permissions,
                isRequesting: model.isRequestingSetupPermission,
                onGrant: model.requestMicrophoneFromSetup,
                onSkip: model.skipSetupStage,
                onLeave: model.finishSetup
            )
        case .systemAudio:
            NotchSetupSystemAudio(
                permissions: model.permissions,
                isRequesting: model.isRequestingSetupPermission,
                onAllow: model.requestSystemAudioFromSetup,
                onRelaunch: model.relaunchFromSetup,
                onSkip: model.skipSetupStage,
                onLeave: model.finishSetup
            )
        case .ambient:
            NotchSetupAmbient(
                screenContext: model.screenContext,
                onTurnOn: model.enableAmbientFromSetup,
                onContinue: model.advanceSetup,
                onSkip: model.skipSetupStage,
                onLeave: model.finishSetup
            )
        case .calendar:
            NotchSetupCalendar(
                calendar: model.calendar,
                integrations: model.integrations,
                onContinue: model.advanceSetup,
                onLeave: model.finishSetup
            )
        case .ready:
            NotchSetupReady(onTry: model.advanceSetup, onLeave: model.finishSetup)
        case .firstAsk:
            NotchSetupFirstAsk(
                chat: model.knowledgeChat,
                baseline: model.askBaseline,
                shortcut: model.hotkeys.combo(for: .askNod).displayString,
                canAskAcrossSessions: model.canAskAcrossSessions,
                onSubmit: model.submitSetupAsk,
                onOpenMeeting: model.openMeetingFromAsk,
                onFinish: model.finishSetup,
                onLeave: model.finishSetup
            )
        }
    }
}
