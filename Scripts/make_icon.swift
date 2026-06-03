#!/usr/bin/env swift
// Generates Resources/WinHub.icns from a vector drawing — no design assets needed.
// Run from the project root:  swift Scripts/make_icon.swift
import AppKit

/// Draw the WinHub icon at a given pixel size. A deep-indigo rounded square with a
/// clean window glyph and traffic-light dots — a nod to the "close button quits"
/// tweak and to macOS windowing in general.
func drawIcon(size s: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()

    let full = CGRect(x: 0, y: 0, width: s, height: s)

    // Rounded-square background.
    let bgRect = full.insetBy(dx: s * 0.06, dy: s * 0.06)
    let corner = s * 0.2237
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: corner, yRadius: corner)
    NSColor(calibratedRed: 0.137, green: 0.149, blue: 0.227, alpha: 1).setFill()
    bg.fill()

    // Soft top highlight for a little depth.
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    let sheen = NSGradient(colors: [NSColor(white: 1, alpha: 0.10), NSColor(white: 1, alpha: 0.0)])
    sheen?.draw(in: bgRect, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Window glyph.
    let inset = s * 0.27
    let winRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let winRadius = s * 0.05
    let win = NSBezierPath(roundedRect: winRect, xRadius: winRadius, yRadius: winRadius)
    NSColor(white: 0.97, alpha: 1).setFill()
    win.fill()

    // Title bar.
    let barHeight = winRect.height * 0.27
    let barRect = CGRect(x: winRect.minX, y: winRect.maxY - barHeight, width: winRect.width, height: barHeight)
    NSGraphicsContext.saveGraphicsState()
    win.addClip()
    NSColor(white: 0.87, alpha: 1).setFill()
    barRect.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Traffic lights (red emphasized — the close button).
    let dotRadius = barHeight * 0.20
    let centerY = barRect.midY
    let colors = [
        NSColor(calibratedRed: 0.99, green: 0.36, blue: 0.34, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.25, alpha: 1),
        NSColor(calibratedRed: 0.43, green: 0.82, blue: 0.30, alpha: 1),
    ]
    for (i, color) in colors.enumerated() {
        let cx = barRect.minX + barHeight * 0.55 + CGFloat(i) * dotRadius * 3.1
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: cx - dotRadius, y: centerY - dotRadius,
                                    width: dotRadius * 2, height: dotRadius * 2)).fill()
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
let iconset = resources.appendingPathComponent("WinHub.iconset")
try? fm.createDirectory(at: iconset, withIntermediateDirectories: true)

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

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("WinHub.icns").path]
try? convert.run()
convert.waitUntilExit()
try? fm.removeItem(at: iconset)

print("Wrote Resources/WinHub.icns")
