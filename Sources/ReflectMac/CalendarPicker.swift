import AppKit
import ReflectCore

/// A month to pick a day from, dropped down from the toolbar: the days
/// with notes dotted, today in the accent colour, the day being looked at
/// chosen. A click goes to a day — with ⌘, in the split view; the arrows
/// move, Return goes, ‹ and › or a scroll turn the month.
///
/// Down the side, each row's week — ISO weeks, counted from the row's
/// Monday — with a dot for a week with a note; a click goes to its note.
final class CalendarPickerView: NSView {
    /// Told the day picked, and whether in the split view.
    var onPick: ((Day, _ inSplit: Bool) -> Void)?
    /// The days with notes.
    var marked: Set<Day> = [] { didSet { needsDisplay = true } }
    /// How far along a day's tasks and checklist items are; nil for a day
    /// with none. Asked of the days shown, and kept.
    var progress: ((Day) -> Checkboxes.Progress?)? { didSet { progresses.removeAll(); needsDisplay = true } }
    private var progresses: [Day: Checkboxes.Progress?] = [:]

    private func progress(of day: Day) -> Checkboxes.Progress? {
        if let known = progresses[day] { return known }
        let found = marked.contains(day) ? progress?(day) : nil
        progresses[day] = .some(found)
        return found
    }
    /// Told the week picked, and whether in the split view.
    var onPickWeek: ((Week, _ inSplit: Bool) -> Void)?
    /// The weeks with notes.
    var markedWeeks: Set<Week> = [] { didSet { needsDisplay = true } }
    /// The week whose note is being looked at.
    var currentWeek: Week? { didSet { needsDisplay = true } }
    private var hoveredWeek: Week?
    private(set) var selected: Day
    /// The month shown: its first day.
    private var month: Day
    private var hovered: Day?
    private var scrolled: CGFloat = 0

    private let title = NSTextField(labelWithString: "")
    private let previous = NSButton()
    private let next = NSButton()

    static let cell = NSSize(width: 34, height: 32)
    static let header: CGFloat = 40
    static let weekdays: CGFloat = 22
    static let margin: CGFloat = 12
    /// The column of week numbers, before the days.
    static let weekColumn: CGFloat = 30
    static var size: NSSize {
        NSSize(width: margin * 2 + weekColumn + cell.width * 7, height: header + weekdays + cell.height * 6 + margin)
    }

    private var calendar: Calendar { .current }

    init(selected: Day) {
        self.selected = selected
        month = Day(year: selected.year, month: selected.month, day: 1)
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        addSubview(title)
        for (button, symbol, label, action) in [(previous, "chevron.left", "Previous Month", #selector(previousMonth(_:))),
                                                (next, "chevron.right", "Next Month", #selector(nextMonth(_:)))] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            button.toolTip = label
            button.target = self
            button.action = action
            addSubview(button)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Drawn as it is: the popover's vibrancy would blend the faint label
    /// colours darker than the dark ground under them.
    override var allowsVibrancy: Bool { false }

    /// The ink of the calendar, in its own appearance: full for the month's
    /// days, faint for the rest, fainter for rims and hovering.
    private struct Ink {
        let text, secondary, faint, rim, hover: NSColor
    }

    private var ink: Ink {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base: NSColor = dark ? .white : .black
        return Ink(text: base.withAlphaComponent(dark ? 0.92 : 0.85), secondary: base.withAlphaComponent(0.55),
                   faint: base.withAlphaComponent(dark ? 0.38 : 0.3), rim: base.withAlphaComponent(dark ? 0.22 : 0.12),
                   hover: base.withAlphaComponent(dark ? 0.14 : 0.08))
    }

    override func layout() {
        super.layout()
        title.sizeToFit()
        title.setFrameOrigin(NSPoint(x: Self.margin + 6, y: (Self.header - title.frame.height) / 2 + 2))
        next.frame = NSRect(x: bounds.width - Self.margin - 28, y: 8, width: 28, height: 26)
        previous.frame = NSRect(x: next.frame.minX - 30, y: 8, width: 28, height: 26)
    }

    private func update() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        title.stringValue = month.date.map(formatter.string(from:)) ?? ""
        needsLayout = true
        needsDisplay = true
    }

    // MARK: The month

    /// The day in each of the grid's 42 places, from the week the month begins in.
    private var grid: [Day] {
        guard let first = month.date else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        return (0..<42).map { month.adding($0 - lead) }
    }

    private func frame(ofPlace index: Int) -> NSRect {
        NSRect(x: Self.margin + Self.weekColumn + CGFloat(index % 7) * Self.cell.width,
               y: Self.header + Self.weekdays + CGFloat(index / 7) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    /// The week of each of the grid's six rows: the week its Monday is in.
    private var weeks: [Week] {
        let days = grid
        let monday = (2 - calendar.firstWeekday + 7) % 7
        return (0..<6).compactMap { row in days.indices.contains(row * 7 + monday) ? Week(days[row * 7 + monday]) : nil }
    }

    private func frame(ofWeekRow row: Int) -> NSRect {
        NSRect(x: Self.margin, y: Self.header + Self.weekdays + CGFloat(row) * Self.cell.height,
               width: Self.weekColumn - 4, height: Self.cell.height)
    }

    private func week(at point: NSPoint) -> Week? {
        let weeks = weeks
        for row in weeks.indices where frame(ofWeekRow: row).contains(point) { return weeks[row] }
        return nil
    }

    private func day(at point: NSPoint) -> Day? {
        let days = grid
        for index in days.indices where frame(ofPlace: index).contains(point) { return days[index] }
        return nil
    }

    func show(month day: Day) {
        month = Day(year: day.year, month: day.month, day: 1)
        update()
    }

    @objc private func previousMonth(_ sender: Any?) { turn(-1) }
    @objc private func nextMonth(_ sender: Any?) { turn(1) }

    private func turn(_ by: Int) {
        guard let date = month.date, let turned = calendar.date(byAdding: .month, value: by, to: date) else { return }
        show(month: Day(turned))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The weekdays, starting where the calendar starts its week.
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                     .foregroundColor: ink.faint]
        for column in 0..<7 {
            let symbol = symbols[(column + calendar.firstWeekday - 1) % 7] as NSString
            let size = symbol.size(withAttributes: small)
            symbol.draw(at: NSPoint(x: Self.margin + Self.weekColumn + CGFloat(column) * Self.cell.width + (Self.cell.width - size.width) / 2,
                                    y: Self.header + 2), withAttributes: small)
        }

        // The weeks, down the side.
        let heading = "W" as NSString
        let headingSize = heading.size(withAttributes: small)
        heading.draw(at: NSPoint(x: Self.margin + (Self.weekColumn - 4 - headingSize.width) / 2, y: Self.header + 2), withAttributes: small)
        let thisWeek = Week.current
        for (row, week) in weeks.enumerated() {
            let cell = frame(ofWeekRow: row)
            let pill = NSRect(x: cell.minX, y: cell.minY + 4, width: cell.width, height: 22)
            let chosen = week == currentWeek
            if chosen {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            } else if week == hoveredWeek {
                ink.hover.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: week == thisWeek ? .bold : .medium),
                .foregroundColor: chosen ? NSColor.white : week == thisWeek ? NSColor.controlAccentColor : ink.faint,
            ]
            let number = "\(week.week)" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2 - 1), withAttributes: attributes)
            if markedWeeks.contains(week) {
                let dot = NSRect(x: pill.midX - 2, y: pill.maxY - 5, width: 4, height: 4)
                (chosen ? NSColor.white : ink.secondary).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
        // A rule between the weeks and the days.
        ink.rim.setFill()
        NSRect(x: Self.margin + Self.weekColumn - 2, y: Self.header + Self.weekdays + 4, width: 1, height: Self.cell.height * 6 - 8).fill()

        let today = Day.today
        for (index, day) in grid.enumerated() {
            let cell = frame(ofPlace: index)
            let inMonth = day.month == month.month
            let circle = NSRect(x: cell.midX - 13, y: cell.minY + 2, width: 26, height: 26)
            let isSelected = day == selected
            // Its tasks: how far along, round it.
            if let progress = progress(of: day) {
                ProgressRing.draw(progress, in: circle.insetBy(dx: -2.5, dy: -2.5), lineWidth: 2, flipped: true, tick: false,
                                  track: ink.rim, dimmed: !inMonth)
            }
            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else if day == hovered {
                ink.hover.setFill()
                NSBezierPath(ovalIn: circle).fill()
            }
            let color: NSColor = isSelected ? .white
                : day == today ? .controlAccentColor
                : inMonth ? ink.text : ink.faint
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: day == today ? .bold : .regular),
                .foregroundColor: color,
            ]
            let number = "\(day.day)" as NSString
            let size = number.size(withAttributes: attributes)
            number.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2 - 1), withAttributes: attributes)
            // A note that day: a dot under its number.
            if marked.contains(day) {
                let dot = NSRect(x: circle.midX - 2, y: circle.maxY - 6, width: 4, height: 4)
                (isSelected ? NSColor.white : inMonth ? ink.secondary : ink.faint).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    // MARK: Picking

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let day = day(at: point)
        let week = week(at: point)
        if day != hovered || week != hoveredWeek {
            hovered = day
            hoveredWeek = week
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        hoveredWeek = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let week = week(at: point) {
            currentWeek = week
            onPickWeek?(week, event.modifierFlags.contains(.command))
            return
        }
        guard let day = day(at: point) else { return }
        selected = day
        needsDisplay = true
        onPick?(day, event.modifierFlags.contains(.command))
    }

    override func scrollWheel(with event: NSEvent) {
        // A notch, or a good swipe, turns a month.
        scrolled += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        if abs(scrolled) >= 36 {
            turn(scrolled > 0 ? -1 : 1)
            scrolled = 0
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrolled = 0 }
    }

    override func keyDown(with event: NSEvent) {
        let moves: [UInt16: Int] = [123: -1, 124: 1, 125: 7, 126: -7]
        if let by = moves[event.keyCode] {
            selected = selected.adding(by)
            if selected.month != month.month || selected.year != month.year { show(month: selected) }
            needsDisplay = true
        } else if event.keyCode == 36 || event.keyCode == 76 {
            onPick?(selected, event.modifierFlags.contains(.command))
        } else if event.charactersIgnoringModifiers == "t" {
            selected = .today
            show(month: selected)
        } else {
            super.keyDown(with: event)
        }
    }
}
