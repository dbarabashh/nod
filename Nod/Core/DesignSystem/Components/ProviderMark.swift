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

    var body: some View {
        if Self.ships.contains(provider) {
            Image(provider.iconName)
                // The stand-in is a Nucleo glyph drawn on the same 18pt grid as
                // the rest of the interface, so it sits a size smaller than a
                // brand mark that fills its own square.
                .icon(Self.tinted.contains(provider) ? size * 0.82 : size)
                .foregroundStyle(Theme.Palette.ink)
        } else {
            // No asset shipped for this one. Now that a connection can be to any
            // of three thousand products, that is the ordinary case rather than
            // an oversight, and the broker's catalogue is where the mark is.
            CatalogueMark(slug: provider.brokerSlug, size: size)
        }
    }

    /// Which providers ship a brand asset. Resolved once — whether an asset is
    /// in the bundle cannot change at runtime, and this is read from view bodies
    /// that re-run per stream flush.
    private static let ships: Set<IntegrationProvider> = Set(
        IntegrationProvider.allCases.filter { NSImage(named: $0.brandAssetName) != nil }
    )

    /// Which marks take the interface's ink. Asked of the asset rather than
    /// listed, so a colour mark added later starts showing its colours without
    /// anybody editing this, and a product with no mark at all still gets a
    /// legible glyph.
    private static let tinted: Set<IntegrationProvider> = Set(
        IntegrationProvider.allCases.filter { NSImage(named: $0.iconName)?.isTemplate != false }
    )
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
        .modifier(CatalogueMarkTile(tiled: tiled))
        // Keyed on the slug: the row is reused as results change, and without
        // this a scrolled-to product keeps the mark of the one it replaced.
        .task(id: slug) {
            mark = await catalogue.mark(for: slug)
        }
    }
}

private struct CatalogueMarkTile: ViewModifier {
    let tiled: Bool

    func body(content: Content) -> some View {
        if tiled {
            content
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radii.chip, style: .continuous)
                        .fill(Theme.Palette.surfaceStrong)
                )
        } else {
            content
        }
    }
}
