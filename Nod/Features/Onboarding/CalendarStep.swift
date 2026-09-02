import SwiftUI

/// The calendar ask, written once.
///
/// Every claim below is one `docs/policies/privacy.md` § 3.11 has to keep
/// matching, and both surfaces show the same ones. Two copies of a sentence
/// like that drift the first time one of them is edited.
enum CalendarCopy {
    static let title = "Connect your calendar"

    static let body = "Nod needs to know which meeting you are in — what it is called, when it runs "
        + "and who is invited. That is what puts notes on the right meeting, names the speakers in "
        + "your transcript, and lets Nod tell you one is starting before you have opened anything."

    /// The two sources, in the order they should be offered.
    ///
    /// `privacy.md` § 3.11 gives them an off-switch each and says neither
    /// implies the other, so both belong here rather than only the one that
    /// happens to be a connected account.
    enum Option {
        case device
        case google

        var title: String {
            switch self {
            case .device: "This Mac's calendar"
            case .google: "Google Calendar"
            }
        }

        var detail: String {
            switch self {
            case .device:
                "One macOS permission, no account. Reads the calendars already in your Calendar app — "
                    + "iCloud, Exchange, Google. Nothing about an event is stored."
            case .google:
                "For a work calendar that is not on this Mac, and it keeps answering while the Mac sleeps. "
                    + "Google's screen asks for wider access than Nod uses."
            }
        }

        var offerTitle: String {
            switch self {
            case .device: "Allow"
            case .google: "Connect"
            }
        }

        var pendingTitle: String {
            switch self {
            case .device: "Asking macOS…"
            case .google: "Waiting for Google…"
            }
        }
    }

    /// True of both sources, so it is said once under them rather than twice
    /// inside them. Bound to `privacy.md` § 3.11 — (b) "Writing: Never" and
    /// (a) "Only when you confirm it, and only what you confirmed".
    static let assurance = "Nod reads your calendar and never changes it on its own. It can create, "
        + "move or cancel an event only from a card you have confirmed."
}

/// Each source's own mark — the Calendar app's icon and Google's logo.
///
/// A row asking for a product's data is recognised by that product's mark, not
/// by a generic glyph: two neutral calendar outlines side by side were the one
/// thing on the step that did not say which was which.
struct CalendarOptionMark: View {
    let option: CalendarCopy.Option

    private static let size: CGFloat = 17

    var body: some View {
        switch option {
        case .device:
            if let icon = AppDirectory.icon(for: AppDirectory.identity(forBundleID: "com.apple.iCal")) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Self.size, height: Self.size)
            } else {
                Image("nc-calendar")
                    .icon(Self.size * 0.82)
                    .foregroundStyle(Theme.Palette.ink)
            }
        case .google:
            ProviderMark(provider: .googleCalendar, size: Self.size)
        }
    }
}

/// The two ways to give Nod a calendar, offered together.
///
/// One view, mounted by both the onboarding step and the prompt an existing
/// account gets, because the wording here is policy-bound and two copies of it
/// drift the first time one is edited.
struct CalendarOptionList: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var integrations: IntegrationService

    var body: some View {
        VStack(spacing: 8) {
            row(.device, state: CalendarSourceState.device(calendar), action: enableDevice)
            row(.google, state: CalendarSourceState.google(integrations), action: connectGoogle)
        }
    }

    private func enableDevice() {
        guard calendar.status != .denied else { return calendar.openSystemSettings() }
        Task { await calendar.enableOnThisMac() }
    }

    private func connectGoogle() {
        Task { await integrations.connect(.googleCalendar) }
    }

    private func row(_ option: CalendarCopy.Option, state: CalendarSourceState, action: @escaping () -> Void) -> some View {
        SettingsRow(
            title: option.title,
            subtitle: detail(for: option, state: state),
            subtitleTone: .secondary,
            alignment: .top
        ) {
            CalendarOptionMark(option: option)
                .frame(width: 20, alignment: .center)
                .padding(.top, 1)
        } trailing: {
            control(state, option: option, action: action)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(emphasis: .strong)
    }

    /// macOS only ever prompts once on its own, so a refusal replaces the pitch
    /// with the one place that can still undo it.
    private func detail(for option: CalendarCopy.Option, state: CalendarSourceState) -> String {
        state == .blocked ? CalendarService.blockedHint : option.detail
    }

    @ViewBuilder
    private func control(_ state: CalendarSourceState, option: CalendarCopy.Option, action: @escaping () -> Void) -> some View {
        switch state {
        case .connected:
            StatusLabel(icon: "nc-check", title: "Connected", tint: Theme.Palette.success)
        case .pending:
            Text(option.pendingTitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Palette.inkSecondary)
        case .offer:
            button(option.offerTitle, action: action)
        case .blocked:
            button("Open Settings", action: action)
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .glassButtonSurface(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .linkCursor()
    }
}

/// The calendar step. The same question put to an existing account is
/// `CalendarPromptView`, which shares this one's words through `CalendarCopy`.
struct CalendarStep: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var integrations: IntegrationService
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(CalendarCopy.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 10)

            Text(CalendarCopy.body)
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)

            CalendarOptionList(calendar: calendar, integrations: integrations)
                .frame(maxWidth: 440)

            Text(CalendarCopy.assurance)
                .multilineTextAlignment(.center)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.inkSecondary)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            if let error = integrations.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .padding(.top, 10)
            }

            actions
                .frame(maxWidth: 440)
                .padding(.top, 18)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await integrations.refresh() }
        .onDisappear { integrations.cancelPending() }
    }

    /// Continue is always live and never a connect button: a step that can be
    /// answered two ways cannot put one of them on the primary, and skipping
    /// stays a real answer — `privacy.md` § 3.11 says neither source is on by
    /// default.
    private var actions: some View {
        PolicyFooter(
            primary: TitledAction(
                CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations) ? "Continue" : "Not now",
                action: onFinish
            ),
            style: .onboarding
        )
    }
}

/// The same question, put to someone who finished onboarding before the step
/// existed.
///
/// A card over the main window rather than a window of its own, and the shape is
/// `EmailConsentPromptView`'s down to the paddings — that is the established
/// answer to "ask an existing account once", and two different-looking modals
/// for one job is how an app stops feeling like one app.
///
/// Which means a dark ground, so the palette flips relative to the onboarding
/// step: `Palette.ink` is near-white and reads here, where on the sky backdrop
/// of `CalendarStep` it disappears.
struct CalendarPromptView: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var integrations: IntegrationService
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("nc-calendar")
                .icon(22)
                .foregroundStyle(Theme.Palette.cyan)

            VStack(alignment: .leading, spacing: 7) {
                Text(CalendarCopy.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(CalendarCopy.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CalendarOptionList(calendar: calendar, integrations: integrations)

            Text(CalendarCopy.assurance)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let error = integrations.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }

            PolicyFooter(
                primary: TitledAction(
                    CalendarSourceState.isAnswered(calendar: calendar, integrations: integrations) ? "Done" : "Not now",
                    action: onFinish
                )
            )
        }
        .promptCard(width: 520)
        .task { await integrations.refresh() }
        .onDisappear { integrations.cancelPending() }
    }
}

/// Wraps the main window and asks accounts that predate the calendar step the
/// same question onboarding now asks. Dismissing counts as an answer, so nobody
/// is asked twice.
///
/// Waits for the email-consent prompt when both are due: two dimmed modals
/// stacked on one launch is worse than either of them a launch apart.
struct CalendarPromptHost<Content: View>: View {
    @ObservedObject var onboarding: OnboardingState
    @ObservedObject var email: EmailPreferenceService
    /// Not observed: this view never reads either, and observing them here would
    /// invalidate the main window's root every time a connection poll publishes.
    let integrations: IntegrationService
    let calendar: CalendarService

    private let content: Content
    @State private var isDismissedForSession = false

    init(
        onboarding: OnboardingState,
        integrations: IntegrationService,
        calendar: CalendarService,
        email: EmailPreferenceService,
        @ViewBuilder content: () -> Content
    ) {
        self.onboarding = onboarding
        self.integrations = integrations
        self.calendar = calendar
        self.email = email
        self.content = content()
    }

    var body: some View {
        PromptHost(
            isDue: onboarding.needsCalendarPrompt && !email.shouldPresentPrompt,
            isDismissed: $isDismissedForSession
        ) {
            content
        } prompt: {
            CalendarPromptView(calendar: calendar, integrations: integrations) {
                isDismissedForSession = true
                onboarding.markCalendarPrompted()
            }
        }
    }
}

#if DEBUG
    #Preview("Existing-user calendar prompt") {
        CalendarPromptView(calendar: CalendarService(), integrations: .preview(), onFinish: {})
            .padding()
            .background(WindowBackdrop())
    }

    #Preview("Nothing connected") {
        WelcomeBackdrop {
            CalendarStep(calendar: CalendarService(), integrations: .preview(), onFinish: {})
        }
        .frame(width: 720, height: 660)
    }

    #Preview("Google connected") {
        WelcomeBackdrop {
            CalendarStep(
                calendar: CalendarService(),
                integrations: .preview(linked: [.googleCalendar]),
                onFinish: {}
            )
        }
        .frame(width: 720, height: 660)
    }
#endif
