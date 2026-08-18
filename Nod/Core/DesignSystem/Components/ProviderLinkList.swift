import AppKit
import SwiftUI

/// One reference to something in a connected product — a Linear issue, and
/// later a Notion page.
struct ProviderLinkItem: Identifiable, Equatable {
    let provider: IntegrationProvider
    let title: String
    let url: URL

    var id: URL {
        url
    }

    /// One line of an answer, if that line is nothing but a reference.
    ///
    /// Asked a line at a time rather than a paragraph at a time: a reference
    /// almost always follows the sentence that introduces it, inside the same
    /// paragraph, and a rule that only recognised a block of pure links left
    /// exactly those references drawn as blue markdown text.
    ///
    /// Inline decoration inside `Text` can't size the mark — an asset image
    /// renders at its natural size there — and a `Text` link can't carry a
    /// pointer cursor. Both are why these get their own row.
    ///
    /// `- [NOD-57 — Provide team access](https://linear.app/…)`, bullet optional.
    static func item(in line: String) -> ProviderLinkItem? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        for bullet in ["- ", "* ", "• "] where rest.hasPrefix(bullet) {
            rest = rest.dropFirst(bullet.count)
        }
        guard rest.hasPrefix("["), rest.hasSuffix(")"),
              let split = rest.range(of: "](", options: .backwards)
        else { return nil }

        let title = rest[rest.index(after: rest.startIndex) ..< split.lowerBound]
        let link = rest[split.upperBound ..< rest.index(before: rest.endIndex)]
        guard let url = URL(string: String(link)),
              let provider = IntegrationProvider(linkHost: url.host()),
              !title.isEmpty
        else { return nil }
        return ProviderLinkItem(provider: provider, title: String(title), url: url)
    }
}

/// References rendered as rows: the product's mark stands in for the bullet, the
/// title reads as text rather than as a blue link, and the arrow is what says it
/// opens somewhere.
///
/// The only place a reference is drawn. An inline form inside `Text` existed
/// briefly and was deleted — `Text` and `HStack` are different layout systems,
/// so two renderers could be given the same colours and still never line up.
/// The model is told to put references on their own lines instead, which makes
/// one renderer enough.
struct ProviderLinkList: View {
    let items: [ProviderLinkItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                Button { NSWorkspace.shared.open(item.url) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(item.provider.iconName)
                            .icon(11)
                            .foregroundStyle(Theme.Palette.ink.opacity(0.85))
                            // The mark sits on the text's baseline rather than
                            // the line box, so titles that wrap keep their first
                            // line level with it.
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(item.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Image("nc-arrow-up-right")
                            .icon(9)
                            .foregroundStyle(Theme.Palette.muted)
                            // Tighter than the row's spacing — it belongs to
                            // the title, not beside it — and centred on the
                            // text's x-height instead of dropped to its
                            // baseline, where a glyph this small reads as
                            // falling off the line.
                            .padding(.leading, -3)
                            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
                    }
                }
                .buttonStyle(.plain)
                .linkCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
