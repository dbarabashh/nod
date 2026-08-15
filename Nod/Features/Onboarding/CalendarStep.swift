import SwiftUI

/// The calendar ask, written once.
///
/// Both surfaces below show the same three promises, and those promises are
/// claims `docs/policies/privacy.md` § 3.11 has to keep matching. Two copies of
/// a sentence like that drift the first time one of them is edited.
enum CalendarCopy {
    static let title = "Connect your calendar"

    static let body = "Nod needs to know which meeting you are in — what it is called, when it runs "
        + "and who is invited. That is what puts notes on the right meeting, and lets Nod tell you "
        + "one is starting before you have opened anything."

    static let promises: [(icon: String, text: String)] = [
        ("nc-shield-check", "Read-only. Nod never creates, changes, or deletes anything in your calendar."),
        ("nc-lock", "Your Google password never reaches Nod, and you can revoke access from Google at any time."),
        ("nc-calendar", "Your primary calendar only, and only meetings from two hours ago to a week ahead.")
    ]

    static func button(isConnected: Bool, isPending: Bool) -> String {
        if isConnected { return "Continue" }
        return isPending ? "Waiting for Google…" : "Connect Google Calendar"
    }
}

/// Step 5 of onboarding. The same question put to an existing account is
/// `CalendarPromptView`, which shares this one's words through `CalendarCopy`.
struct CalendarStep: View {
    @ObservedObject var integrations: IntegrationService
    let onFinish: () -> Void

    private var isConnected: Bool {
        integrations.linked.contains(.googleCalendar)
    }

    private var isPending: Bool {
        integrations.pending == .googleCalendar
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(CalendarCopy.title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.GlassButton.text)
                .padding(.bottom, 10)

            Text(CalendarCopy.body)
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.muted)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)

            promises
                .frame(maxWidth: 420)

            if let error = integrations.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
                    .padding(.top, 12)
            }

            actions
                .frame(maxWidth: 420)
                .padding(.top, 18)
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await integrations.refresh() }
        .onDisappear { integrations.cancelPending() }
    }

    // `Palette.ink` and `surfaceStrong` are built for the dark interface and
    // vanish on this sky backdrop; the glass pair below is what the primary
    // button already uses here.
    private var promises: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(CalendarCopy.promises, id: \.icon) { promise($0.icon, $0.text) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassButtonSurface(RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous))
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(icon)
                .icon(13)
                .foregroundStyle(Theme.GlassButton.text.opacity(0.55))
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.GlassButton.text.opacity(0.9))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 12)

            if !isConnected {
                Button("Not now", action: onFinish)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .linkCursor()
            }

            Button {
                if isConnected {
                    onFinish()
                } else {
                    Task { await integrations.connect(.googleCalendar) }
                }
            } label: {
                Text(CalendarCopy.button(isConnected: isConnected, isPending: isPending))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .frame(width: 170)
                    .padding(.vertical, 10)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(isPending)
            .linkCursor()
        }
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
    @ObservedObject var integrations: IntegrationService
    let onFinish: () -> Void

    private var isConnected: Bool {
        integrations.linked.contains(.googleCalendar)
    }

    private var isPending: Bool {
        integrations.pending == .googleCalendar
    }

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

            promises

            if let error = integrations.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }

            HStack(spacing: 12) {
                Link("Privacy policy", destination: EmailConsentLinks.privacy)
                    .font(.system(size: 11.5, weight: .medium))

                Spacer(minLength: 12)

                if !isConnected {
                    Button("Not now", action: onFinish)
                        .buttonStyle(.plain)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.Palette.muted)
                        .linkCursor()
                }

                Button {
                    if isConnected {
                        onFinish()
                    } else {
                        Task { await integrations.connect(.googleCalendar) }
                    }
                } label: {
                    Text(CalendarCopy.button(isConnected: isConnected, isPending: isPending))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(isPending)
                .linkCursor()
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(WindowBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .task { await integrations.refresh() }
        .onDisappear { integrations.cancelPending() }
    }

    private var promises: some View {
        VStack(spacing: 8) {
            ForEach(CalendarCopy.promises, id: \.icon) { promise($0.icon, $0.text) }
        }
    }

    private func promise(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(icon)
                .icon(13)
                .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                .frame(width: 22)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                .fill(Theme.Palette.surfaceStrong)
        )
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
    /// Not observed: this view never reads it, and observing it here would
    /// invalidate the main window's root every time a connection poll publishes.
    let integrations: IntegrationService

    private let content: Content
    @State private var isDismissedForSession = false

    init(
        onboarding: OnboardingState,
        integrations: IntegrationService,
        email: EmailPreferenceService,
        @ViewBuilder content: () -> Content
    ) {
        self.onboarding = onboarding
        self.integrations = integrations
        self.email = email
        self.content = content()
    }

    var body: some View {
        ZStack {
            content

            if onboarding.needsCalendarPrompt, !email.shouldPresentPrompt, !isDismissedForSession {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                CalendarPromptView(integrations: integrations) {
                    isDismissedForSession = true
                    onboarding.markCalendarPrompted()
                }
            }
        }
    }
}

#if DEBUG
    #Preview("Existing-user calendar prompt") {
        CalendarPromptView(integrations: .preview(), onFinish: {})
            .padding()
            .background(WindowBackdrop())
    }

    #Preview("Not connected") {
        CalendarStep(integrations: .preview(), onFinish: {})
            .frame(width: 580, height: 560)
            .background(WindowBackdrop())
    }

    #Preview("Connected") {
        CalendarStep(integrations: .preview(linked: [.googleCalendar]), onFinish: {})
            .frame(width: 580, height: 560)
            .background(WindowBackdrop())
    }
#endif
