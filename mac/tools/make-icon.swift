// Draws FlowClone's app icon (orange squircle + white waveform bars) and writes an .iconset.
// Usage: swift tools/make-icon.swift <out.iconset>   then   iconutil -c icns <out.iconset>
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // Apple's macOS icon grid: 824×824 body centred in 1024, ~185 corner radius.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    shadow.set()
    NSColor(red: 1.0, green: 0.42, blue: 0.10, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm vertical gradient: lighter saffron at the top, deeper orange at the bottom.
    NSGradient(colors: [NSColor(red: 1.0, green: 0.56, blue: 0.24, alpha: 1),
                        NSColor(red: 1.0, green: 0.42, blue: 0.10, alpha: 1),
                        NSColor(red: 0.90, green: 0.32, blue: 0.04, alpha: 1)])!
        .draw(in: shape, angle: -90)
    // Soft top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Waveform: 5 rounded white bars.
    let heights: [CGFloat] = [210, 380, 520, 330, 190]
    let barW: CGFloat = 74 * s, gap: CGFloat = 50 * s
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = body.midX - total / 2
    NSColor.white.setFill()
    for h in heights {
        let bh = h * s
        NSBezierPath(roundedRect: NSRect(x: x, y: body.midY - bh / 2, width: barW, height: bh),
                     xRadius: barW / 2, yRadius: barW / 2).fill()
        x += barW + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("wrote \(out)")
