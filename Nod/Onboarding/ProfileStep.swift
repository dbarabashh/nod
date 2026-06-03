import SwiftUI

/// Onboarding step that seeds the user's always-on context. Everything is
/// optional — the user can skip — but even a name + one line of focus makes
/// the very first recap noticeably sharper. The actual upsert is fired by
/// OnboardingView so this view stays pure and previewable.
struct ProfileStep: View {
    let initialName: String
    let onContinue: (_ name: String, _ role: String, _ focus: String) -> Void
    let onSkip: () -> Void

    @State private var name: String
    @State private var role: String = ""
    @State private var focus: String = ""

    init(
        initialName: String,
        onContinue: @escaping (String, String, String) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.initialName = initialName
        self.onContinue = onContinue
        self.onSkip = onSkip
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(Theme.Palette.cyan)
                .shadow(color: Theme.Palette.cyan.opacity(0.35), radius: 24, x: 0, y: 10)
                .padding(.bottom, 22)

            Text("A little about you")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .padding(.bottom, 8)

            Text(
                "Nod uses this to make every summary and answer feel like it already knows you. You can change or clear it anytime in Settings."
            )
            .multilineTextAlignment(.center)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Theme.Palette.graphite)
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
                    label: "What you do",
                    placeholder: "Product designer at an early-stage startup",
                    text: $role
                )
                ProfileField(
                    label: "What you're working on",
                    placeholder: "Shipping our iOS app, hiring two engineers this quarter",
                    text: $focus,
                    axis: .vertical
                )
            }
            .frame(maxWidth: 400)

            Spacer(minLength: 0)

            Button(action: { onContinue(name, role, focus) }) {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.ink)
                    .frame(width: 220)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Theme.Gradients.buttonBrand)
                    )
                    .shadow(color: Theme.Palette.pink.opacity(0.3), radius: 18, x: 0, y: 10)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.bottom, 10)

            Button("Skip for now", action: onSkip)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.graphite)
                .padding(.bottom, 28)
        }
        .padding(.horizontal, 40)
    }
}

private struct ProfileField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.muted)

            TextField(placeholder, text: $text, axis: axis)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Palette.ink)
                .focused($focused)
                .lineLimit(axis == .vertical ? 2 ... 4 : 1 ... 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(
                                    focused ? Theme.Palette.cyan.opacity(0.55) : Theme.Palette.border,
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
        ProfileStep(initialName: "Dima", onContinue: { _, _, _ in }, onSkip: {})
            .frame(width: 580, height: 540)
    }
}
