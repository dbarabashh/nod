import SwiftUI

/// Shared home for the "confirm Nod language before each meeting" preference so the
/// section's "ask before each meeting" checkbox, ContentView's start gate, and
/// the Settings toggle all read/write the same UserDefaults key (default on).
enum MeetingLanguagePromptDefaults {
    static let defaultsKey = "meeting.languagePrompt.enabled"
    static let defaultValue = true
}

/// Inline output-language confirm shown in place of the Start button when the user
/// taps Start. Catches the "forgot to switch Nod's language" case by surfacing
/// the current output pin one last time before recording begins. Read-only on purpose
/// — the only place to change the language is the header chip, so we don't stack
/// two pickers in the same cramped panel. Full-width dark section matching the
/// session-kind bar above it.
struct MeetingLanguagePrompt: View {
    let language: AppLanguage
    @Binding var askEachTime: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text("Nod language")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                Spacer(minLength: 0)
                Text(language.nativeName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }

            Toggle(isOn: $askEachTime) {
                Text("Ask before each meeting")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                actionButton("Cancel", primary: false, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                actionButton("Start meeting", primary: true, action: onStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                PanelMaterial()
                Color.white.opacity(0.05)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        )
        .transition(.opacity)
    }

    private func actionButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let label = Text(title)
                .font(.system(size: 13, weight: primary ? .semibold : .medium))
                .foregroundColor(primary ? Theme.GlassButton.text : .white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            if primary {
                label.glassButtonSurface(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                label.background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }
        }
        .buttonStyle(.plain)
    }
}
