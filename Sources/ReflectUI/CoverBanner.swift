import AppKit
import ReflectCore

/// A note's cover across the top of it: its picture filling the banner,
/// cut to its shape about the middle — the top corners rounded as the card
/// under it is, or every corner, on the page.
@MainActor
package final class CoverBanner: NSView {
    package var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    /// How far down the picture the banner's middle is, from 0 to 1.
    package var focus: CGFloat = 0.5 { didSet { if focus != oldValue { needsDisplay = true } } }
    /// Rounded at the top only — on a card, whose top it is — or all round.
    package var topOnly = true { didSet { if topOnly != oldValue { needsDisplay = true } } }
    package var radius: CGFloat = CardSurface.radius { didSet { if radius != oldValue { needsDisplay = true } } }

    package override var isFlipped: Bool { true }

    /// How tall a banner is across a width: a third of it, within bounds.
    package static func height(width: CGFloat) -> CGFloat {
        min(max((width / 3).rounded(), 110), 280)
    }

    package override func draw(_ dirtyRect: NSRect) {
        let shape = topOnly ? Self.topRounded(bounds, radius: radius) : NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
        bounds.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let y = -(size.height - bounds.height) * min(max(focus, 0), 1)
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: y, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A rectangle with its top corners rounded, in a flipped view.
    private static func topRounded(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }
}
