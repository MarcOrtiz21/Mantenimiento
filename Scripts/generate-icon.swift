#!/usr/bin/env swift

import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.dropFirst().first ?? "."
let outputURL = URL(fileURLWithPath: outputDirectory)
let iconsetURL = outputURL.appendingPathComponent("AppIcon.iconset")
let iconURL = outputURL.appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try? FileManager.default.removeItem(at: iconURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2),
]

for variant in variants {
    let pixels = Int(variant.points * variant.scale)
    let image = makeIcon(size: CGFloat(pixels))
    let destination = iconsetURL.appendingPathComponent(variant.name)
    try writePNG(image, to: destination)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", iconURL.path, iconsetURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw IconError.iconutilFailed
}

try? FileManager.default.removeItem(at: iconsetURL)

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSGraphicsContext.current?.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.035, dy: size * 0.035), xRadius: radius, yRadius: radius)

    NSGradient(colors: [
        .systemTeal,
        .systemBlue,
        .controlAccentColor,
    ])?.draw(in: background, angle: -45)

    NSColor.white.withAlphaComponent(0.16).setFill()
    NSBezierPath(ovalIn: rect.insetBy(dx: size * 0.16, dy: size * 0.16)).fill()

    let center = NSPoint(x: rect.midX, y: rect.midY)
    let bladeLength = size * 0.25
    let bladeWidth = size * 0.13

    NSColor.white.setFill()
    for angle in stride(from: 0.0, to: 360.0, by: 120.0) {
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        transform.rotate(byDegrees: angle)
        transform.translateX(by: -center.x, yBy: -center.y)

        let blade = NSBezierPath(ovalIn: NSRect(
            x: center.x - bladeWidth * 0.42,
            y: center.y + size * 0.05,
            width: bladeWidth,
            height: bladeLength
        ))
        blade.transform(using: transform as AffineTransform)
        blade.fill()
    }

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - size * 0.075,
        y: center.y - size * 0.075,
        width: size * 0.15,
        height: size * 0.15
    )).fill()

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw IconError.pngFailed
    }

    try png.write(to: url)
}

enum IconError: Error {
    case pngFailed
    case iconutilFailed
}
