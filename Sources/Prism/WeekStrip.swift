import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// The week over a day shown on its own page: its seven days, the day shown
/// filled, today in the accent, those with notes marked — a ring for how far
/// their to-dos are along, else a dot. ‹ and › a week along, the day shown
/// kept; a day clicked, gone to; the calendar's mark, the whole month.
final class WeekStrip: NSView, ColumnBlock {
    var metrics: OutlineMetrics { didSet { needsLayout = true; needsDisplay = true } }
    var onChoose: ((Day) -> Void)?
    /// The calendar's mark clicked: the month, from it.
    var onMonth: ((NSView) -> Void)?

    /// The day shown, under the strip.
    private let shown: Day
    /// The week the strip is at: the day shown's, till stepped along.
    private var days: [Day]
    private let marks: [Day: NoteCalendar.Mark]
    private var hovered: Day? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private let back = CloseButton(symbol: "chevron.left", pointSize: 12, toolTip: "The Week Before")
    private let ahead = CloseButton(symbol: "chevron.right", pointSize: 12, toolTip: "The Week After")
    private let month = CloseButton(symbol: "calendar", pointSize: 13, toolTip: "The Month")

    override var isFlipped: Bool { true }
    private static let height: CGFloat = 78

    init(day: Day, marks: [Day: NoteCalendar.Mark], metrics: OutlineMetrics) {
        shown = day
        days = NoteCalendar.week(of: day)
        self.marks = marks
        self.metrics = metrics
        super.init(frame: .zero)
        for (button, action) in [(back, #selector(backClicked)), (ahead, #selector(aheadClicked)), (month, #selector(monthClicked))] {
            button.contentTintColor = Ink.secondary
            button.target = self
            button.action = action
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func backClicked() { step(-7) }
    @objc private func aheadClicked() { step(7) }
    @objc private func monthClicked() { onMonth?(month) }

    private func step(_ by: Int) {
        days = days.map { $0.adding(by) }
        needsDisplay = true
    }

    func desiredHeight(width: CGFloat) -> CGFloat { Self.height }
    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }

    /// Where the days go: across the text's column, clear of the arrows.
    private var row: NSRect {
        let column = min(metrics.columnWidth, bounds.width - 48)
        let x = ((bounds.width - column) / 2).rounded()
        return NSRect(x: x + 28, y: 14, width: max(0, column - 28 - 56), height: 50)
    }

    private func cell(_ i: Int) -> NSRect {
        let row = row, width = row.width / 7
        return NSRect(x: row.minX + CGFloat(i) * width, y: row.minY, width: width, height: row.height)
    }

    override func layout() {
        super.layout()
        let row = row
        back.frame = NSRect(x: row.minX - 28, y: row.maxY - 30, width: 24, height: 24)
        ahead.frame = NSRect(x: row.maxX + 4, y: row.maxY - 30, width: 24, height: 24)
        month.frame = NSRect(x: row.maxX + 30, y: row.maxY - 30, width: 24, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let today = Day.today
        let label = metrics.typography.label(size: 14)
        let symbols = NoteCalendar.weekdaySymbols()
        for (i, day) in days.enumerated() {
            let cell = cell(i)
            // The weekday, in the small capitals labels are in; the month's
            // name over the first of a month.
            let name = day.day == 1 ? Self.monthName(day) : symbols[i]
            let letter = NSAttributedString(string: name.uppercased(), attributes: label)
            letter.draw(at: NSPoint(x: (cell.midX - letter.size().width / 2).rounded(), y: cell.minY))
            let center = NSPoint(x: cell.midX, y: cell.minY + 34)
            let mark = marks[day]
            let chosen = day == shown
            if chosen {
                Ink.text.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)).fill()
            } else if day == hovered {
                Ink.hover.setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30)).fill()
            }
            if let progress = mark?.progress, !chosen {
                ProgressRing.draw(progress, in: NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28),
                                  lineWidth: 1.8, flipped: true, tick: false, track: Ink.rule)
            }
            let color: NSColor = chosen ? Ink.paper : day == today ? Ink.accent : mark != nil ? Ink.text : Ink.faint
            let number = NSAttributedString(string: "\(day.day)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: chosen || day == today || mark != nil ? .semibold : .regular),
                .foregroundColor: color,
            ])
            let size = number.size()
            number.draw(at: NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded()))
            if mark != nil, mark?.progress == nil, !chosen {
                (day == today ? Ink.accent : Ink.secondary).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y + 9, width: 4, height: 4)).fill()
            }
        }
        // A hairline under it, across the text's column.
        let column = min(metrics.columnWidth, bounds.width - 48)
        Ink.rule.setFill()
        NSRect(x: ((bounds.width - column) / 2).rounded(), y: bounds.height - 1, width: column, height: 1).fill()
    }

    private static func monthName(_ day: Day) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return day.date.map(formatter.string(from:)) ?? ""
    }

    private func day(at point: NSPoint) -> Day? {
        days.indices.first { cell($0).insetBy(dx: 0, dy: -4).contains(point) }.map { days[$0] }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { hovered = day(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let day = day(at: convert(event.locationInWindow, from: nil)) { onChoose?(day) }
    }
    override func resetCursorRects() { addCursorRect(row, cursor: .pointingHand) }
}
