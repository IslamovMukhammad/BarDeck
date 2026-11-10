#!/usr/bin/env swift
// Draws the BarDeck app icon in code and writes Resources/AppIcon.iconset.
// Usage: swift Scripts/make_icon.swift   (from the package folder)
//
// The design: a deep indigo tile holding a Touch Bar strip with three cards on it
// (a cover with a progress line, a glowing status lamp, a slider), the strip BarDeck draws.

import AppKit

func drawIcon(_ px: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = px / 1024   // design in 1024 units

    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        // y is measured from the top in the design
        NSRect(x: x * s, y: (1024 - y - h) * s, width: w * s, height: h * s)
    }
    func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: radius * s, yRadius: radius * s)
    }
    func shadowed(_ color: NSColor, blur: CGFloat, y: CGFloat, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowBlurRadius = blur * s
        shadow.shadowOffset = NSSize(width: 0, height: -y * s)
        shadow.set()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }

    // Tile (macOS icon grid: 824 pt body centred in 1024, radius ~185)
    let tile = rounded(r(100, 100, 824, 824), 185)
    shadowed(NSColor.black.withAlphaComponent(0.35), blur: 24, y: 10) { NSColor.black.setFill(); tile.fill() }
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [NSColor(red: 0.20, green: 0.24, blue: 0.62, alpha: 1),
                        NSColor(red: 0.05, green: 0.06, blue: 0.20, alpha: 1)])!
        .draw(in: tile.bounds, angle: -70)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)])!
        .draw(in: rounded(r(40, 40, 620, 620), 310), relativeCenterPosition: .zero)
    NSGraphicsContext.restoreGraphicsState()

    // The strip
    let strip = r(150, 420, 724, 184)
    shadowed(NSColor.black.withAlphaComponent(0.55), blur: 40, y: 16) {
        NSColor(white: 0.03, alpha: 1).setFill()
        rounded(strip, 46).fill()
    }
    NSColor.white.withAlphaComponent(0.12).setStroke()
    let edge = rounded(strip.insetBy(dx: 2 * s, dy: 2 * s), 44)
    edge.lineWidth = 4 * s
    edge.stroke()

    // Card 1: cover + text lines + progress line, washed in the cover colour
    let card1 = r(180, 450, 300, 124)
    NSGraphicsContext.saveGraphicsState()
    rounded(card1, 26).addClip()
    NSGradient(colors: [NSColor(red: 0.98, green: 0.47, blue: 0.32, alpha: 0.55),
                        NSColor(white: 1, alpha: 0.08)])!.draw(in: card1, angle: 0)
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.30, alpha: 1),
                        NSColor(red: 0.62, green: 0.22, blue: 0.62, alpha: 1)])!
        .draw(in: rounded(r(200, 470, 84, 84), 18), angle: -90)
    NSColor.white.withAlphaComponent(0.92).setFill()
    rounded(r(304, 482, 150, 20), 10).fill()
    NSColor.white.withAlphaComponent(0.45).setFill()
    rounded(r(304, 516, 104, 16), 8).fill()
    NSColor.white.withAlphaComponent(0.18).setFill()
    rounded(r(200, 558, 260, 7), 3.5).fill()
    NSColor(red: 1.0, green: 0.62, blue: 0.30, alpha: 1).setFill()
    rounded(r(200, 558, 150, 7), 3.5).fill()

    // Card 2: the status lamp, glowing yellow
    let card2 = r(500, 450, 190, 124)
    NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 0.22).setFill()
    rounded(card2, 26).fill()
    let lamp = NSBezierPath(ovalIn: r(528, 494, 36, 36))
    shadowed(NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1), blur: 26, y: 0) {
        NSColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1).setFill()
        lamp.fill()
    }
    NSColor.white.withAlphaComponent(0.9).setFill()
    rounded(r(584, 492, 84, 18), 9).fill()
    NSColor.white.withAlphaComponent(0.4).setFill()
    rounded(r(584, 522, 64, 14), 7).fill()

    // Card 3: a slider pill with a fill
    let card3 = r(710, 450, 134, 124)
    NSColor(red: 0.35, green: 0.72, blue: 1.0, alpha: 0.25).setFill()
    rounded(card3, 62).fill()
    NSColor.white.withAlphaComponent(0.2).setFill()
    rounded(r(736, 505, 82, 14), 7).fill()
    NSColor(red: 0.35, green: 0.72, blue: 1.0, alpha: 1).setFill()
    rounded(r(736, 505, 52, 14), 7).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: "Resources/AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = drawIcon(CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: out.appendingPathComponent(name))
    }
}
print("Wrote \(out.path)")
