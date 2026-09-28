import AppKit
import ReflectCore

/// Pictures and carousels made larger or smaller by a grip in their corner,
/// shown while the pointer is over them: a picture keeps its shape, a
/// carousel takes any. The size is kept as how this Mac shows the notes —
/// the note's Markdown is left as it is. A double click on the grip gives
/// a picture back its own size.
extension OutlineTextView {
    static let gripSide: CGFloat = 18

    /// Where a picture's grip is, in its frame.
    static func grip(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - gripSide - 4, y: frame.maxY - gripSide - 4, width: gripSide, height: gripSide)
    }

    /// Notes the picture under the pointer, whose grip shows.
    func hoverPicture(at point: NSPoint?) {
        let hit = point.flatMap { outlineLayout.pictureFrame(at: $0, origin: textContainerOrigin) }
        let next = hit.flatMap { $0.box.isResizable ? $0.frame : nil }
        guard next != hoveredPictureFrame else { return }
        if let old = hoveredPictureFrame { setNeedsDisplay(old.insetBy(dx: -2, dy: -2)) }
        hoveredPictureFrame = next
        if let next { setNeedsDisplay(next.insetBy(dx: -2, dy: -2)) }
    }

    /// Whether a point is on the grip of the picture under the pointer.
    func onPictureGrip(_ point: NSPoint) -> Bool {
        guard let frame = hoveredPictureFrame else { return false }
        return Self.grip(in: frame).insetBy(dx: -3, dy: -3).contains(point)
    }

    /// Follows the grip until the button comes up, sizing the picture as it
    /// goes; twice clicked, forgets the size it was given.
    func dragPictureGrip(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (box, frame) = outlineLayout.pictureFrame(at: point, origin: textContainerOrigin), box.isResizable,
              let root = images?.root else { return }
        if event.clickCount >= 2 {
            SessionState.shared.setPictureSize(root, box.sizeKey, nil)
            NotificationCenter.default.post(name: ImageStore.didLoad, object: box.source)
            return
        }
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let dx = next.locationInWindow.x - start.x, dy = start.y - next.locationInWindow.y
            resizePicture(box, from: frame, to: CGSize(width: frame.width + dx, height: frame.height + dy))
            if next.type == .leftMouseUp { break }
        }
        hoveredPictureFrame = nil
        hoverPicture(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
    }

    /// Gives a picture a size: no narrower than it can be seen, no wider
    /// than its column; a picture in its own shape, a carousel in the one
    /// asked for. Every note showing it is laid out again.
    func resizePicture(_ box: ImageBox, from frame: NSRect, to size: CGSize) {
        guard let root = images?.root else { return }
        let indent = frame.minX - textContainerOrigin.x
        let column = max(80, (textContainer?.size.width ?? 600) - indent - 2 * (textContainer?.lineFragmentPadding ?? 0))
        let aspect = frame.width > 0 ? frame.height / frame.width : 1
        let width = min(max(size.width, 80), column).rounded()
        let height = box.carousel == nil ? (width * aspect).rounded() : min(max(size.height, 80), 2400).rounded()
        SessionState.shared.setPictureSize(root, box.sizeKey, CGSize(width: width, height: height))
        NotificationCenter.default.post(name: ImageStore.didLoad, object: box.source)
    }
}

extension OutlineLayoutManager {
    /// Draws the grip in a picture's corner.
    static func drawPictureGrip(in frame: NSRect) {
        let grip = OutlineTextView.grip(in: frame)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 4, yRadius: 4).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        for inset in [4.0, 8.0, 12.0] {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: grip.maxX - 3, y: grip.minY + inset))
            line.line(to: NSPoint(x: grip.minX + inset, y: grip.maxY - 3))
            line.lineWidth = 1.2
            line.stroke()
        }
    }
}
