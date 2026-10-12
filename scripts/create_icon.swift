#!/usr/bin/env swift
import AppKit
import Foundation

// Run from any working directory: swift /path/to/SiliconPlayer/scripts/create_icon.swift
// Only the final .icns is saved in the project; iconset intermediates live on APFS.
let sourceURL = URL(fileURLWithPath: #filePath).standardizedFileURL
let projectURL = sourceURL.deletingLastPathComponent().deletingLastPathComponent()
let resourcesURL = projectURL.appendingPathComponent("Resources", isDirectory: true)
let manager = FileManager.default
let temporaryURL = manager.temporaryDirectory.appendingPathComponent("SiliconPlayerIcon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = temporaryURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [red, green, blue, alpha])!
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
}

func roundedTriangle() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 414, y: 667))
    path.addQuadCurve(to: CGPoint(x: 441, y: 683), control: CGPoint(x: 414, y: 700))
    path.addLine(to: CGPoint(x: 697, y: 532))
    path.addQuadCurve(to: CGPoint(x: 697, y: 492), control: CGPoint(x: 731, y: 512))
    path.addLine(to: CGPoint(x: 441, y: 341))
    path.addQuadCurve(to: CGPoint(x: 414, y: 357), control: CGPoint(x: 414, y: 324))
    path.closeSubpath()
    return path
}

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "SiliconPlayerIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create image bitmap."])
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = CGFloat(size) / 1_024
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)

    let body = CGPath(roundedRect: CGRect(x: 106, y: 106, width: 812, height: 812), cornerWidth: 184, cornerHeight: 184, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: color(0, 0, 0, 0.32))
    context.setFillColor(color(0.07, 0.09, 0.14))
    context.addPath(body)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(body)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0.055, 0.075, 0.12), color(0.13, 0.17, 0.24)]),
        start: CGPoint(x: 680, y: 140), end: CGPoint(x: 300, y: 930), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.drawRadialGradient(
        gradient([color(0.19, 0.83, 0.68, 0.10), color(0.19, 0.83, 0.68, 0)]),
        startCenter: CGPoint(x: 560, y: 515), startRadius: 0,
        endCenter: CGPoint(x: 560, y: 515), endRadius: 420, options: []
    )
    context.restoreGState()

    // Two quiet, offset geometric planes give the play button a distinct silhouette.
    context.saveGState()
    context.translateBy(x: 500, y: 512)
    context.rotate(by: -0.12)
    let rear = CGPath(roundedRect: CGRect(x: -234, y: -234, width: 468, height: 468), cornerWidth: 79, cornerHeight: 79, transform: nil)
    context.setFillColor(color(0.06, 0.105, 0.15))
    context.addPath(rear)
    context.fillPath()
    context.setStrokeColor(color(0.36, 0.66, 0.64, 0.20))
    context.setLineWidth(size <= 32 ? 9 : 3)
    context.addPath(rear)
    context.strokePath()
    context.restoreGState()

    let panel = CGPath(roundedRect: CGRect(x: 295, y: 297, width: 432, height: 432), cornerWidth: 74, cornerHeight: 74, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0, 0, 0, 0.30))
    context.setFillColor(color(0.12, 0.17, 0.22))
    context.addPath(panel)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(panel)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0.08, 0.13, 0.18), color(0.18, 0.25, 0.29)]),
        start: CGPoint(x: 615, y: 295), end: CGPoint(x: 345, y: 735), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()
    context.setStrokeColor(color(0.75, 0.96, 0.90, 0.08))
    context.setLineWidth(2)
    context.addPath(panel)
    context.strokePath()

    let triangle = roundedTriangle()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -5), blur: 18, color: color(0.22, 0.85, 0.67, 0.20))
    context.setFillColor(color(0.44, 0.91, 0.74))
    context.addPath(triangle)
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(triangle)
    context.clip()
    context.drawLinearGradient(
        gradient([color(0.27, 0.83, 0.65), color(0.69, 0.98, 0.84)]),
        start: CGPoint(x: 550, y: 325), end: CGPoint(x: 460, y: 700), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    if size >= 128 {
        context.saveGState()
        context.addPath(body)
        context.clip()
        context.setStrokeColor(color(0.86, 0.94, 1, 0.09))
        context.setLineWidth(2)
        context.addPath(body)
        context.strokePath()
        context.restoreGState()
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SiliconPlayerIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon PNG."])
    }
    return png
}

do {
    try manager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try manager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: temporaryURL) }
    for logicalSize in [16, 32, 128, 256, 512] {
        for multiplier in [1, 2] {
            let suffix = multiplier == 2 ? "@2x" : ""
            let name = "icon_\(logicalSize)x\(logicalSize)\(suffix).png"
            try drawIcon(size: logicalSize * multiplier).write(to: iconsetURL.appendingPathComponent(name))
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    let outputURL = resourcesURL.appendingPathComponent("AppIcon.icns")
    process.arguments = ["--convert", "icns", "--output", outputURL.path, iconsetURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "SiliconPlayerIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed."])
    }
    print("Created \(outputURL.path)")
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
