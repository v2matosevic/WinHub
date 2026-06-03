#!/usr/bin/env swift
// Generates Resources/WinHub.icns (the app icon) and docs/icon.png (for the
// README) from a vector drawing — no external design assets needed.
// Run from the project root:  swift Scripts/make_icon.swift
import AppKit

/// Draw the WinHub icon at a given pixel size: a deep-indigo rounded square with a
/// clean window card (title bar + traffic lights, red emphasized as a nod to the
/// "close button quits" tweak) and a hint of window content.
func drawIcon(size s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let full = CGRect(x: 0, y: 0, width: s, height: s)

    // Rounded-square background with a subtle vertical gradient for depth.
    let bgRect = full.insetBy(dx: s * 0.055, dy: s * 0.055)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: s * 0.2237, yRadius: s * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.18, green: 0.20, blue: 0.31, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.17, alpha: 1),
    ])?.draw(in: bgRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline inner highlight.
    bg.lineWidth = max(1, s * 0.004)
    NSColor(white: 1, alpha: 0.06).setStroke()
    bg.stroke()

    // Window card with a soft drop shadow.
    let inset = s * 0.265
    let winRect = CGRect(x: inset, y: inset * 0.92, width: s - inset * 2, height: s - inset * 2)
    let win = NSBezierPath(roundedRect: winRect, xRadius: s * 0.055, yRadius: s * 0.055)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.03
    shadow.set()
    NSColor(white: 0.98, alpha: 1).setFill()
    win.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Title bar (rounded only at the top, via clipping to the window path).
    let barHeight = winRect.height * 0.26
    let barRect = CGRect(x: winRect.minX, y: winRect.maxY - barHeight, width: winRect.width, height: barHeight)
    NSGraphicsContext.saveGraphicsState()
    win.addClip()
    NSColor(white: 0.90, alpha: 1).setFill()
    barRect.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Traffic lights.
    let dotRadius = barHeight * 0.18
    let colors = [
        NSColor(calibratedRed: 0.99, green: 0.37, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.79, blue: 0.27, alpha: 1),
        NSColor(calibratedRed: 0.44, green: 0.83, blue: 0.31, alpha: 1),
    ]
    for (i, color) in colors.enumerated() {
        let cx = barRect.minX + barHeight * 0.5 + CGFloat(i) * dotRadius * 3.2
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - dotRadius, y: barRect.midY - dotRadius,
                                    width: dotRadius * 2, height: dotRadius * 2)).fill()
    }

    // A few content lines so it reads as a window.
    let lineX = winRect.minX + winRect.width * 0.12
    let lineH = max(1, s * 0.013)
    NSColor(white: 0, alpha: 0.10).setFill()
    for i in 0..<3 {
        let ly = barRect.minY - winRect.height * 0.16 - CGFloat(i) * winRect.height * 0.13
        let w = winRect.width * 0.55 * (1 - CGFloat(i) * 0.18)
        NSBezierPath(roundedRect: CGRect(x: lineX, y: ly, width: w, height: lineH),
                     xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let docs = root.appendingPathComponent("docs")
let iconset = resources.appendingPathComponent("WinHub.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try? fm.createDirectory(at: docs, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    writePNG(drawIcon(size: px), to: iconset.appendingPathComponent("\(name).png"))
}

// README image.
writePNG(drawIcon(size: 512), to: docs.appendingPathComponent("icon.png"))

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("WinHub.icns").path]
try? convert.run()
convert.waitUntilExit()
try? fm.removeItem(at: iconset)

print("Wrote Resources/WinHub.icns and docs/icon.png")
