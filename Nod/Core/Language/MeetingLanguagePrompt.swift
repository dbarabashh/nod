import SwiftUI

/// Shared home for the "confirm Nod language before each meeting" preference so the
/// section's "ask before each meeting" checkbox, ContentView's start gate, and
/// the Settings toggle all read/write the same UserDefaults key (default on).
enum MeetingLanguagePromptDefaults {
    static let defaultsKey = "meeting.languagePrompt.enabled"
    static let defaultValue = true
}

/// Output-language confirm, shown as a state of the notch surface on the way
/// into a recording. Catches the "forgot to switch Nod's language" case by
/// surfacing the current output pin one last time before capture begins.
///
/// Paints only its content — the notch is the card.
struct MeetingLanguagePrompt: View {
    /// Writable, not read-only as it was in the old panel: that panel had a
    /// language chip in its header to change this, and the notch does not. A
    /// confirm you can only agree with is a dead end when the answer is wrong.
    @Binding var language: AppLanguage
    @Binding var askEachTime: Bool
    let onStart: () -> Void
    let onCancel: () -> Void

    /// What the Nod language pick governs, and — the half people get wrong —
    /// what it leaves alone. Shared with the onboarding pick and the header
    /// picker's tooltip so all three describe the same setting the same way.
    static let scopeNote = "Summaries, titles, and answers come back in this language. It doesn't limit what you speak on the call — Nod transcribes whatever it hears."

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image("nc-earth")
                    .icon(12)
                    .foregroundColor(Theme.Palette.ink.opacity(0.85))
                Text("Nod language")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.Palette.ink.opacity(0.72))
                Spacer(minLength: 0)
                picker
            }

            // A language confirm shown the instant you press Start reads as
            // "what language is this meeting in?" no matter what it is called —
            // the context is doing the talking. Users set it to the language
            // they were about to speak and then got a recap they couldn't read.
            // So the card states what it governs, and what it does not.
            Text(Self.scopeNote)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(Theme.Palette.ink.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $askEachTime) {
                Text("Ask before each meeting")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundColor(Theme.Palette.ink.opacity(0.72))
            }
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                actionButton("Cancel", primary: false, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                actionButton("Start meeting", primary: true, action: onStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var picker: some View {
        Menu {
            ForEach(AppLanguage.allCases, id: \.self) { option in
                Button(option.nativeName) { language = option }
            }
        } label: {
            HStack(spacing: 4) {
                Text(language.nativeName)
                    .font(.system(size: 12.5, weight: .semibold))
                Image("nc-chevron-expand-y")
                    .icon(8)
            }
            .foregroundColor(Theme.Palette.ink.opacity(0.95))
        }
        .plainMenuChrome()
        .fixedSize()
    }

    private func actionButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            let label = Text(title)
                .font(.system(size: 13, weight: primary ? .semibold : .medium))
                .foregroundColor(primary ? Theme.GlassButton.text : Theme.Palette.ink.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            if primary {
                label.glassButtonSurface(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                label.background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Palette.overlay.opacity(0.06))
                )
            }
        }
        .buttonStyle(.plain)
    }
}
