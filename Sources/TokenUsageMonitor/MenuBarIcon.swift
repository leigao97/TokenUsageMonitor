import AppKit

/// Menu bar icon: two concentric ring gauges. Outer = Claude, inner = Codex.
/// Arc length = used percent of that provider's most-used window.
/// Template image, so it adapts to light/dark menu bars.
enum MenuBarIcon {
    static func make(outer: Double?, inner: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            ring(center: c, radius: 7.4, width: 2.2, value: outer)
            ring(center: c, radius: 3.6, width: 2.2, value: inner)
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func ring(center: NSPoint, radius: CGFloat, width: CGFloat, value: Double?) {
        // track
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.black.withAlphaComponent(0.28).setStroke()
        track.stroke()

        guard let v = value else { return }
        let frac = max(0.04, min(1, v / 100))
        let arc = NSBezierPath()
        // clockwise from 12 o'clock
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 360 * frac, clockwise: true)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }
}
