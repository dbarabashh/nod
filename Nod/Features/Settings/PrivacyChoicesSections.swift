import SwiftUI

/// Settings → Privacy: what we may email about. The same three topics as the
/// consent prompt, each writable on its own so turning one off never has to touch
/// the others.
struct EmailPreferencesSection: View {
    @ObservedObject var preferences: EmailPreferenceService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("EMAIL CHOICES")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.muted)

            Text(
                "Optional emails are off unless you choose them here. Account and referral "
                    + "notices aren't marketing and are sent regardless."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.muted)
            .fixedSize(horizontal: false, vertical: true)

            SettingsCard {
                ForEach(Array(EmailTopic.allCases.enumerated()), id: \.element.id) { index, topic in
                    if index > 0 { SettingsRowDivider() }
                    SettingsRow(icon: topic.icon, title: topic.title, subtitle: topic.detail) {
                        Toggle("", isOn: binding(for: topic))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel(topic.title)
                            .disabled(!preferences.hasLoaded || preferences.isLoading || preferences.isSaving(topic))
                    }
                }
            }

            HStack(spacing: 7) {
                if preferences.isLoading || !preferences.savingTopics.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                Spacer(minLength: 8)
                Link("Privacy policy", destination: EmailConsentLinks.privacy)
                    .font(.system(size: 11.5, weight: .medium))
            }

            if let error = preferences.lastError {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.danger)
                    Button("Try again") {
                        Task { await preferences.refresh() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .linkCursor()
                }
            }
        }
        .task { await preferences.refresh() }
    }

    private func binding(for topic: EmailTopic) -> Binding<Bool> {
        Binding(
            get: { preferences.isSubscribed(to: topic) },
            set: { isOn in
                Task { await preferences.setPreference(isOn, for: topic) }
            }
        )
    }

    private var statusText: String {
        if preferences.isLoading, !preferences.hasLoaded {
            return "Loading your choices…"
        }
        switch preferences.subscribedCount {
        case 0: return "All optional emails are off."
        case 1: return "Subscribed to 1 topic."
        default: return "Subscribed to \(preferences.subscribedCount) topics."
        }
    }
}

/// Settings → Privacy: product analytics. These are bounded first-party events
/// used to see where the product loses people; they carry no meeting content and
/// go nowhere else. That is why the control is an opt-OUT — the alternative
/// measures nothing and still asks for a decision nobody has context for.
struct ProductAnalyticsSection: View {
    @ObservedObject var analytics: ProductAnalytics

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PRODUCT ANALYTICS")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Palette.muted)

            SettingsCard {
                SettingsRow(
                    icon: "nc-shield-check",
                    title: "Share usage events",
                    // The guarantee comes first, and it is specific: a vague
                    // "we respect your privacy" is exactly what nobody believes.
                    subtitle: "What you record is never touched by this. No transcript, summary, "
                        + "meeting title, question, or answer is ever part of these events, and "
                        + "nothing here goes to a third party — it stays in Nod's own database. "
                        + "Counted: which screens and actions you used, and whether they worked. "
                        + "Turning this off also discards anything still waiting to be sent."
                ) {
                    Toggle("", isOn: Binding(
                        get: { !analytics.isOptedOut },
                        set: { analytics.isOptedOut = !$0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Share usage events")
                }
            }
        }
    }
}

#Preview("Email choices") {
    EmailPreferencesSection(preferences: EmailPreferenceService())
        .padding()
        .frame(width: 560)
        .background(WindowBackdrop())
}
