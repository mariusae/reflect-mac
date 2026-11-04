import AppKit
import PrismCore
import ReflectCore
import ReflectUI

/// Where a row goes, chosen under its Move to…: today and tomorrow, and
/// the notes pinned, offered straight away; typed, the days and notes the
/// words name, found as they are typed — or a note of that name, made.
@MainActor
final class MovePicker: NSViewController, NSTextFieldDelegate, NSPopoverDelegate {
    struct Choice: Equatable {
        var title: String
        var detail: String?
        var symbol: String
        /// The note it is; nil, one to make of `title`.
        var path: String?
        var pinned = false
    }

    private let session: Session
    private let source: String
    private let chosen: (String) -> Void
    private let closed: () -> Void
    private let field = NSTextField()
    private let list = FlippedView()
    private var choices: [Choice] = []
    private var lines: [ChoiceLine] = []
    private var selected = 0
    private var popover: NSPopover?
    private static let width: CGFloat = 320
    private static let lineHeight: CGFloat = 30

    /// `chosen`: the path chosen, made if need be. `closed`: gone, chosen or not.
    init(session: Session, source: String, chosen: @escaping (String) -> Void, closed: @escaping () -> Void) {
        self.session = session
        self.source = source
        self.chosen = chosen
        self.closed = closed
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(relativeTo rect: NSRect, of view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = self
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: rect, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
        view.window?.makeFirstResponder(nil)
        popover.contentViewController?.view.window?.makeFirstResponder(field)
    }

    override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        root.autoresizingMask = [.width, .height]
        field.placeholderString = "Move to…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.cell?.isScrollable = true
        root.addSubview(field)
        let rule = NSBox()
        rule.boxType = .separator
        rule.frame = NSRect(x: 0, y: 40, width: Self.width, height: 1)
        root.addSubview(rule)
        root.addSubview(list)
        view = root
        update()
    }

    // MARK: Choices

    private func update() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        choices = query.isEmpty ? offered() : found(query)
        selected = 0
        for line in lines { line.removeFromSuperview() }
        lines = choices.enumerated().map { i, choice in
            let line = ChoiceLine(choice)
            line.onHover = { [weak self] in self?.select(i) }
            line.onClick = { [weak self] in self?.choose(i) }
            list.addSubview(line)
            return line
        }
        layout()
        select(0)
    }

    /// Before anything is typed: today, if it is not the note's day, and
    /// tomorrow; then the notes pinned.
    private func offered() -> [Choice] {
        let today = Day.today
        var offered = [today, today.adding(1)].map(dayChoice).filter { $0.path != source }
        offered += session.index.pinned.filter { $0.path != source }.prefix(8).map { entry in
            Choice(title: entry.shown, detail: nil, symbol: "doc.text", path: entry.path, pinned: true)
        }
        return offered
    }

    /// The days and notes the words name, best first; a note by them to make
    /// if none is called that.
    private func found(_ query: String) -> [Choice] {
        var found: [Choice] = []
        // A day named in part — `next we`, `fri` — as it will be named whole.
        let lowered = query.lowercased()
        for phrase in Self.dayPhrases where phrase.hasPrefix(lowered) && phrase != lowered {
            guard let day = DayQuery.day(phrase), found.count < 3 else { continue }
            let choice = dayChoice(day)
            if choice.path != source, !found.contains(where: { $0.path == choice.path }) { found.append(choice) }
        }
        for candidate in LinkSuggestions.candidates(query, index: session.index, limit: 8) where !candidate.isRiver {
            let choice: Choice
            if candidate.isDay, let day = Day(candidate.name) {
                choice = dayChoice(day)
            } else if let path = session.index.resolve(candidate.name) {
                choice = Choice(title: candidate.title, detail: nil, symbol: candidate.isTopic ? "number" : "doc.text", path: path,
                                pinned: session.index.entry(path)?.pin != nil)
            } else {
                continue
            }
            if choice.path != source, !found.contains(where: { $0.path == choice.path }) { found.append(choice) }
        }
        if !found.contains(where: { $0.title.caseInsensitiveCompare(query) == .orderedSame }) {
            found.append(Choice(title: query, detail: nil, symbol: "square.and.pencil", path: nil))
        }
        return found
    }

    private static let dayPhrases: [String] = {
        let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        return ["today", "tomorrow", "next week"] + weekdays + weekdays.map { "next " + $0 }
    }()

    private func dayChoice(_ day: Day) -> Choice {
        let named = [0: "Today", 1: "Tomorrow", -1: "Yesterday"]
        let detail = named.first { Day.today.adding($0.key) == day }?.value
        var title = day.description
        if let date = day.date {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(day.year == Day.today.year ? "EEEMMMd" : "EEEMMMdyyyy")
            title = formatter.string(from: date)
        }
        return Choice(title: title, detail: detail, symbol: "calendar", path: GraphPaths.dailyPath(for: day))
    }

    private func layout() {
        field.frame = NSRect(x: 14, y: 11, width: Self.width - 28, height: 20)
        var y: CGFloat = 6
        for line in lines {
            line.frame = NSRect(x: 6, y: y, width: Self.width - 12, height: Self.lineHeight)
            y += Self.lineHeight
        }
        let listHeight = lines.isEmpty ? 0 : y + 6
        list.frame = NSRect(x: 0, y: 41, width: Self.width, height: listHeight)
        // The popover the size of what is in it, as that changes: else
        // it keeps the size it first had, and this sits at its bottom.
        let size = NSSize(width: Self.width, height: 41 + listHeight)
        preferredContentSize = size
        if let popover { popover.contentSize = size } else { view.setFrameSize(size) }
    }

    private func select(_ index: Int) {
        guard lines.indices.contains(index) else { return }
        selected = index
        for (i, line) in lines.enumerated() { line.isSelected = i == index }
    }

    private func choose(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        let choice = choices[index]
        guard let path = choice.path ?? session.note(titled: choice.title) else { return NSSound.beep() }
        popover?.close()
        chosen(path)
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) { update() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): select(max(0, selected - 1))
        case #selector(NSResponder.moveDown(_:)): select(min(lines.count - 1, selected + 1))
        case #selector(NSResponder.insertNewline(_:)): choose(selected)
        case #selector(NSResponder.cancelOperation(_:)): popover?.close()
        default: return false
        }
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        closed()
    }
}

/// One place to move to: its mark, its name, and what it is — a pin, or
/// which day.
private final class ChoiceLine: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true } } }
    private let choice: MovePicker.Choice

    init(_ choice: MovePicker.Choice) {
        self.choice = choice
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(choice.path == nil ? "Create new note \(choice.title)" : choice.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let middle = bounds.midY
        if let symbol = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: 10 + (18 - size.width) / 2, y: middle - size.height / 2, width: size.width, height: size.height))
        }
        let title = choice.path == nil ? "Create new note “\(choice.title)”" : choice.title
        let font = NSFont.systemFont(ofSize: 13.5)
        var right = bounds.width - 10
        if choice.pinned, let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular).applying(.init(paletteColors: [.systemOrange]))) {
            let size = pin.size
            pin.draw(in: NSRect(x: right - size.width, y: middle - size.height / 2, width: size.width, height: size.height))
            right -= size.width + 8
        }
        if let detail = choice.detail {
            let text = NSAttributedString(string: detail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            let size = text.size()
            text.draw(at: NSPoint(x: right - size.width, y: middle - size.height / 2))
            right -= size.width + 10
        }
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let height = text.size().height
        text.draw(with: NSRect(x: 38, y: middle - height / 2, width: max(0, right - 38), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
