import SwiftUI

/// The list that floats under a field while someone types — people, channels,
/// products — so the form never changes height on a keystroke. Opaque layers,
/// because it covers whatever sits below the field: the usual translucent wash
/// would show that text through the rows meant to hide it.
///
/// Mount it in the field's `overlay(alignment: .topLeading)` and give the field
/// `zIndex(1)` so the rows draw over the siblings that follow.
struct SuggestionPopover<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let width: CGFloat?
    let offset: CGFloat
    let onPick: (Item) -> Void
    let row: (Item) -> Row

    init(
        items: [Item],
        width: CGFloat? = nil,
        offset: CGFloat = 32,
        onPick: @escaping (Item) -> Void,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.items = items
        self.width = width
        self.offset = offset
        self.onPick = onPick
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button {
                    onPick(item)
                } label: {
                    HStack(spacing: 8) {
                        row(item)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.Palette.bg)
                .overlay(RoundedRectangle(cornerRadius: 7).fill(Theme.Palette.surfaceStrong))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.Palette.border, lineWidth: 1))
        .shadow(color: Theme.Palette.scrim.opacity(0.35), radius: 14, y: 6)
        .offset(y: offset)
    }
}

#Preview {
    struct Person: Identifiable {
        let name: String
        let email: String
        var id: String {
            email
        }
    }

    struct Host: View {
        @State private var typed = "an"
        private let people = [
            Person(name: "Anna Kowalski", email: "anna@example.com"),
            Person(name: "Andrés Molina", email: "andres@example.com")
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                InlineTextField("Invite — type a name", text: $typed)
                    .overlay(alignment: .topLeading) {
                        SuggestionPopover(
                            items: people,
                            width: 300,
                            onPick: { typed = $0.email },
                            row: { person in
                                Image("nc-user")
                                    .icon(11)
                                    .foregroundStyle(Theme.Palette.muted)
                                    .frame(width: 14)
                                Text(person.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Palette.ink)
                                Text(person.email)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.Palette.muted)
                                    .lineLimit(1)
                            }
                        )
                    }
                    .zIndex(1)
                Text("Sits under the popover.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.muted)
            }
            .frame(width: 340, height: 160, alignment: .top)
            .padding(24)
            .background(Theme.Palette.bg)
        }
    }
    return Host()
}
