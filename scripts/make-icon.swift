#!/usr/bin/env swift
//
// Draws Claude Bridge's app icon and writes Resources/AppIcon.icns.
//
//     swift scripts/make-icon.swift
//
// The icon is generated rather than committed as an opaque blob so it can be
// reviewed and adjusted in a diff. The .icns it produces *is* committed, so a
// normal build does not have to run this.
//
// The mark is a bridge: an arch springing from a deck, which is what the app
// does — carries traffic from Claude Desktop across to whatever is on the other
// side. Drawn with heavy strokes because the smallest rendering is 16pt in a
// Finder list, where anything finer turns to mush.
//
// The palette is deliberately not Anthropic's. This is an independent project
// and its icon should not imply otherwise.

import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")

// MARK: - Palette

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

let backgroundTop = srgb(0x3B4A6B)     // slate blue
let backgroundBottom = srgb(0x161C2B)  // near-black slate
let deckColour = srgb(0xF4F6FB)        // near-white
let archColour = srgb(0xF0A93B)        // amber

// MARK: - Drawing

func drawIcon(size: CGFloat, into context: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(canvas)

    // Big Sur proportions: the rounded square occupies 824/1024 of the canvas
    // with a 185.4/1024 corner radius, leaving the margin the system expects.
    let inset = size * (1 - 824.0 / 1024.0) / 2
    let plate = canvas.insetBy(dx: inset, dy: inset)
    let radius = size * (185.4 / 1024.0)

    let squircle = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(squircle)
    context.clip()

    let colours = [backgroundTop.cgColor, backgroundBottom.cgColor] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colours, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }
    context.restoreGState()

    let L = plate.width
    // Detail is dropped as the canvas shrinks, the way Apple's own icons are
    // redrawn rather than downsampled. At 16pt the hangers merge into the arch
    // and the piers disappear into the deck, so both are left out and the
    // strokes are thickened to keep the silhouette readable.
    let showsHangers = size >= 64
    let showsPiers = size >= 32
    let stroke = L * (size >= 64 ? 0.085 : 0.115)
    let span = L * 0.62
    // Optically centred: the arch carries more weight than the deck, so the
    // deck sits a little below the geometric middle.
    let deckY = plate.minY + L * 0.43
    let left = plate.midX - span / 2
    let right = plate.midX + span / 2

    context.setLineCap(.round)

    // Arch, springing from the deck — a tied arch, the shape most people
    // picture when they picture a bridge.
    context.setStrokeColor(archColour.cgColor)
    context.setLineWidth(stroke)
    context.addArc(center: CGPoint(x: plate.midX, y: deckY),
                   radius: span / 2,
                   startAngle: 0, endAngle: .pi, clockwise: false)
    context.strokePath()

    // Hangers. They read as a bridge at full size and merge into the arch at
    // 16pt, where the silhouette alone still carries it.
    context.setLineWidth(stroke * 0.34)
    context.setStrokeColor(archColour.withAlphaComponent(0.9).cgColor)
    for offset in (showsHangers ? [-0.52, 0.0, 0.52] : []) as [CGFloat] {
        let x = plate.midX + span / 2 * offset
        let y = deckY + sqrt(pow(span / 2, 2) - pow(span / 2 * offset, 2))
        context.move(to: CGPoint(x: x, y: deckY + stroke * 0.1))
        context.addLine(to: CGPoint(x: x, y: y - stroke * 0.3))
        context.strokePath()
    }

    // The deck runs almost the full width of the plate. Stopping it at the
    // arch, with legs beneath, made the mark read as a table; carrying it out
    // to the edges is what says "this spans something".
    context.setStrokeColor(deckColour.cgColor)
    context.setLineWidth(stroke)
    let deckInset = L * (showsPiers ? 0.085 : 0.06)
    context.move(to: CGPoint(x: plate.minX + deckInset, y: deckY))
    context.addLine(to: CGPoint(x: plate.maxX - deckInset, y: deckY))
    context.strokePath()

    // Short piers under the springing points, enough to lift the deck without
    // turning into legs.
    context.setLineWidth(stroke * 0.8)
    for x in (showsPiers ? [left, right] : []) {
        context.move(to: CGPoint(x: x, y: deckY - stroke * 0.4))
        context.addLine(to: CGPoint(x: x, y: deckY - L * 0.13))
        context.strokePath()
    }
}

func renderPNG(size: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("could not allocate a \(size)pt bitmap") }

    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    // Each size is drawn at its own scale rather than downsampled from 1024,
    // so the strokes stay crisp at 16 and 32pt.
    drawIcon(size: CGFloat(size), into: graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode the \(size)pt bitmap")
    }
    return data
}

// MARK: - Iconset

let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The sizes iconutil expects, each as 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    try renderPNG(size: base)
        .write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try renderPNG(size: base * 2)
        .write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let resources = root.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let icns = resources.appendingPathComponent("AppIcon.icns")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }

// A large PNG for the README and the GitHub social preview.
try renderPNG(size: 512).write(to: resources.appendingPathComponent("icon-512.png"))

print("Wrote \(icns.path)")
