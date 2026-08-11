import SwiftUI

/// The three optional topics as checkboxes, shared by onboarding, the
/// existing-user prompt and Settings. Everything starts unchecked: consent is
/// something a person gives, not a default we hand ourselves.
struct EmailConsentChoiceList: View {
    @Binding var selected: Set<EmailTopic>
    var isDisabled = false

    var body: some View {
        VStack(spacing: 10) {
            ForEach(EmailTopic.allCases) { topic in
                Toggle(isOn: binding(for: topic)) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(topic.icon)
                            .icon(13)
                            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(topic.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(Theme.Palette.ink)
                            Text(topic.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(isDisabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
            }
        }
    }

    private func binding(for topic: EmailTopic) -> Binding<Bool> {
        Binding(
            get: { selected.contains(topic) },
            set: { isOn in
                if isOn {
                    selected.insert(topic)
                } else {
                    selected.remove(topic)
                }
            }
        )
    }
}

/// Wraps the main window and asks existing accounts the same question new ones
/// get during onboarding. Dismissing counts as an answer ("none of these"), so
/// nobody is asked twice and nobody is enrolled by silence.
struct EmailConsentPromptHost<Content: View>: View {
    @ObservedObject var preferences: EmailPreferenceService

    private let content: Content
    @State private var isDismissedForSession = false

    init(preferences: EmailPreferenceService, @ViewBuilder content: () -> Content) {
        self.preferences = preferences
        self.content = content()
    }

    var body: some View {
        ZStack {
            content

            if preferences.shouldPresentPrompt, !isDismissedForSession {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                EmailConsentPromptView(
                    preferences: preferences,
                    onFinish: { isDismissedForSession = true }
                )
            }
        }
        .task { await preferences.refresh() }
    }
}

struct EmailConsentPromptView: View {
    @ObservedObject var preferences: EmailPreferenceService
    let onFinish: () -> Void

    @State private var selected: Set<EmailTopic> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image("nc-msgs")
                .icon(22)
                .foregroundStyle(Theme.Palette.cyan)

            VStack(alignment: .leading, spacing: 7) {
                Text("What would you like to hear from us about?")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(Theme.Palette.ink)
                Text("Every choice is optional and off until you pick it. You can change your mind any time in Settings.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            EmailConsentChoiceList(selected: $selected, isDisabled: preferences.isBusy)

            if let error = preferences.lastError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.danger)
            }

            HStack(spacing: 12) {
                Link("Privacy policy", destination: EmailConsentLinks.privacy)
                    .font(.system(size: 11.5, weight: .medium))

                Spacer(minLength: 12)

                Button("Not now") { save(nothing: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.Palette.muted)
                    .disabled(preferences.isBusy)
                    .linkCursor()

                Button { save(nothing: false) } label: {
                    Text(preferences.isSavingPrompt ? "Saving…" : "Save choices")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.GlassButton.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .glassButtonSurface(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(preferences.isBusy)
                .linkCursor()
            }
        }
        .padding(22)
        .frame(width: 520)
        // The window's own ground, not a palette colour: `surfaceCard()` let the
        // content read through, and a flat fill (`bgSoft`) reads navy against the
        // window's neutral material. `WindowBackdrop` blends behind the WINDOW,
        // so sibling views stay hidden while the card matches its surroundings.
        .background(WindowBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radii.card, style: .continuous)
                .stroke(Theme.Palette.borderStrong, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }

    private func save(nothing: Bool) {
        Task {
            if await preferences.savePromptSelection(nothing ? [] : selected, source: .existingUserPrompt) {
                onFinish()
            }
        }
    }
}

enum EmailConsentLinks {
    /// `nod-landing` serves every policy under `/policies/…`; a bare `/privacy`
    /// is not a route.
    static let privacy = URL(string: "https://hellonod.app/policies/privacy")
        ?? URL(fileURLWithPath: "/")
}

#Preview("Existing-user consent prompt") {
    EmailConsentPromptView(preferences: EmailPreferenceService(), onFinish: {})
        .padding()
        .background(WindowBackdrop())
}

#Preview("Consent choices") {
    EmailConsentChoiceList(selected: .constant([]))
        .padding()
        .frame(width: 520)
        .background(WindowBackdrop())
}
