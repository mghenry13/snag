// Snag app icon: expressive wordmark, Sunday Club feel.
// Deep green squircle, cream "Snag" set huge in a fat serif, slight tilt.
// Run: swift tools/make-icon.swift <outdir> [fontName]
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "iconset"
let fontName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Young Serif"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let green = NSColor(srgbRed: 0x2F/255.0, green: 0x5D/255.0, blue: 0x43/255.0, alpha: 1)   // deep leaf green
let greenDark = NSColor(srgbRed: 0x27/255.0, green: 0x4E/255.0, blue: 0x38/255.0, alpha: 1)
let cream = NSColor(srgbRed: 0xF2/255.0, green: 0xE9/255.0, blue: 0xD2/255.0, alpha: 1)   // warm cream

func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = s * 0.098
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Subtle vertical gradient so the green feels printed, not flat
    NSGradient(starting: green, ending: greenDark)?.draw(in: squircle, angle: -90)

    squircle.setClip()

    // Fit "Snag" to ~96% of the tile width
    let word = "Snag"
    var fontSize = rect.width * 0.5
    var font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .black)
    func attrs(_ f: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: f, .foregroundColor: cream, .kern: -f.pointSize * 0.02]
    }
    var textSize = NSAttributedString(string: word, attributes: attrs(font)).size()
    fontSize *= (rect.width * 0.96) / textSize.width
    font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .black)
    let a = attrs(font)
    textSize = NSAttributedString(string: word, attributes: a).size()

    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.translateBy(x: rect.midX, y: rect.midY)
    ctx.rotate(by: -4.5 * .pi / 180)
    // Optical vertical centering: cap height sits high, nudge down a touch
    NSAttributedString(string: word, attributes: a).draw(
        at: NSPoint(x: -textSize.width / 2, y: -textSize.height / 2 - fontSize * 0.02)
    )
    ctx.restoreGState()

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

if outDir.hasSuffix(".preview") {
    writePNG(draw(size: 512), "\(outDir)/preview.png", pixels: 512)
    print("preview at \(outDir)/preview.png using \(fontName)")
} else {
    for (pts, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
        let px = pts * scale
        let name = scale == 1 ? "icon_\(pts)x\(pts).png" : "icon_\(pts)x\(pts)@2x.png"
        writePNG(draw(size: CGFloat(px)), "\(outDir)/\(name)", pixels: px)
    }
    print("iconset written to \(outDir) using \(fontName)")
}
