import AppKit
import SwiftUI

/// A connected product's own logo, wherever one is shown.
///
/// A brand mark is drawn as it is; only a single-colour glyph — Linear's, or the
/// Nucleo stand-in for a product whose mark hasn't been fetched yet — takes the
/// interface's ink. Tinting the rest turned three products into three shades of
/// one.
///
/// Marks arrive at build time (`scripts/fetch-integration-logos.sh`), not over
/// the network: a logo drawn from a third party's CDN on every launch made the
/// desktop client talk to the broker directly for the first time, replaced a curated
/// asset with an unreviewed one, and drew the stand-in first on a cold cache.
struct ProviderMark: View {
    let provider: IntegrationProvider
    var size: CGFloat = 17
    /// Drawn on a tile in Settings, where it sits in a row of tiles; bare
    /// everywhere else, where it sits among glyphs.
    var tiled = false

    var body: some View {
        Group {
            if Self.ships.contains(provider) {
                Image(provider.iconName)
                    .icon(Self.side(for: provider, size: size))
                    .foregroundStyle(Theme.Palette.ink)
            } else {
                // No asset shipped for this one. Now that a connection can be to any
                // of three thousand products, that is the ordinary case rather than
                // an oversight, and the broker's catalogue is where the mark is.
                CatalogueMark(slug: provider.brokerSlug, size: size)
            }
        }
        .markTile(tiled)
    }

    /// Which providers ship a brand asset. Resolved once — whether an asset is
    /// in the bundle cannot change at runtime, and this is read from view bodies
    /// that re-run per stream flush.
    /// Which products draw their own mark. Read by anything that offers a
    /// product by its logo: a row meant to be recognised cannot show the
    /// stand-in glyph.
    static let ships: Set<IntegrationProvider> = Set(
        IntegrationProvider.allCases.filter { NSImage(named: $0.brandAssetName) != nil }
    )

    /// Which marks take the interface's ink. Asked of the asset rather than
    /// listed, so a colour mark added later starts showing its colours without
    /// anybody editing this, and a product with no mark at all still gets a
    /// legible glyph.
    private static let tinted: Set<IntegrationProvider> = Set(
        IntegrationProvider.allCases.filter { NSImage(named: $0.iconName)?.isTemplate != false }
    )

    /// The stand-in is a Nucleo glyph drawn on the same 18pt grid as the rest
    /// of the interface, so it sits a size smaller than a brand mark that fills
    /// its own square. One rule for the row, the inline mark and the row an
    /// answer draws in TextKit: two copies of the shrink drift apart silently.
    static func side(for provider: IntegrationProvider, size: CGFloat) -> CGFloat {
        tinted.contains(provider) ? size * 0.82 : size
    }

    /// The mark as a piece of text, so it can sit at the end of a sentence
    /// rather than on a line of its own.
    ///
    /// The notch answer is a few hundred points wide and four lines tall; a row
    /// holding one 11pt icon spent a whole line saying what a trailing glyph
    /// says for nothing. Sized in the image rather than by a modifier because a
    /// `Text` draws an image at its natural size and no modifier reaches inside
    /// one.
    ///
    /// Nil for a product whose mark comes from the broker's catalogue: that one
    /// arrives asynchronously, and a sentence cannot wait for it.
    static func inline(_ provider: IntegrationProvider) -> Text? {
        inlineMarks[provider]
    }

    private static let inlineSize: CGFloat = 11

    /// Resolved once, for the same reason `ships` is: this is read from a notch
    /// body that re-runs every second a meeting is recorded, and building the
    /// image per call rasterised the glyph again each time.
    private static let inlineMarks: [IntegrationProvider: Text] = ships.reduce(into: [:]) { marks, provider in
        guard let mark = NSImage.nodIcon(provider.iconName, side: side(for: provider, size: inlineSize)) else { return }
        // A brand mark keeps its own colours; only the stand-in takes the ink.
        mark.isTemplate = tinted.contains(provider)
        marks[provider] = Text(Image(nsImage: mark))
    }
}

/// A catalogue product's own logo, or the stand-in until it arrives.
///
/// Unlike `ProviderMark`, this cannot draw from the asset catalogue: the
/// products here are three thousand and change, and the marks come down with
/// the search. The stand-in is the same Nucleo glyph a product with no mark
/// gets, so a slow fetch reads as "loading" rather than as a broken row.
struct CatalogueMark: View {
    let slug: String
    var size: CGFloat = 17
    /// Drawn on a tile in Settings, where it sits in a row of tiles; bare
    /// everywhere else, where it sits among glyphs.
    var tiled = false

    @EnvironmentObject private var catalogue: IntegrationCatalogue
    @State private var mark: NSImage?

    var body: some View {
        Group {
            if let mark {
                Image(nsImage: mark)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image("nc-puzzle-piece")
                    .icon(size * 0.82)
                    .foregroundStyle(Theme.Palette.muted)
            }
        }
        .markTile(tiled)
        // Keyed on the slug: the row is reused as results change, and without
        // this a scrolled-to product keeps the mark of the one it replaced.
        .task(id: slug) {
            mark = await catalogue.mark(for: slug)
        }
    }
}

/// The 32pt chip a settings row draws a product's mark in — the same tile
/// `SettingsRowIcon` gives a glyph, so a row of products and a row of
/// settings line up.
extension View {
    @ViewBuilder
    func markTile(_ tiled: Bool = true) -> some View {
        if tiled {
            frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
        } else {
            self
        }
    }
}
