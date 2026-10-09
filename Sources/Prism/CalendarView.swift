import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// A month of days: a dot under each day with a note; for a note with
/// tasks or a checklist, how far along, as a ring about its number. A day
/// clicked is gone to; the arrows, or a swipe, go a month along.
final class CalendarView: NSView {
    var onChoose: ((Day) -> Void)?
    /// A week's number clicked: its note.
    var onChooseWeek: ((Week) -> Void)?
    private var month: NoteCalendar.Month
    private let marks: [Day: NoteCalendar.Mark]
    /// The weeks with a note: their numbers in the weeks' ochre, the rest faint.
    private let notedWeeks: Set<Week>
    private var hoveredWeek: Week?
    private let face: Typeface
    private var hovered: Day?
    private let previous = NSButton()
    private let next = NSButton()

    override var isFlipped: Bool { true }

    static let size = NSSize(width: 338, height: 318)
    private static let cell: CGFloat = 40
    /// The column of week numbers, before the days.
    private static let weekColumn: CGFloat = 30
    private static let top: CGFloat = 76

    init(month: NoteCalendar.Month, marks: [Day: NoteCalendar.Mark], weeks: Set<Week> = [], face: Typeface) {
        self.month = month
        self.marks = marks
        self.notedWeeks = weeks
        self.face = face
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        for (button, symbol, step) in [(previous, "chevron.left", -1), (next, "chevron.right", 1)] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: step < 0 ? "Previous Month" : "Next Month")?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.isBordered = false
            button.contentTintColor = Ink.secondary
            button.target = self
            button.action = step < 0 ? #selector(goBack) : #selector(goOn)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func goBack() { show(month.adding(-1)) }
    @objc private func goOn() { show(month.adding(1)) }

    private func show(_ month: NoteCalendar.Month) {
        self.month = month
        hovered = nil
        hoveredWeek = nil
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        next.frame = NSRect(x: bounds.width - 18 - 28, y: 14, width: 28, height: 28)
        previous.frame = next.frame.offsetBy(dx: -30, dy: 0)
    }

    // MARK: Where each day is

    private var weeks: [[Day?]] { NoteCalendar.weeks(of: month) }
    private var left: CGFloat { ((bounds.width - 7 * Self.cell + Self.weekColumn) / 2).rounded() }

    private func weekRect(_ week: Int) -> NSRect {
        NSRect(x: left - Self.weekColumn, y: Self.top + CGFloat(week) * Self.cell, width: Self.weekColumn, height: Self.cell)
    }

    private func week(at point: NSPoint) -> Week? {
        for (w, row) in weeks.enumerated() where weekRect(w).contains(point) { return NoteCalendar.week(ofRow: row) }
        return nil
    }

    private func rect(week: Int, weekday: Int) -> NSRect {
        NSRect(x: left + CGFloat(weekday) * Self.cell, y: Self.top + CGFloat(week) * Self.cell, width: Self.cell, height: Self.cell)
    }

    private func day(at point: NSPoint) -> Day? {
        for (w, week) in weeks.enumerated() {
            for (d, day) in week.enumerated() where rect(week: w, weekday: d).contains(point) { return day }
        }
        return nil
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let title = NSAttributedString(string: month.title(), attributes: [
            .font: face.font(size: 16, weight: .bold), .foregroundColor: Ink.text,
        ])
        title.draw(at: NSPoint(x: left - Self.weekColumn + 8, y: 18))
        let weekdayFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        for (i, symbol) in NoteCalendar.weekdaySymbols().enumerated() {
            let text = NSAttributedString(string: symbol, attributes: [.font: weekdayFont, .foregroundColor: Ink.secondary])
            let size = text.size()
            text.draw(at: NSPoint(x: left + CGFloat(i) * Self.cell + (Self.cell - size.width) / 2, y: 52))
        }
        let today = Day.today
        for (w, week) in weeks.enumerated() {
            // The week's number: in the weeks' ochre, faint with no note, a
            // dot under it with one.
            if let number = NoteCalendar.week(ofRow: week) {
                let box = weekRect(w)
                let center = NSPoint(x: box.midX, y: box.midY)
                if number == hoveredWeek {
                    Ink.hover.setFill()
                    NSBezierPath(ovalIn: NSRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)).fill()
                }
                let has = notedWeeks.contains(number)
                let label = NSAttributedString(string: "\(number.week)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: has || number == .current ? Ink.week : Ink.week.withAlphaComponent(0.4),
                ])
                let size = label.size()
                label.draw(at: NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded()))
                if has {
                    Ink.week.setFill()
                    NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y + 9, width: 4, height: 4)).fill()
                }
            }
            for (d, day) in week.enumerated() {
                guard let day else { continue }
                drawDay(day, in: rect(week: w, weekday: d), today: today)
            }
        }
    }

    private func drawDay(_ day: Day, in rect: NSRect, today: Day) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let mark = marks[day]
        if day == hovered {
            Ink.hover.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 17, y: center.y - 17, width: 34, height: 34)).fill()
        }
        // Its to-dos, how far along: a ring about the number.
        if let progress = mark?.progress {
            let side: CGFloat = 30
            ProgressRing.draw(progress, in: NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                              lineWidth: 2, flipped: true, tick: false, track: Ink.rule)
        }
        let isToday = day == today
        let color: NSColor = isToday ? Ink.accent : mark != nil ? Ink.text : Ink.faint
        let text = NSAttributedString(string: "\(day.day)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: isToday || mark != nil ? .semibold : .regular),
            .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded()))
        // A note with nothing to tick off: a dot under the number.
        if mark != nil, mark?.progress == nil {
            (isToday ? Ink.accent : Ink.secondary).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y + 9, width: 4, height: 4)).fill()
        }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let day = day(at: point), week = week(at: point)
        guard day != hovered || week != hoveredWeek else { return }
        hovered = day
        hoveredWeek = week
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveredWeek = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let week = week(at: point) {
            onChooseWeek?(week)
            return
        }
        guard let day = day(at: point) else { return }
        onChoose?(day)
    }

    /// How far a swipe has gone, across or down, while it lasts.
    private var swiped: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : event.scrollingDeltaY
        // A mouse's wheel: each notch a month.
        if event.phase == [], event.momentumPhase == [] {
            if delta > 0 { goBack() } else if delta < 0 { goOn() }
            return
        }
        // A trackpad's swipe: a month, once it ends, the way it went.
        if event.phase == .began { swiped = 0 }
        swiped += delta
        if event.phase == .ended {
            if swiped > 20 { goBack() } else if swiped < -20 { goOn() }
            swiped = 0
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: goBack()
        case 124: goOn()
        default: super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
