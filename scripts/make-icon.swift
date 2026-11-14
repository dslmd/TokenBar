// Draws the TokenBar app icon (1024x1024 PNG) with CoreGraphics so no binary asset is committed.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit

let size = 1024
guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.png>\n".utf8))
    exit(2)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let gfx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gfx
let ctx = gfx.cgContext

// Rounded-square body with a vertical gradient (macOS icon grid: ~824pt body inside 1024).
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
let path = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let space = CGColorSpaceCreateDeviceRGB()
let colors = [CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1), CGColor(red: 0.36, green: 0.22, blue: 0.80, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

// Four rising bars.
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
let heights: [CGFloat] = [0.28, 0.46, 0.66, 0.88]
let barW: CGFloat = 96, gap: CGFloat = 48
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = (CGFloat(size) - total) / 2
let baseY = body.minY + 190
let maxH = body.height - 380
for h in heights {
    let r = CGRect(x: x, y: baseY, width: barW, height: maxH * h)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.fillPath()
    x += barW + gap
}

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
