import SwiftUI

/// What the profile step collected. A struct rather than four closure
/// parameters so adding a question doesn't reshape the call site again.
struct ProfileAnswers {
    let name: String
    let preferences: String
    let role: WorkRole?
    let heardFrom: AcquisitionSource?
}

/// Onboarding step that seeds the user's always-on context. Everything is
/// optional — the user can skip — but even a name plus one line on how they
/// want Nod to respond makes the very first recap noticeably sharper. The
/// actual upsert is fired by OnboardingView so this view stays pure.
struct ProfileStep: View {
    let initialName: String
    /// Every field is seeded from the stored profile, because Continue writes
    /// the whole row: an unseeded control would clear what a previous pass —
    /// or another Mac — already saved.
    let initialPreferences: String
    let initialRole: WorkRole?
    let initialHeardFrom: AcquisitionSource?
    let onContinue: (_ answers: ProfileAnswers) -> Void
    let onSkip: () -> Void

    @State private var name: String
    @State private var preferences: String
    @State private var role: WorkRole?
    @State private var heardFrom: AcquisitionSource?

    init(
        initialName: String,
        initialPreferences: String,
        initialRole: WorkRole?,
        initialHeardFrom: AcquisitionSource?,
        onContinue: @escaping (ProfileAnswers) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.initialName = initialName
        self.initialPreferences = initialPreferences
        self.initialRole = initialRole
        self.initialHeardFrom = initialHeardFrom
        self.onContinue = onContinue
        self.onSkip = onSkip
        _name = State(initialValue: initialName)
        _preferences = State(initialValue: initialPreferences)
        _role = State(initialValue: initialRole)
        _heardFrom = State(initialValue: initialHeardFrom)
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
                ProfilePicker(
                    label: "What do you do?",
                    selection: $role,
                    options: WorkRole.allCases,
                    title: \.title,
                    footnote: modeFootnote
                )
                ProfilePicker(
                    label: "How did you hear about us?",
                    selection: $heardFrom,
                    options: AcquisitionSource.allCases,
                    title: \.title
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

            Button(action: submit) {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.GlassButton.text)
                    .frame(width: 220)
                    .padding(.vertical, 12)
                    .glassButtonSurface(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            // No `.defaultAction` here: with two menus on the step, Return
            // would fire Continue instead of opening whichever one has focus —
            // the exact conflict that sent `WelcomeStep` back to a Picker.
            .padding(.bottom, 10)

            Button("Skip for now", action: onSkip)
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.Palette.muted)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() {
        onContinue(
            ProfileAnswers(
                name: name,
                preferences: preferences,
                role: role,
                heardFrom: heardFrom
            )
        )
    }

    /// Answering has to buy something on the spot, or it's a form for our
    /// benefit. The role picks the starting mode, and this says so.
    private var modeFootnote: String? {
        guard let name = role?.presetModeName else { return nil }
        return "\(name) mode will be on by default — change it any time."
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
                .profileFieldSurface(focused: focused)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

/// A dropdown that matches the text fields beside it. `nil` is a real state —
/// every question on this step is optional.
///
/// A `Menu`, not a `Picker`: a pop-up button refuses to grow past its widest
/// item, so two Pickers on one form land on two different widths and neither
/// lines up with the fields. `.frame(width:)` doesn't move it either — it just
/// centres the control in the frame. A Menu takes the width it's given, which
/// is the whole reason this is hand-rolled.
///
/// What that costs, and how it's paid: the selected item carries its own
/// checkmark, and the step drops `.keyboardShortcut(.defaultAction)` so Return
/// opens the focused menu instead of firing Continue past it.
private struct ProfilePicker<Option: Identifiable & Hashable>: View {
    let label: String
    @Binding var selection: Option?
    let options: [Option]
    let title: KeyPath<Option, String>
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.muted)

            Menu {
                ForEach(options) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            IconLabel(title: option[keyPath: title], icon: "nc-check")
                        } else {
                            Text(option[keyPath: title])
                        }
                    }
                }
            } label: {
                menuLabel
            }
            .plainMenuChrome()
            .accessibilityLabel(label)
            .accessibilityValue(selectedTitle ?? "Not set")

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var selectedTitle: String? {
        selection.map { $0[keyPath: title] }
    }

    private var menuLabel: some View {
        HStack(spacing: 8) {
            Text(selectedTitle ?? "Select an option…")
                .font(.system(size: 13.5))
                .foregroundStyle(
                    selectedTitle == nil
                        ? Theme.Palette.muted
                        : Theme.GlassButton.text
                )
                .lineLimit(1)

            Spacer(minLength: 0)

            Image("nc-chevron-expand-y")
                .icon(10)
                .foregroundStyle(Theme.Palette.muted)
        }
        .profileFieldSurface()
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension View {
    /// The one surface every control on this step wears — fields and menus
    /// alike, so a radius or hairline tweak can't drift between them.
    func profileFieldSurface(focused: Bool = false) -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

#Preview {
    ZStack {
        Theme.Palette.bg.ignoresSafeArea()
        ProfileStep(
            initialName: "Dima",
            initialPreferences: "",
            initialRole: nil,
            initialHeardFrom: nil,
            onContinue: { _ in },
            onSkip: {}
        )
        .frame(width: 580, height: 560)
    }
}
