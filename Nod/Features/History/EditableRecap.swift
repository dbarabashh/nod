import SwiftUI

/// The recap as a thing you can correct, a line at a time.
///
/// A recap is written from a transcript, and a transcript mishears names. The
/// fix used to be a mode: press Edit, get the raw markdown in a text box, find
/// `**Decisions**` and the dash that starts the line, repair the sentence, leave
/// the mode. That asks somebody who spotted "Eric" where "Erik" belongs to first
/// learn how the recap is stored.
struct EditableRecap: View {
    let recap: MeetingRecap
    /// Handed the whole recap rather than the line: a correction rewrites
    /// `recap_json` and the rendered `summary` together, and only the owner of
    /// both can do that.
    let onEdit: (MeetingRecap) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(recap.sections.enumerated()), id: \.offset) { index, section in
                VStack(alignment: .leading, spacing: 6) {
                    Text(section.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.ink)
                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { position, bullet in
                        RecapLine(bullet: bullet) { corrected in
                            let id = MeetingRecap.BulletID(section: index, bullet: position)
                            onEdit(recap.replacing(id, with: corrected))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One bullet: read it, double-click it, fix it.
///
/// A view of its own so typing invalidates the line being typed in rather than
/// the recap around it — with the draft and the hover held above, every
/// keystroke rebuilt the attributed text of every other bullet on screen.
private struct RecapLine: View {
    let bullet: MeetingRecap.Bullet
    let onCorrect: (String) -> Void

    @State private var isEditing = false
    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.muted)
            if isEditing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.ink)
                    .focused($isFocused)
                    .chatSubmit(text: $draft) { commit() }
                    .onExitCommand { isEditing = false }
                    // Clicking away is a save, not a discard: the sentence on
                    // screen is the one the person just typed, and throwing it
                    // out because they looked elsewhere reads as a bug.
                    .onChange(of: isFocused) { focused in
                        if !focused, isEditing { commit() }
                    }
            } else {
                Text(rendered)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // Not `.textSelection(.enabled)`: on macOS that puts a
                    // selectable layer in front, and the double-click lands on
                    // it instead of here — the line stayed uneditable and
                    // nothing said why.
                    .onTapGesture(count: 2) { begin() }
                    .hoverHighlight(
                        isHovering,
                        cornerRadius: 6,
                        reduceMotion: reduceMotion,
                        inset: CGSize(width: -6, height: -3)
                    )
                    .onHover { isHovering = $0 }
                    // The gesture is invisible otherwise, and a correction
                    // nobody discovers is a correction nobody makes.
                    .help("Double-click to correct this line")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The quote reads as the transcript's own words, kept so a line can be
    /// checked against them.
    private var rendered: AttributedString {
        var text = AttributedString(bullet.text)
        guard let quote = bullet.quote, !quote.isEmpty else { return text }
        var quoted = AttributedString(" \"\(quote)\"")
        quoted.foregroundColor = Theme.Palette.muted
        text.append(quoted)
        return text
    }

    private func begin() {
        // The quote is left out of the draft: it is evidence for the sentence,
        // not part of it, and editing a line drops it anyway.
        draft = bullet.text
        isEditing = true
        isFocused = true
    }

    private func commit() {
        isEditing = false
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines) != bullet.text else { return }
        onCorrect(draft)
    }
}

#Preview {
    EditableRecap(
        recap: MeetingRecap(sections: [
            MeetingRecap.Section(title: "Decisions", bullets: [
                MeetingRecap.Bullet(
                    text: "Eric owns the migration",
                    quote: "Eric will take the migration"
                ),
                MeetingRecap.Bullet(text: "Ship on Friday")
            ]),
            MeetingRecap.Section(title: "Open questions", bullets: [
                MeetingRecap.Bullet(text: "Who signs off on pricing?")
            ])
        ]),
        onEdit: { _ in }
    )
    .padding(24)
    .frame(width: 420)
    .background(Theme.Palette.surface)
}
