#!/usr/bin/env swift

// Derives AppIcon-Sandbox.appiconset from AppIcon.appiconset by stamping a
// label across the foot of every size.
//
// The sandbox app installs alongside the real one and looks identical in every
// place macOS shows an app — Finder, the update dialog, the login-items list.
// Telling them apart by name alone fails exactly when it matters: reading a
// screenshot from the person running it.
//
// Run after changing the app icon: swift scripts/make-sandbox-icon.swift

import AppKit
import Foundation

let label = "SANDBOX"
let bandColor = NSColor(red: 1.0, green: 0.718, blue: 0.392, alpha: 1)   // goldenrod
let textColor = NSColor(red: 0.11, green: 0.114, blue: 0.122, alpha: 1)  // twilightInk

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Nod/Core/Resources/Assets.xcassets")
let source = root.appendingPathComponent("AppIcon.appiconset")
let destination = root.appendingPathComponent("AppIcon-Sandbox.appiconset")

guard FileManager.default.fileExists(atPath: source.path) else {
    FileHandle.standardError.write(Data("error: \(source.path) not found — run from the repo root\n".utf8))
    exit(1)
}

/// Below this the band is drawn without the word: seven letters across 32px
/// render as a grey smear that reads as a rendering fault rather than a label.
let legibleTextWidth: CGFloat = 96

/// Draws into a bitmap sized in pixels rather than through `NSImage.lockFocus`,
/// which would use the *display's* backing scale and quietly emit 32×32 for a
/// 16pt icon. actool rejects every size that does not match its slot exactly,
/// and does it as a warning — so the whole icon silently goes missing.
func badged(_ image: NSImage, pixelWidth: CGFloat) -> NSBitmapImageRep? {
    let pixels = Int(pixelWidth)
    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }

    output.size = NSSize(width: pixelWidth, height: pixelWidth)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer {
        NSGraphicsContext.restoreGraphicsState()
    }

    let size = NSSize(width: pixelWidth, height: pixelWidth)
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)

    // Just clears the feet of the glyph — any taller and the clipped letterform
    // reads as a broken icon rather than a labelled one.
    let bandHeight = (pixelWidth * 0.23).rounded()
    let band = NSRect(x: 0, y: 0, width: pixelWidth, height: bandHeight)
    bandColor.setFill()
    band.fill()

    guard pixelWidth >= legibleTextWidth else { return output }

    // Size the word to the icon rather than to a point scale: the same glyph
    // has to sit correctly at 128px and at 1024px.
    var fontSize = bandHeight * 0.62
    var attributes: [NSAttributedString.Key: Any] = [:]
    var text = NSAttributedString()
    repeat {
        attributes = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: textColor,
            .kern: fontSize * 0.08
        ]
        text = NSAttributedString(string: label, attributes: attributes)
        fontSize -= 1
    } while text.size().width > pixelWidth * 0.86 && fontSize > 4

    let textSize = text.size()
    text.draw(at: NSPoint(
        x: ((pixelWidth - textSize.width) / 2).rounded(),
        y: ((bandHeight - textSize.height) / 2).rounded()
    ))
    return output
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

try? FileManager.default.removeItem(at: destination)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let contents = try Data(contentsOf: source.appendingPathComponent("Contents.json"))
guard let manifest = try JSONSerialization.jsonObject(with: contents) as? [String: Any],
      let images = manifest["images"] as? [[String: Any]]
else {
    FileHandle.standardError.write(Data("error: unreadable Contents.json\n".utf8))
    exit(1)
}

for entry in images {
    guard let filename = entry["filename"] as? String,
          let size = entry["size"] as? String,
          let scale = entry["scale"] as? String,
          let base = NSImage(contentsOf: source.appendingPathComponent(filename))
    else { continue }

    let points = CGFloat(Int(size.split(separator: "x")[0]) ?? 0)
    let factor = CGFloat(Int(scale.dropLast()) ?? 1)
    let pixels = points * factor

    guard let stamped = badged(base, pixelWidth: pixels) else {
        FileHandle.standardError.write(Data("error: could not render \(filename)\n".utf8))
        exit(1)
    }
    try writePNG(stamped, to: destination.appendingPathComponent(filename))
    print("  \(filename)  \(stamped.pixelsWide)×\(stamped.pixelsHigh)")
}

try contents.write(to: destination.appendingPathComponent("Contents.json"))
print("Wrote \(destination.lastPathComponent)")
