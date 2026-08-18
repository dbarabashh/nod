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
/// desktop client talk to Nango directly for the first time, replaced a curated
/// asset with an unreviewed one, and drew the stand-in first on a cold cache.
struct ProviderMark: View {
    let provider: IntegrationProvider
    var size: CGFloat = 17

    var body: some View {
        Image(provider.iconName)
            // The stand-in is a Nucleo glyph drawn on the same 18pt grid as the
            // rest of the interface, so it sits a size smaller than a brand mark
            // that fills its own square.
            .icon(Self.tinted.contains(provider) ? size * 0.82 : size)
            .foregroundStyle(Theme.Palette.ink)
    }

    /// Which marks take the interface's ink. Asked of the asset rather than
    /// listed, so a colour mark added later starts showing its colours without
    /// anybody editing this, and a product with no mark at all still gets a
    /// legible glyph.
    private static let tinted: Set<IntegrationProvider> = Set(
        IntegrationProvider.allCases.filter { NSImage(named: $0.iconName)?.isTemplate != false }
    )
}
