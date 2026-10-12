import AppKit
import ReflectCore

/// A link's card — a post, a video, a page — hidden from the note: a "–" on
/// its corner while the pointer is over it, or its menu, or the link's.
/// Hidden, the link is written `[text](address "no card")`, so every
/// device shows it without; shown again, as it was.
extension OutlineTextView {
    private static let hideSide: CGFloat = 22

    /// Where a card's "–" is: on its top right corner, half over it.
    package static func cardHide(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - hideSide / 2 - 2, y: frame.minY - hideSide / 2 + 2, width: hideSide, height: hideSide)
    }

    /// Whether a picture is a link's card, not a picture.
    package func isLinkCard(_ box: ImageBox) -> Bool { box.isCard || images?.isCard(box.source) == true }

    /// The card under the pointer, its "–" shown — kept while the pointer
    /// is on the "–", which reaches past the card's corner.
    func hoverCard(_ frame: NSRect?, at point: NSPoint?) {
        let kept = hoveredCardFrame.flatMap { old in
            point.map { Self.cardHide(in: old).insetBy(dx: -2, dy: -2).contains($0) } == true ? old : nil
        }
        let next = isEditable ? frame ?? kept : nil
        guard next != hoveredCardFrame else { return }
        if let old = hoveredCardFrame { setNeedsDisplay(old.insetBy(dx: -16, dy: -16)) }
        hoveredCardFrame = next
        if let next { setNeedsDisplay(next.insetBy(dx: -16, dy: -16)) }
    }

    /// Whether the link at a place in a row shows a card.
    func hasCard(row: Int, offset: Int) -> Bool {
        guard paragraphRanges.indices.contains(row), let storage = textStorage else { return false }
        let at = paragraphRanges[row].location + offset
        guard at < storage.length, let box = storage.attribute(.outlineImage, at: at, effectiveRange: nil) as? ImageBox else { return false }
        return isLinkCard(box)
    }

    /// The card in a frame hidden.
    func hideCard(at frame: NSRect) {
        guard let (box, _) = outlineLayout.pictureFrame(at: NSPoint(x: frame.midX, y: frame.midY), origin: textContainerOrigin),
              let location = rangeOfPicture(box)?.location else { return }
        let row = rowIndex(at: location)
        hoveredCardFrame = nil
        setNeedsDisplay(frame.insetBy(dx: -16, dy: -16))
        setCard(row: row, offset: location - paragraphRanges[row].location, hidden: true)
    }

    /// The link at a place in a row, its card hidden or shown: undone as one.
    func setCard(row: Int, offset: Int, hidden: Bool) {
        let before = rows
        guard before.indices.contains(row), let changed = LinkTitle.settingCard(before[row].text, at: offset, hidden: hidden) else {
            return NSSound.beep()
        }
        var after = before
        after[row].text = changed.text
        replace(before, with: after, actionName: hidden ? "Hide Card" : "Show Card")
    }
}

extension OutlineLayoutManager {
    /// Draws a card's "–", to hide it.
    package static func drawCardHide(in frame: NSRect) {
        let badge = OutlineTextView.cardHide(in: frame)
        let circle = NSBezierPath(ovalIn: badge)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
        let dash = NSBezierPath()
        dash.move(to: NSPoint(x: badge.midX - 5, y: badge.midY))
        dash.line(to: NSPoint(x: badge.midX + 5, y: badge.midY))
        dash.lineWidth = 1.6
        dash.lineCapStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        dash.stroke()
    }
}
