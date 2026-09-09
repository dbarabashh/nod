import SwiftUI

/// The second half of onboarding, run where Nod lives. The window has heard
/// the person once; the notch asks for the two things it cannot do without —
/// the microphone and a calendar — one per card, then asks for the week: a
/// real capture, spoken, that comes back as a recap with next steps, which
/// is the product doing the thing it is for. Hearing the other side of a
/// call and reading the screen are asked for later, where first needed.
enum NotchSetupStage: String, Equatable, CaseIterable {
    case intro
    case microphone
    case calendar
    case plans

    /// The asks, in order — the ones the progress marks count.
    static let asks: [NotchSetupStage] = [.microphone, .calendar]

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

/// The first capture, offered rather than explained: what is on the week,
/// said out loud, becomes the first recap and the first action items. A
/// voice note, so it needs nothing the person has not already granted.
struct NotchSetupPlans: View {
    let onStart: () -> Void
    let onSkip: () -> Void
    let onLeave: () -> Void

    var body: some View {
        NotchSetupCard(
            stage: .plans,
            title: "Now, what's on your plate this week?",
            subtitle: "Say it out loud, the way you'd tell a colleague. Stop when you're done and I'll write it up, next steps included.",
            onLeave: onLeave
        ) {
            VStack(spacing: 10) {
                NotchActionButton(title: "Start talking", icon: "nc-mic", action: onStart)
                NotchSetupSecondaryButton(title: "Not now", action: onSkip)
            }
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
        case .calendar:
            NotchSetupCalendar(
                calendar: model.calendar,
                integrations: model.integrations,
                onContinue: model.advanceSetup,
                onLeave: model.finishSetup
            )
        case .plans:
            NotchSetupPlans(
                onStart: model.startFirstCaptureFromSetup,
                onSkip: model.finishSetup,
                onLeave: model.finishSetup
            )
        }
    }
}
