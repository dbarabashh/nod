import AppKit
import XCTest
@testable import Nod

/// Nucleo assets carry no intrinsic point size, so `.icon(9)` sizes the SVG
/// *canvas* — how big the glyph looks depends on how much of its own canvas the
/// artwork fills. Four assets came from Nucleo's 20-unit stroke set instead of
/// the 18-unit fill set and covered ~70% of it against the family's ~89%, so
/// they rendered a quarter smaller than the icon sitting next to them in the
/// same row. Nothing in the Swift code can see that, which is why it is
/// asserted here against the rasterised asset.
final class GlyphIconInkTests: XCTestCase {
    /// Share of the rendered box the artwork actually covers.
    private func inkFraction(_ name: String) throws -> Double {
        let bundle = Bundle(for: MeetingSession.self)
        let image = try XCTUnwrap(
            bundle.image(forResource: name) ?? NSImage(named: name),
            "missing asset \(name)"
        )
        let side = 96
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var minX = side, minY = side, maxX = -1, maxY = -1
        for row in 0 ..< side {
            for column in 0 ..< side where (rep.colorAt(x: column, y: row)?.alphaComponent ?? 0) > 0.06 {
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        XCTAssertGreaterThan(maxX, minX, "\(name) drew nothing")
        return Double(max(maxX - minX, maxY - minY) + 1) / Double(side)
    }

    /// Ratio between the largest and smallest glyph in a group that appears in
    /// one row. 1.0 is identical; the bug this covers was 1.28.
    private func spread(_ names: [String]) throws -> Double {
        let fractions = try names.map { try inkFraction($0) }
        for (name, fraction) in zip(names, fractions) {
            print("  \(name) ink \(String(format: "%.3f", fraction))")
        }
        return try XCTUnwrap(fractions.max()) / XCTUnwrap(fractions.min())
    }

    /// The meeting bar's utility row: mic, screen-share visibility, open Nod.
    func testMeetingBarUtilityGlyphsMatch() throws {
        XCTAssertLessThan(try spread(["nc-mic", "nc-stack-perspective", "nc-window-pointer"]), 1.12)
    }

    /// The recap card's footer: copy, and open the meeting in the main window.
    func testRecapFooterGlyphsMatch() throws {
        XCTAssertLessThan(try spread(["nc-files-2", "nc-arrow-up-right"]), 1.12)
    }

    /// One control, two states — the same button swaps these two as you start
    /// and finish editing a summary, so a size change reads as a layout jump.
    func testEditToggleGlyphsMatch() throws {
        XCTAssertLessThan(try spread(["nc-pen-writing", "nc-check"]), 1.12)
    }

    func testMuteToggleGlyphsMatch() throws {
        XCTAssertLessThan(try spread(["nc-mic", "nc-mic-slash"]), 1.12)
    }
}
