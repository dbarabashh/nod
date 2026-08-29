import AppKit
import SwiftUI
import XCTest
@testable import Nod

/// `ThemedColorTests` proves an `NSColor` resolves per appearance. This proves
/// the half that actually ships: that SwiftUI hands the token the view's own
/// colour scheme when it draws, so a `static let` in `Theme.Palette` follows
/// Light/Dark without any view asking which one is on.
@MainActor
final class ThemedRenderingTests: XCTestCase {
    private func render(_ view: some View, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        renderer.scale = 1
        return try NSBitmapImageRep(cgImage: XCTUnwrap(renderer.cgImage))
    }

    private func centerPixel(_ view: some View, scheme: ColorScheme) throws -> NSColor {
        let bitmap = try render(view, scheme: scheme)
        let pixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        return try XCTUnwrap(pixel.usingColorSpace(.sRGB))
    }

    func testASurfaceRendersLightInLightAndDarkInDark() throws {
        let surface = Rectangle().fill(Theme.Palette.bg).frame(width: 40, height: 40)
        let light = try centerPixel(surface, scheme: .light)
        let dark = try centerPixel(surface, scheme: .dark)
        XCTAssertGreaterThan(light.brightnessComponent, 0.9)
        // Not pure black on purpose — the dark base is hellonod.app's own
        // `#0B0E16`, so this is "unmistakably dark", not "zero".
        XCTAssertLessThan(dark.brightnessComponent, 0.2)
    }

    /// A settings card is the composite that matters: text token over surface
    /// token over background token. If any one of the three failed to follow,
    /// this is where it shows up as unreadable.
    func testCardTextStaysReadableAgainstItsBackgroundInBothThemes() throws {
        let card = SettingsCard {
            SettingsRow(icon: "nc-gear-2", title: "Appearance", subtitle: nil) { EmptyView() }
        }
        .frame(width: 320)
        .background(Theme.Palette.bg)

        for scheme in [ColorScheme.light, .dark] {
            let bitmap = try render(card, scheme: scheme)
            var darkest = 1.0
            var lightest = 0.0
            for column in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                for row in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    guard let pixel = bitmap.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                    darkest = min(darkest, Double(pixel.brightnessComponent))
                    lightest = max(lightest, Double(pixel.brightnessComponent))
                }
            }
            XCTAssertGreaterThan(lightest - darkest, 0.5, "\(scheme) card has no contrast between text and surface")
        }
    }
}
