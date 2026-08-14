#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO

enum VolumeIconError: Error {
    case cannotCreateBitmap
    case cannotCreateCGImage
    case cannotCreateGraphicsContext
    case cannotCreateGradient
    case cannotEncodePNG
    case invalidIconType(String)
    case missingSource(URL)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appendingPathComponent("scripts/dmg")
let skyURL = outputDirectory.appendingPathComponent("background-src.png")
let glyphURL = root.appendingPathComponent("Nod/Core/Resources/Assets.xcassets/NodGlyphInk.imageset/n-ink.png")
let masterPixels = 1_024
let iconRepresentations = [
    ("ic11", 32),
    ("ic12", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic13", 256),
    ("ic09", 512),
    ("ic14", 512),
    ("ic10", 1_024)
]

func bitmap(pixels: Int) throws -> NSBitmapImageRep {
    guard let image = NSBitmapImageRep(
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
    ) else {
        throw VolumeIconError.cannotCreateBitmap
    }
    image.size = NSSize(width: pixels, height: pixels)
    return image
}

func draw(in bitmap: NSBitmapImageRep, operation: () throws -> Void) throws {
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw VolumeIconError.cannotCreateGraphicsContext
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: bitmap.size).fill()
    try operation()
}

func gradient(start: NSColor, end: NSColor) throws -> NSGradient {
    guard let gradient = NSGradient(starting: start, ending: end) else {
        throw VolumeIconError.cannotCreateGradient
    }
    return gradient
}

func coverSourceRect(image: NSImage, destination: NSRect) -> NSRect {
    let destinationRatio = destination.width / destination.height
    let sourceRatio = image.size.width / image.size.height
    if sourceRatio > destinationRatio {
        let width = image.size.height * destinationRatio
        return NSRect(x: (image.size.width - width) / 2, y: 0, width: width, height: image.size.height)
    }
    let height = image.size.width / destinationRatio
    return NSRect(x: 0, y: (image.size.height - height) / 2, width: image.size.width, height: height)
}

func renderIcon(sky: NSImage, glyph: NSImage, isSandbox: Bool) throws -> NSBitmapImageRep {
    let output = try bitmap(pixels: masterPixels)
    try draw(in: output) {
        let bodyRect = NSRect(x: 144, y: 148, width: 736, height: 764)
        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 126, yRadius: 126)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.16, green: 0.18, blue: 0.28, alpha: 0.38)
        shadow.shadowBlurRadius = 38
        shadow.shadowOffset = NSSize(width: 0, height: -28)
        shadow.set()
        NSColor.white.setFill()
        bodyPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        try gradient(
            start: NSColor(red: 0.67, green: 0.71, blue: 0.86, alpha: 1),
            end: NSColor(red: 0.99, green: 0.99, blue: 1, alpha: 1)
        ).draw(in: bodyPath, angle: 90)

        let faceRect = NSRect(x: 168, y: 172, width: 688, height: 720)
        let facePath = NSBezierPath(roundedRect: faceRect, xRadius: 106, yRadius: 106)
        NSGraphicsContext.saveGraphicsState()
        facePath.addClip()
        sky.draw(
            in: faceRect,
            from: coverSourceRect(image: sky, destination: faceRect),
            operation: .sourceOver,
            fraction: 1
        )
        try gradient(
            start: NSColor(white: 1, alpha: 0),
            end: NSColor(white: 1, alpha: 0.40)
        ).draw(in: faceRect, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        glyph.draw(
            in: NSRect(x: 292, y: 340, width: 440, height: 440),
            from: NSRect(origin: .zero, size: glyph.size),
            operation: .sourceOver,
            fraction: 1
        )

        let panelRect = NSRect(x: 168, y: 172, width: 688, height: 126)
        let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 34, yRadius: 34)
        try gradient(
            start: NSColor(red: 0.82, green: 0.85, blue: 0.94, alpha: 0.95),
            end: NSColor(red: 0.96, green: 0.97, blue: 1, alpha: 0.84)
        ).draw(in: panelPath, angle: 90)

        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 192, y: 298))
        divider.line(to: NSPoint(x: 832, y: 298))
        divider.lineWidth = 4
        NSColor(white: 1, alpha: 0.86).setStroke()
        divider.stroke()

        let slot = NSBezierPath(roundedRect: NSRect(x: 374, y: 218, width: 276, height: 24), xRadius: 12, yRadius: 12)
        NSColor(red: 0.22, green: 0.25, blue: 0.35, alpha: 0.76).setFill()
        slot.fill()
        let slotHighlight = NSBezierPath(roundedRect: NSRect(x: 382, y: 226, width: 260, height: 10), xRadius: 5, yRadius: 5)
        NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 0.76).setFill()
        slotHighlight.fill()

        if isSandbox {
            let badgeRect = NSRect(x: 750, y: 194, width: 92, height: 76)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 38, yRadius: 38)
            NSGraphicsContext.saveGraphicsState()
            let badgeShadow = NSShadow()
            badgeShadow.shadowColor = NSColor(red: 0.23, green: 0.17, blue: 0.11, alpha: 0.32)
            badgeShadow.shadowBlurRadius = 10
            badgeShadow.shadowOffset = NSSize(width: 0, height: -4)
            badgeShadow.set()
            NSColor(red: 1, green: 0.72, blue: 0.39, alpha: 1).setFill()
            badgePath.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 766, y: 210, width: 60, height: 44), xRadius: 22, yRadius: 22).fill()
        } else {
            NSColor(red: 0.37, green: 0.47, blue: 0.87, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 790, y: 214, width: 24, height: 24)).fill()
            NSColor(red: 0.80, green: 0.86, blue: 1, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 796, y: 220, width: 12, height: 12)).fill()
        }

        bodyPath.lineWidth = 7
        NSColor(white: 1, alpha: 0.88).setStroke()
        bodyPath.stroke()
        let innerRim = NSBezierPath(roundedRect: NSRect(x: 153, y: 157, width: 718, height: 746), xRadius: 117, yRadius: 117)
        innerRim.lineWidth = 4
        NSColor(red: 0.41, green: 0.46, blue: 0.67, alpha: 0.45).setStroke()
        innerRim.stroke()
        facePath.lineWidth = 4
        NSColor(white: 1, alpha: 0.67).setStroke()
        facePath.stroke()
    }
    return output
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw VolumeIconError.cannotEncodePNG
    }
    try data.write(to: url)
}

func bigEndianBytes(_ value: Int) -> Data {
    Data([
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ])
}

func icnsChunk(type: String, bitmap: NSBitmapImageRep) throws -> Data {
    guard let typeData = type.data(using: .ascii), typeData.count == 4 else {
        throw VolumeIconError.invalidIconType(type)
    }
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw VolumeIconError.cannotEncodePNG
    }
    var chunk = Data()
    chunk.append(typeData)
    chunk.append(bigEndianBytes(pngData.count + 8))
    chunk.append(pngData)
    return chunk
}

func writeIcon(_ bitmap: NSBitmapImageRep, stem: String) throws {
    let pngURL = outputDirectory.appendingPathComponent("\(stem).png")
    let icnsURL = outputDirectory.appendingPathComponent("\(stem).icns")
    try writePNG(bitmap, to: pngURL)

    var payload = Data()
    for (type, pixels) in iconRepresentations {
        payload.append(try icnsChunk(type: type, bitmap: resized(bitmap, pixels: pixels)))
    }
    var icns = Data("icns".utf8)
    icns.append(bigEndianBytes(payload.count + 8))
    icns.append(payload)
    try icns.write(to: icnsURL)
}

func resized(_ bitmap: NSBitmapImageRep, pixels: Int) throws -> NSBitmapImageRep {
    guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw VolumeIconError.cannotEncodePNG
    }
    guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil) else {
        throw VolumeIconError.cannotCreateCGImage
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels
    ]
    guard let resizedImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
        throw VolumeIconError.cannotCreateCGImage
    }
    return NSBitmapImageRep(cgImage: resizedImage)
}

for source in [skyURL, glyphURL] where !FileManager.default.fileExists(atPath: source.path) {
    throw VolumeIconError.missingSource(source)
}
guard let sky = NSImage(contentsOf: skyURL) else {
    throw VolumeIconError.missingSource(skyURL)
}
guard let glyph = NSImage(contentsOf: glyphURL) else {
    throw VolumeIconError.missingSource(glyphURL)
}

try writeIcon(renderIcon(sky: sky, glyph: glyph, isSandbox: false), stem: "volume-icon")
try writeIcon(renderIcon(sky: sky, glyph: glyph, isSandbox: true), stem: "volume-icon-sandbox")
FileHandle.standardOutput.write(Data("wrote production and sandbox DMG volume icons\n".utf8))
