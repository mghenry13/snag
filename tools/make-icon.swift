// Renders the Snag app icon: michaelhenry.studio feel.
// Near-black #030712 squircle, signature yellow #FFEE00 snag-hook arrow
// dropping into a tray. Run: swift tools/make-icon.swift <outdir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let bg = NSColor(srgbRed: 0x03/255.0, green: 0x07/255.0, blue: 0x12/255.0, alpha: 1)
let border = NSColor(srgbRed: 0x37/255.0, green: 0x41/255.0, blue: 0x51/255.0, alpha: 1)
let yellow = NSColor(srgbRed: 1.0, green: 0xEE/255.0, blue: 0.0, alpha: 1)

func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: content squircle inset ~10%, corner radius ~22.5% of the shape
    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    bg.setFill()
    squircle.fill()
    border.withAlphaComponent(0.85).setStroke()
    squircle.lineWidth = max(s * 0.008, 1)
    squircle.stroke()

    // Glyph geometry (in unit space of the squircle)
    let w = rect.width
    let cx = rect.midX
    let stroke = w * 0.075

    // The snag hook: starts up-right, curves over, drops straight down (an arrow
    // with a hooked tail — "snagged" mid-fall)
    let hook = NSBezierPath()
    hook.lineWidth = stroke
    hook.lineCapStyle = .round
    hook.lineJoinStyle = .round
    let topY = rect.minY + w * 0.72
    let hookStartX = cx - w * 0.20
    hook.move(to: NSPoint(x: hookStartX, y: topY - w * 0.10))
    hook.curve(to: NSPoint(x: cx, y: topY),
               controlPoint1: NSPoint(x: hookStartX, y: topY - w * 0.015),
               controlPoint2: NSPoint(x: cx - w * 0.11, y: topY))
    hook.curve(to: NSPoint(x: cx + w * 0.075, y: topY - w * 0.09),
               controlPoint1: NSPoint(x: cx + w * 0.055, y: topY),
               controlPoint2: NSPoint(x: cx + w * 0.075, y: topY - w * 0.035))
    hook.line(to: NSPoint(x: cx + w * 0.075, y: rect.minY + w * 0.40))
    yellow.setStroke()
    hook.stroke()

    // Arrow head at the bottom of the drop
    let ax = cx + w * 0.075
    let ay = rect.minY + w * 0.385
    let head = NSBezierPath()
    head.lineWidth = stroke
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.move(to: NSPoint(x: ax - w * 0.10, y: ay + w * 0.095))
    head.line(to: NSPoint(x: ax, y: ay))
    head.line(to: NSPoint(x: ax + w * 0.10, y: ay + w * 0.095))
    head.stroke()

    // The tray: open bracket catching the drop
    let tray = NSBezierPath()
    tray.lineWidth = stroke
    tray.lineCapStyle = .round
    tray.lineJoinStyle = .round
    let ty = rect.minY + w * 0.235
    let tw = w * 0.27
    let th = w * 0.10
    tray.move(to: NSPoint(x: cx - tw, y: ty + th))
    tray.line(to: NSPoint(x: cx - tw, y: ty))
    tray.line(to: NSPoint(x: cx + tw, y: ty))
    tray.line(to: NSPoint(x: cx + tw, y: ty + th))
    tray.stroke()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, _ path: String, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

for (pts, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = pts * scale
    let name = scale == 1 ? "icon_\(pts)x\(pts).png" : "icon_\(pts)x\(pts)@2x.png"
    writePNG(draw(size: CGFloat(px)), "\(outDir)/\(name)", pixels: px)
}
print("iconset written to \(outDir)")
