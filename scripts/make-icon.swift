#!/usr/bin/env swift
import AppKit
import Foundation

// Original Talkie artwork, generated locally from paths and gradients.
// Usage: swift scripts/make-icon.swift <output.iconset> <output.icns>

enum IconError: LocalizedError {
    case usage
    case render
    case encode
    case iconutil(Int32)

    var errorDescription: String? {
        switch self {
        case .usage: "Usage: swift scripts/make-icon.swift <output.iconset> <output.icns>"
        case .render: "Could not create the Talkie icon bitmap."
        case .encode: "Could not encode the Talkie icon PNG."
        case .iconutil(let status): "iconutil failed with exit status \(status)."
        }
    }
}

func drawIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
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
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw IconError.render }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.shouldAntialias = true
    context.imageInterpolation = .high
    let cg = context.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    // macOS icon silhouette: a generous canvas margin and a quiet soft shadow.
    let face = NSBezierPath(roundedRect: NSRect(x: 95, y: 102, width: 834, height: 834), xRadius: 188, yRadius: 188)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.12, alpha: 0.25)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -14)
    shadow.set()
    NSColor(calibratedRed: 0.65, green: 0.29, blue: 0.14, alpha: 1).setFill()
    face.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    face.addClip()
    let clay = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.78, green: 0.43, blue: 0.27, alpha: 1), 0),
        (NSColor(calibratedRed: 0.72, green: 0.35, blue: 0.20, alpha: 1), 0.42),
        (NSColor(calibratedRed: 0.62, green: 0.26, blue: 0.13, alpha: 1), 1)
    )!
    clay.draw(in: face, angle: -80)
    let light = NSGradient(starting: NSColor(calibratedRed: 1, green: 0.82, blue: 0.63, alpha: 0.14), ending: .clear)!
    light.draw(fromCenter: NSPoint(x: 310, y: 870), radius: 0, toCenter: NSPoint(x: 410, y: 740), radius: 720, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: NSRect(x: 97, y: 104, width: 830, height: 830), xRadius: 186, yRadius: 186)
    rim.lineWidth = 3
    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    rim.stroke()

    // Draw a lowercase t as a continuous rounded voice-like stroke rather than
    // embedding a font or a raster asset. The open hook keeps its small-size
    // silhouette clear in Finder, the Dock and Command–Tab.
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: 467, y: 739))
    stem.line(to: NSPoint(x: 467, y: 392))
    stem.curve(to: NSPoint(x: 615, y: 327), controlPoint1: NSPoint(x: 467, y: 288), controlPoint2: NSPoint(x: 541, y: 281))
    stem.lineWidth = 94
    stem.lineCapStyle = .round
    stem.lineJoinStyle = .round
    let crossbar = NSBezierPath()
    crossbar.move(to: NSPoint(x: 342, y: 578))
    crossbar.line(to: NSPoint(x: 638, y: 578))
    crossbar.lineWidth = 94
    crossbar.lineCapStyle = .round

    NSGraphicsContext.saveGraphicsState()
    let letterShadow = NSShadow()
    letterShadow.shadowColor = NSColor(calibratedRed: 0.31, green: 0.12, blue: 0.06, alpha: 0.11)
    letterShadow.shadowBlurRadius = 4
    letterShadow.shadowOffset = NSSize(width: 0, height: -4)
    letterShadow.set()
    NSColor(calibratedRed: 0.995, green: 0.972, blue: 0.930, alpha: 1).setStroke()
    stem.stroke()
    crossbar.stroke()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else { throw IconError.encode }
    return data
}

do {
    guard CommandLine.arguments.count == 3 else { throw IconError.usage }
    let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard iconset.pathExtension == "iconset", output.pathExtension == "icns" else { throw IconError.usage }
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 2 ? "@2x" : ""
            let name = "icon_\(size)x\(size)\(suffix).png"
            try drawIcon(pixels: size * scale).write(to: iconset.appendingPathComponent(name), options: .atomic)
        }
    }
    let converter = Process()
    converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    converter.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
    try converter.run()
    converter.waitUntilExit()
    guard converter.terminationStatus == 0 else { throw IconError.iconutil(converter.terminationStatus) }
    print("Generated \(output.path)")
} catch {
    fputs("Talkie icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
