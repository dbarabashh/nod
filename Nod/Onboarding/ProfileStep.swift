import SwiftUI

/// Onboarding step that seeds the user's always-on context. Everything is
/// optional — the user can skip — but even a name plus one line on how they
/// want Nod to respond makes the very first recap noticeably sharper. The
/// actual upsert is fired by OnboardingView so this view stays pure.
struct ProfileStep: View {
    let initialName: String
    let onContinue: (_ name: String, _ preferences: String) -> Void
    let onSkip: () -> Void

    @State private var name: String
    @State private var preferences: String = ""

    init(
        initialName: String,
        onContinue: @escaping (String, String) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.initialName = initialName
        self.onContinue = onContinue
        self.onSkip = onSkip
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("A little about you")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.GlassButton.text)
                .padding(.bottom, 8)

            Text(
                "Your name and how you like Nod to respond — used in every kind of session. You can change or clear it anytime in Settings."
            )
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Theme.Palette.muted)
            .frame(maxWidth: 400)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 26)

            VStack(spacing: 14) {
                ProfileField(
                    label: "Your name",
                    placeholder: "Alex",
                    text: $name
                )
                ProfileField(
                    label: "What should Nod help you win at?",
                    placeholder: "Track what people commit to me, surface risks early, and tell me how to make my point more persuasively",
                    text: $preferences,
                    helper: "Your edge in every conversation. Nod tailors each summary to it — so you follow through, stay on top, and get credit for your work.",
                    axis: .vertical
                )
            }
            .frame(maxWidth: 400)
            .padding(.bottom, 28)

            Button(action: { onContinue(name, preferences) }) {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .frame(width: 220)
                    .padding(.vertical, 12)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 10)

            Button("Skip for now", action: onSkip)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var helper: String?
    var axis: Axis = .horizontal

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.muted)

            if let helper {
                Text(helper)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(placeholder, text: $text, axis: axis)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.GlassButton.text)
                .focused($focused)
                .lineLimit(axis == .vertical ? 2 ... 4 : 1 ... 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    focused ? Theme.Palette.cyan.opacity(0.55) : Color.black.opacity(0.12),
                                    lineWidth: focused ? 1 : 0.5
                                )
                        )
                )
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

#Preview {
    ZStack {
        Theme.Palette.bg.ignoresSafeArea()
        ProfileStep(initialName: "Dima", onContinue: { _, _ in }, onSkip: {})
            .frame(width: 580, height: 540)
    }
}
