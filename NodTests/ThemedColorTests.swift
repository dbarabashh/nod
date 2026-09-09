import AppKit
import SwiftUI
import XCTest
@testable import Nod

/// The whole Light theme rests on one mechanism: a `Theme.Palette` token is a
/// plain `static let` that resolves to a different colour depending on the
/// appearance drawing it. Nothing on screen tells you when that stops working —
/// the app just renders one theme in both — so it is pinned here.
final class ThemedColorTests: XCTestCase {
    private func rgb(_ color: Color, in appearance: NSAppearance.Name) throws -> NSColor {
        try rgb(NSColor(color), in: appearance)
    }

    /// The conversion happens OUTSIDE the drawing block on purpose: a token is
    /// a `static let` built long before anything is drawn, so what has to stay
    /// dynamic is the stored colour, not the moment it was made.
    private func rgb(_ color: NSColor, in appearance: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: appearance))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved)
    }

    func testThemedColorPicksTheAppearanceItIsDrawnIn() throws {
        let color = Color.themed(light: .black, dark: .white)
        XCTAssertEqual(try rgb(color, in: .aqua).redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try rgb(color, in: .darkAqua).redComponent, 1, accuracy: 0.01)
    }

    /// `vibrantDark` is what the capture surface pins itself to, and it is not
    /// `darkAqua` — a token that only matched the exact name would go light
    /// inside the notch.
    func testVibrantDarkResolvesAsDark() throws {
        let color = Color.themed(light: .black, dark: .white)
        XCTAssertEqual(try rgb(color, in: .vibrantDark).redComponent, 1, accuracy: 0.01)
    }

    /// The AppKit half, used by the composer's mention pills — which are drawn
    /// by an `NSTextAttachmentCell`, where a SwiftUI `Color` never reaches.
    func testAppKitThemedColorPicksTheAppearanceItIsDrawnIn() throws {
        let color = NSColor.themed(light: .black, dark: .white)
        XCTAssertEqual(try rgb(color, in: .aqua).redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(try rgb(color, in: .darkAqua).redComponent, 1, accuracy: 0.01)
    }

    func testOpacityAppliedToAThemedTokenSurvivesResolution() throws {
        let alpha = try rgb(Theme.Palette.overlay.opacity(0.4), in: .aqua).alphaComponent
        XCTAssertEqual(alpha, 0.4, accuracy: 0.02)
    }

    /// Text and background have to move together — if `ink` inverts and `bg`
    /// doesn't, Light mode is white on white.
    func testInkAndBackgroundInvertTogether() throws {
        let inkLight = try rgb(Theme.Palette.ink, in: .aqua).brightnessComponent
        let inkDark = try rgb(Theme.Palette.ink, in: .darkAqua).brightnessComponent
        let bgLight = try rgb(Theme.Palette.bg, in: .aqua).brightnessComponent
        let bgDark = try rgb(Theme.Palette.bg, in: .darkAqua).brightnessComponent
        XCTAssertLessThan(inkLight, bgLight)
        XCTAssertGreaterThan(inkDark, bgDark)
    }

    /// The primary pill is the inverse of the surface it sits on. Getting the
    /// polarity wrong leaves the main call to action unreadable in one theme,
    /// which is exactly the bug a picker makes easy to ship.
    func testGlassButtonLabelContrastsItsFillInBothThemes() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fill = try rgb(Theme.Palette.ink, in: appearance).brightnessComponent
            let text = try rgb(Theme.GlassButton.text, in: appearance).brightnessComponent
            XCTAssertGreaterThan(abs(fill - text), 0.5, "\(appearance.rawValue)")
        }
    }
}
