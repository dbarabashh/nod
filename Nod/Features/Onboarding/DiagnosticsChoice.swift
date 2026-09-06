import SwiftUI

/// The two things that leave the Mac without a question being asked each
/// time — crash reports to Sentry, usage events to Nod's own database —
/// asked once, up front, with the same words the Settings switches use.
///
/// One view for both places it appears: a step for a new install, and a
/// one-time prompt for an install that updated into this build. Reports are
/// off until this is answered; usage events keep their existing state, which
/// a person may already have set in Settings.
///
/// `style` is which ground it sits on. `muted` and `cyan` are tuned for the
/// app's own dark surfaces; on the welcome sky the secondary text sinks into
/// the blue and the accent icon vanishes, so the step takes the ink instead.
struct DiagnosticsChoice: View {
    @ObservedObject var analytics: ProductAnalytics
    let consent: ConsentPreference
    var style: PolicyFooter.Style = .prompt
    let onFinish: () -> Void

    @State private var sendsCrashReports = CrashReporting.isEnabledByDefault
    @State private var sharesUsage: Bool

    init(
        analytics: ProductAnalytics,
        consent: ConsentPreference,
        style: PolicyFooter.Style = .prompt,
        onFinish: @escaping () -> Void
    ) {
        self.analytics = analytics
        self.consent = consent
        self.style = style
        self.onFinish = onFinish
        _sharesUsage = State(initialValue: !analytics.isOptedOut)
    }

    private var secondaryText: Color {
        style == .onboarding ? Theme.Palette.inkSecondary : Theme.Palette.muted
    }

    private var subtitleTone: SettingsSubtitleTone {
        style == .onboarding ? .secondary : .muted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("nc-shield-check")
                .icon(22)
                .foregroundStyle(style == .onboarding ? Theme.Palette.ink : Theme.Palette.cyan)
            VStack(alignment: .leading, spacing: 7) {
                Text("Help make Nod better?")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)
                Text(
                    "Neither of these ever includes a transcript, summary, question, answer, name, email or IP address. Both can be changed any time in Settings → Privacy."
                )
                .font(.system(size: 12.5))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard {
                SettingsRow(
                    icon: "nc-triangle-warning",
                    title: "Send crash reports",
                    subtitle: "When Nod crashes or freezes, the stack trace, app version, macOS version and Mac model go to Sentry so it can be fixed.",
                    subtitleTone: subtitleTone
                ) {
                    Toggle("", isOn: $sendsCrashReports)
                        .labelsHidden()
                        .nodSwitch()
                        .accessibilityLabel("Send crash reports")
                }
                SettingsRowDivider()
                SettingsRow(
                    icon: "nc-window-chart-line",
                    title: "Share usage events",
                    subtitle: "Counts of which features get used and whether they worked, so we know what to fix. Never what you say or write. Kept in Nod's own database.",
                    subtitleTone: subtitleTone
                ) {
                    Toggle("", isOn: $sharesUsage)
                        .labelsHidden()
                        .nodSwitch()
                        .accessibilityLabel("Share usage events")
                }
            }
            PolicyFooter(primary: TitledAction("Continue") { finish() }, style: style)
        }
    }

    private func finish() {
        analytics.isOptedOut = !sharesUsage
        CrashReporting.record(enabled: sendsCrashReports)
        consent.recordDiagnosticsChoice(crashReports: sendsCrashReports, usageEvents: sharesUsage, source: .prompt)
        onFinish()
    }
}

/// Wraps the main window so an install that updated into this build is asked
/// once, the way the email prompt asks. A new install answers in onboarding
/// and never sees this.
struct DiagnosticsPromptHost<Content: View>: View {
    @ObservedObject var analytics: ProductAnalytics
    let consent: ConsentPreference
    let isOnboardingComplete: Bool
    private let content: Content

    @State private var isAnswered = CrashReporting.hasBeenAsked()

    init(analytics: ProductAnalytics, consent: ConsentPreference, isOnboardingComplete: Bool, @ViewBuilder content: () -> Content) {
        self.analytics = analytics
        self.consent = consent
        self.isOnboardingComplete = isOnboardingComplete
        self.content = content()
    }

    var body: some View {
        PromptHost(isDue: isOnboardingComplete && !isAnswered, isDismissed: .constant(false)) {
            content
        } prompt: {
            DiagnosticsChoice(analytics: analytics, consent: consent) { isAnswered = true }
                .promptCard(width: 520)
        }
    }
}
