import SwiftUI

/// A labelled card of rows on the home surface: the section label above, the
/// rows inside one surface, hairlines between them indented past the row's
/// leading control.
struct TodayCardList<Item: Identifiable, Row: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().overlay(Theme.Palette.border).padding(.leading, 44)
                    }
                    row(item)
                }
            }
            .surfaceCard()
        }
    }
}

#Preview {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
    }
    return TodayCardList(title: "Waiting on you", items: [Line(text: "Send the deck"), Line(text: "Reply to Sasha")]) { line in
        HStack(spacing: 12) {
            ActionCheckbox(done: false)
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    .padding(20)
    .frame(width: 420)
    .background(Theme.Palette.bg)
}
