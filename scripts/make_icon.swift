// Renders the app icon: dark rounded square with two concentric gauge rings
// (outer = Claude, coral; inner = Codex, white).
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: artwork fills ~80% of the canvas
    let inset = s * 0.1
    let box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.08, alpha: 1)])!
        .draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke()
    bg.lineWidth = max(1, s * 0.004)
    bg.stroke()

    let c = NSPoint(x: box.midX, y: box.midY)
    func ring(_ r: CGFloat, _ w: CGFloat, _ frac: CGFloat, _ color: NSColor) {
        let t = NSBezierPath()
        t.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
        t.lineWidth = w
        NSColor(white: 1, alpha: 0.09).setStroke()
        t.stroke()
        let a = NSBezierPath()
        a.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
        a.lineWidth = w
        a.lineCapStyle = .round
        color.setStroke()
        a.stroke()
    }
    let w = box.width * 0.085
    ring(box.width * 0.30, w, 0.68, NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
    ring(box.width * 0.17, w, 0.40, NSColor(white: 0.96, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}
print("icon written to \(out)")
