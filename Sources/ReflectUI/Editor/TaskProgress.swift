import AppKit
import ReflectCore

/// A note's tasks and checklist items: how many there are, how many done —
/// folded rows' too — and where the next one not done is.
extension OutlineTextView {
    /// Done, and all: nil when the note has none.
    package var checkboxProgress: (done: Int, total: Int)? {
        let all = Row.unfold(rows)
        let boxes = all.filter { $0.task != nil }
        guard !boxes.isEmpty else { return nil }
        return (boxes.filter { $0.task?.isDone == true }.count, boxes.count)
    }

    /// Takes the caret to the next task or checklist item not done after it
    /// — round to the first — opening the fold it is in. Says whether there
    /// was one.
    @discardableResult
    package func goToNextUnfinished() -> Bool {
        if selectedRows != nil { leaveRowSelection() }
        let caretRow = rowIndex(at: selectedRange().location)
        for _ in 0..<32 {
            let shown = rows
            let open = shown.indices.filter { shown[$0].task != nil && shown[$0].task?.isDone != true }
            if let next = open.first(where: { $0 > caretRow }) ?? open.first {
                // Past the checkbox's own text: at the start of what it says.
                restoreCaret(CaretPosition(row: next, offset: 0))
                scrollRangeToVisible(selectedRange())
                showFindIndicator(for: NSRange(location: selectedRange().location,
                                               length: max(0, paragraphRanges[next].length - 1)))
                return true
            }
            // None showing: the first fold holding one, opened.
            guard let folded = shown.indices.first(where: { index in
                Row.unfold(shown[index].folded).contains { $0.task != nil && $0.task?.isDone != true }
            }) else { return false }
            perform("Expand", on: folded..<(folded + 1)) { rows, selection in
                OutlineEditing.unfold(&rows, at: selection.lowerBound)
                return selection
            }
        }
        return false
    }
}

/// A ring whose rim fills, clockwise from the top, with the share done —
/// and, all done, a full ring with a tick.
package final class ProgressRingButton: NSButton {
    package var progress: (done: Int, total: Int) = (0, 0) {
        didSet {
            needsDisplay = true
            toolTip = progress.total == 0 ? nil
                : progress.done == progress.total ? "All \(progress.total) done — click to go through them"
                : "\(progress.done) of \(progress.total) done — click for the next"
            setAccessibilityValue(toolTip)
        }
    }

    package override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 30, height: 24))
        // A size of its own, for the toolbar to make room for.
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        isBordered = false
        title = ""
        setAccessibilityLabel("Progress")
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 24) }

    package override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 15
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        ProgressRing.draw(Checkboxes.Progress(done: progress.done, total: progress.total), in: rect, lineWidth: 2.2,
                          flipped: isFlipped, dimmed: isHighlighted)
    }
}

/// The ring the progress of some checkboxes is shown in: its rim filling,
/// clockwise from the top, with the share done — and, all done, whole, with
/// a tick in it when there is room for one.
package enum ProgressRing {
    package static func draw(_ progress: Checkboxes.Progress, in rect: NSRect, lineWidth width: CGFloat, flipped: Bool,
                     tick: Bool = true, track: NSColor = .quaternaryLabelColor, dimmed: Bool = false) {
        let ring = rect.insetBy(dx: width / 2, dy: width / 2)
        let center = NSPoint(x: ring.midX, y: ring.midY)
        let radius = ring.width / 2

        let rim = NSBezierPath(ovalIn: ring)
        rim.lineWidth = width
        track.setStroke()
        rim.stroke()

        guard progress.total > 0 else { return }
        let share = CGFloat(progress.share)
        (dimmed ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.controlAccentColor).setStroke()
        if share >= 1 {
            let full = NSBezierPath(ovalIn: ring)
            full.lineWidth = width
            full.stroke()
            guard tick else { return }
            // Down to the left, then up to the right, as seen.
            let mark = NSBezierPath()
            let down: CGFloat = flipped ? 1 : -1
            let scale = radius / 6.4
            mark.move(to: NSPoint(x: center.x - 3 * scale, y: center.y))
            mark.line(to: NSPoint(x: center.x - 0.8 * scale, y: center.y + 2.3 * down * scale))
            mark.line(to: NSPoint(x: center.x + 3.2 * scale, y: center.y - 2.4 * down * scale))
            mark.lineWidth = 1.8
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.stroke()
        } else if share > 0 {
            // From twelve o'clock, clockwise.
            let arc = NSBezierPath()
            let start: CGFloat = flipped ? -90 : 90
            let end = flipped ? start + 360 * share : start - 360 * share
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: !flipped)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }
}
