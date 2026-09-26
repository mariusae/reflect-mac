import AppKit
import ReflectCore

/// A note's tasks and checklist items: how many there are, how many done —
/// folded rows' too — and where the next one not done is.
extension OutlineTextView {
    /// Done, and all: nil when the note has none.
    var checkboxProgress: (done: Int, total: Int)? {
        let all = Row.unfold(rows)
        let boxes = all.filter { $0.task != nil }
        guard !boxes.isEmpty else { return nil }
        return (boxes.filter { $0.task?.isDone == true }.count, boxes.count)
    }

    /// Takes the caret to the next task or checklist item not done after it
    /// — round to the first — opening the fold it is in. Says whether there
    /// was one.
    @discardableResult
    func goToNextUnfinished() -> Bool {
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
final class ProgressRingButton: NSButton {
    var progress: (done: Int, total: Int) = (0, 0) {
        didSet {
            needsDisplay = true
            toolTip = progress.total == 0 ? nil
                : progress.done == progress.total ? "All \(progress.total) done — click to go through them"
                : "\(progress.done) of \(progress.total) done — click for the next"
            setAccessibilityValue(toolTip)
        }
    }

    override init(frame: NSRect) {
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
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 30, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 15
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        let width: CGFloat = 2.2
        let ring = rect.insetBy(dx: width / 2, dy: width / 2)
        let center = NSPoint(x: ring.midX, y: ring.midY)
        let radius = ring.width / 2

        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = width
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        guard progress.total > 0 else { return }
        let share = CGFloat(progress.done) / CGFloat(progress.total)
        let color: NSColor = isHighlighted ? .controlAccentColor.withAlphaComponent(0.6) : .controlAccentColor
        color.setStroke()
        if share >= 1 {
            let full = NSBezierPath(ovalIn: ring)
            full.lineWidth = width
            full.stroke()
            // A tick: down to the left, then up to the right, as seen.
            let tick = NSBezierPath()
            let down: CGFloat = isFlipped ? 1 : -1
            tick.move(to: NSPoint(x: center.x - 3, y: center.y))
            tick.line(to: NSPoint(x: center.x - 0.8, y: center.y + 2.3 * down))
            tick.line(to: NSPoint(x: center.x + 3.2, y: center.y - 2.4 * down))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            tick.stroke()
        } else if share > 0 {
            // From twelve o'clock, clockwise.
            let arc = NSBezierPath()
            let start: CGFloat = isFlipped ? -90 : 90
            let end = isFlipped ? start + 360 * share : start - 360 * share
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: !isFlipped)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }
}
