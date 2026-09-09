import AppKit
import SwiftUI

/// One reference to a connected product, drawn as a row that opens it: the
/// product's mark, the title as text rather than as a blue link, and the arrow
/// that says it leaves the app.
///
/// Two sizes for two places. `reference` is a line of an answer, where the
/// title is the point; `compact` sits in a row's metadata line beside a date,
/// and takes that line's weight so it reads as one more fact about the item.
struct ProviderLink: View {
    enum Style {
        case reference
        case compact
    }

    let item: ProviderLinkItem
    var style: Style = .reference

    var body: some View {
        Button { NSWorkspace.shared.open(item.url) } label: {
            switch style {
            case .reference: reference
            case .compact: compact
            }
        }
        .buttonStyle(.plain)
        .linkCursor()
    }

    private var reference: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ProviderMark(provider: item.provider, size: 12)
                // The mark sits on the text's baseline rather than the line
                // box, so titles that wrap keep their first line level with it.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(item.title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(Theme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            if let note = item.note {
                Text(note)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Image("nc-arrow-up-right")
                .icon(9)
                .foregroundStyle(Theme.Palette.muted)
                // Tighter than the row's spacing — it belongs to the title, not
                // beside it — and centred on the text's x-height instead of
                // dropped to its baseline, where a glyph this small reads as
                // falling off the line.
                .padding(.leading, -3)
                .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
        }
    }

    private var compact: some View {
        HStack(spacing: 3) {
            ProviderMark(provider: item.provider, size: 11)
            Text(item.title)
            Image("nc-arrow-up-right").icon(8)
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.Palette.muted)
        .contentShape(Rectangle())
        .help("Open in \(item.provider.displayName)")
    }
}

#Preview {
    let item = ProviderLinkItem(
        provider: .linear,
        title: "NOD-57 — Provide team access",
        url: URL(fileURLWithPath: "/")
    )
    var noted = item
    noted.note = "In Progress"
    return VStack(alignment: .leading, spacing: 16) {
        ProviderLink(item: item)
        ProviderLink(item: noted)
        ProviderLink(item: item, style: .compact)
    }
    .padding(20)
    .background(Theme.Palette.bg)
}
