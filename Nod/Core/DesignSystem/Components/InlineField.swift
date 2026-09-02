import SwiftUI

extension View {
    /// The soft rounded wash every inline form draws under its fields, its
    /// option lists and its banners.
    func inlineFieldSurface() -> some View {
        background(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
    }
}

/// A one-line field inside an inline form. Modifiers that belong to the field
/// — `onSubmit`, an overlay of suggestions, `zIndex` — chain on this view.
struct InlineTextField: View {
    let placeholder: String
    @Binding var text: String
    let weight: Font.Weight

    init(_ placeholder: String, text: Binding<String>, weight: Font.Weight = .regular) {
        self.placeholder = placeholder
        _text = text
        self.weight = weight
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, weight: weight))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .inlineFieldSurface()
    }
}

/// The multi-line sibling: a message, a description. Grows with its text
/// between the two heights and scrolls past the second.
struct InlineTextEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 56
    var maxHeight: CGFloat = 110

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .padding(6)
            .inlineFieldSurface()
    }
}

#Preview {
    struct Host: View {
        @State private var title = "Follow up with the design team"
        @State private var recipient = ""
        @State private var details = "Bring the revised mock and the open questions from Tuesday."

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                InlineTextField("Title", text: $title, weight: .medium)
                InlineTextField("Who — a person, or # a channel", text: $recipient)
                InlineTextEditor(text: $details, minHeight: 48, maxHeight: 100)
                Text("Already filed as NOD-12")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .inlineFieldSurface()
            }
            .frame(width: 320)
            .padding(24)
            .background(Theme.Palette.bg)
        }
    }
    return Host()
}
