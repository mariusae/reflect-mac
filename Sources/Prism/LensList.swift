import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// One thing a lens lists: a note, a day, a task — each a row of the same
/// kind, leading to its note.
struct ListItem: Equatable {
    var path: String
    var title: String
    /// At the row's right, small: when.
    var detail: String?
    /// Under its title: what the note starts with, where the words were found.
    var snippet: String?
    /// A circle before it, to tick: a task done, a note out of the inbox.
    var checkable = false
    /// A task, to drag onto a day's hours.
    var task: NoteTask?
}

struct ListSection: Equatable {
    var title: String?
    var items: [ListItem]
}

/// The list beside the notes: what the lens chosen gathers — a
/// month over the days, for Daily; a field over what is found, for Search.
/// A row clicked opens its note; ↑ ↓ go along, ↩ into the note.
final class LensList: NSView {
    var onChoose: ((ListItem, _ beside: Bool) -> Void)?
    var onCheck: ((ListItem) -> Void)?
    var onSearch: ((String) -> Void)?
    var onEnter: (() -> Void)?
    var onDay: ((Day) -> Void)?
    var onWeek: ((Week) -> Void)?

    private(set) var lens: Lens = .daily
    private var sections: [ListSection] = []
    /// The note shown beside: its row lit.
    var selected: String? { didSet { if selected != oldValue { rows.forEach { $0.isChosen = $0.item.task == nil && $0.item.path == selected } } } }
    var typography = Typography() { didSet { rebuild() } }
    var face: Typeface = .system

    private let scroll = NSScrollView()
    private let list = FlippedView()
    private let field = NSSearchField()
    private var calendar: CalendarView?
    private var rows: [ListRow] = []
    private var heads: [NSTextField] = []
    private var empty: NSTextField?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// Its top: the window's buttons, and the lenses after them.
    static let barHeight: CGFloat = 44

    init() {
        super.init(frame: .zero)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        addSubview(scroll)
        field.placeholderString = "Search every note"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(searched)
        field.delegate = self
        field.isHidden = true
        addSubview(field)
        // Nothing of it past its glass.
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A lens's rows, the month with them for Daily.
    func show(_ lens: Lens, sections: [ListSection], month: (NoteCalendar.Month, [Day: NoteCalendar.Mark], Set<Week>)? = nil) {
        let changedLens = lens != self.lens
        self.lens = lens
        field.isHidden = lens != .search
        if let month {
            if calendar == nil || changedLens {
                calendar?.removeFromSuperview()
                let view = CalendarView(month: month.0, marks: month.1, weeks: month.2, face: face)
                view.onChoose = { [weak self] day in self?.onDay?(day) }
                view.onChooseWeek = { [weak self] week in self?.onWeek?(week) }
                addSubview(view)
                calendar = view
            }
        } else {
            calendar?.removeFromSuperview()
            calendar = nil
        }
        guard sections != self.sections || changedLens else { return needsDisplay = true }
        self.sections = sections
        rebuild()
        if changedLens { scroll.contentView.scroll(to: .zero) }
    }

    /// The search field, the keyboard in it, its words chosen.
    func focusSearch() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    @objc private func searched() { onSearch?(field.stringValue) }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        heads.forEach { $0.removeFromSuperview() }
        empty?.removeFromSuperview()
        rows = []
        heads = []
        for section in sections where !section.items.isEmpty {
            if let title = section.title {
                let head = NSTextField(labelWithAttributedString: NSAttributedString(string: title.uppercased(), attributes: typography.label(size: 13)))
                list.addSubview(head)
                heads.append(head)
            }
            for item in section.items {
                let row = ListRow(item: item, typography: typography)
                row.isChosen = item.task == nil && item.path == selected
                row.onClick = { [weak self] beside in self?.onChoose?(item, beside) }
                row.onCheck = { [weak self] in self?.onCheck?(item) }
                list.addSubview(row)
                rows.append(row)
            }
        }
        if rows.isEmpty, lens != .daily {
            var attributes = typography.label(size: 14)
            attributes[.foregroundColor] = Ink.faint
            let text = lens == .search ? (field.stringValue.isEmpty ? "TYPE TO SEARCH" : "NOTHING FOUND") : "NOTHING HERE"
            let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: attributes))
            list.addSubview(label)
            empty = label
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        var top = Self.barHeight
        if !field.isHidden {
            field.frame = NSRect(x: 14, y: top + 10, width: bounds.width - 28, height: 28)
            top = field.frame.maxY + 6
        }
        if let calendar {
            // The month as wide as the list has room for: drawn smaller, not cut off.
            let size = CalendarView.size
            let scale = min(1, (bounds.width - 8) / size.width)
            calendar.frame = NSRect(x: ((bounds.width - size.width * scale) / 2).rounded(), y: top - 18 * scale,
                                    width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
            calendar.bounds = NSRect(origin: .zero, size: size)
            top = calendar.frame.maxY - 14 * scale
        }
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        let width = scroll.contentSize.width
        var y: CGFloat = 4
        var rowIndex = 0
        var headIndex = 0
        for section in sections where !section.items.isEmpty {
            if section.title != nil, heads.indices.contains(headIndex) {
                let head = heads[headIndex]
                headIndex += 1
                head.sizeToFit()
                y += y > 4 ? 12 : 4
                head.frame.origin = NSPoint(x: 20, y: y)
                y += head.frame.height + 6
            }
            for _ in section.items where rows.indices.contains(rowIndex) {
                let row = rows[rowIndex]
                rowIndex += 1
                let height = row.height(width: width - 16)
                row.frame = NSRect(x: 8, y: y, width: width - 16, height: height)
                y += height + 2
            }
        }
        if let empty {
            empty.sizeToFit()
            empty.frame.origin = NSPoint(x: 20, y: 16)
            y = empty.frame.maxY
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 24, scroll.contentSize.height))
    }

    /// On glass of the window's: its top the lenses', and the window's buttons'.
    override func draw(_ dirtyRect: NSRect) {}

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: The keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: step(1)
        case 126: step(-1)
        case 36, 76: onEnter?()
        default: super.keyDown(with: event)
        }
    }

    private func step(_ by: Int) {
        guard !rows.isEmpty else { return NSSound.beep() }
        let at = rows.firstIndex { $0.item.path == selected }.map { $0 + by } ?? (by > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(at) else { return }
        let row = rows[at]
        onChoose?(row.item, false)
        window?.makeFirstResponder(self)
        row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -8))
    }

    // MARK: The pointer: one row lit at a time

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { light(at: event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { light(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { light(at: nil) }
    @objc private func scrolled() { light(at: window?.mouseLocationOutsideOfEventStream) }

    private func light(at point: NSPoint?) {
        let visible = point.map { scroll.contentView.convert($0, from: nil) }.map(scroll.contentView.bounds.contains) ?? false
        let inside = point.map { list.convert($0, from: nil) }
        for row in rows { row.isHovered = visible && inside.map(row.frame.contains) == true }
    }
}

/// A row of a lens's list: its circle, when it can be ticked; its title and
/// when; a line or two of what it says.
final class ListRow: NSView, NSDraggingSource {
    let item: ListItem
    private let typography: Typography
    var onClick: ((_ beside: Bool) -> Void)?
    var onCheck: (() -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    var isChosen = false { didSet { if isChosen != oldValue { needsDisplay = true } } }
    private var downAt: NSPoint?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(item: ListItem, typography: Typography) {
        self.item = item
        self.typography = typography
        super.init(frame: .zero)
        if item.task != nil { toolTip = "Drag onto a day's Schedule to block time for it" }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var titleFont: NSFont { typography.face(style: "Semibold", size: 13.5) ?? typography.face(style: "Bold", size: 13.5) ?? .boldSystemFont(ofSize: 13.5) }
    private var textFont: NSFont { typography.face(style: "Regular", size: 12.5) ?? typography.face(style: "Book", size: 12.5) ?? .systemFont(ofSize: 12.5) }
    private var left: CGFloat { item.checkable ? 36 : 14 }

    private var title: NSAttributedString {
        NSAttributedString(string: item.title.isEmpty ? "Untitled" : item.title,
                           attributes: [.font: item.task == nil ? titleFont : textFont.withSize(13.5), .foregroundColor: item.title.isEmpty ? Ink.faint : Ink.text])
    }

    private var detail: NSAttributedString? {
        guard let text = item.detail, !text.isEmpty else { return nil }
        var attributes = typography.label(size: 13)
        attributes[.foregroundColor] = Ink.faint
        return NSAttributedString(string: text.uppercased(), attributes: attributes)
    }

    private var snippet: NSAttributedString? {
        guard let text = item.snippet, !text.isEmpty else { return nil }
        return NSAttributedString(string: text, attributes: [.font: textFont, .foregroundColor: Ink.secondary])
    }

    private var detailWidth: CGFloat { detail.map { ceil($0.size().width) + 10 } ?? 0 }

    func height(width: CGFloat) -> CGFloat {
        let titleHeight = ceil(title.boundingRect(with: NSSize(width: width - left - 12 - detailWidth, height: 40),
                                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]).height)
        var height = 9 + min(36, titleHeight) + 9
        if let snippet {
            height += min(32, ceil(snippet.boundingRect(with: NSSize(width: width - left - 12, height: 40), options: [.usesLineFragmentOrigin]).height)) + 2
        }
        return height
    }

    private var circle: NSRect { NSRect(x: 13, y: 10, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen || isHovered {
            (isChosen ? Ink.text.withAlphaComponent(0.08) : Ink.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        if item.checkable {
            let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1.2
            Ink.faint.setStroke()
            ring.stroke()
        }
        let width = bounds.width - left - 12
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let titleRect = NSRect(x: left, y: 8, width: width - detailWidth, height: 36)
        let titleBounds = title.boundingRect(with: titleRect.size, options: options)
        title.draw(with: titleRect, options: options)
        if let detail {
            let size = detail.size()
            detail.draw(at: NSPoint(x: bounds.width - 12 - size.width, y: 11))
        }
        if let snippet {
            snippet.draw(with: NSRect(x: left, y: 9 + min(36, ceil(titleBounds.height)) + 1, width: width, height: 32), options: options)
        }
    }

    // To VoiceOver: the note, to open; its circle, an action of its own.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { item.title.isEmpty ? "Untitled" : item.title }
    override func accessibilityValue() -> Any? { [item.detail, item.snippet].compactMap { $0 }.joined(separator: ", ") }
    override func isAccessibilitySelected() -> Bool { isChosen }
    override func accessibilityPerformPress() -> Bool {
        onClick?(false)
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = [NSAccessibilityCustomAction(name: "Open Beside") { [weak self] in
            self?.onClick?(true)
            return true
        }]
        if item.checkable {
            actions.append(NSAccessibilityCustomAction(name: item.task != nil ? "Mark Done" : "Take Out of Inbox") { [weak self] in
                self?.onCheck?()
                return true
            })
        }
        return actions
    }

    override func mouseDown(with event: NSEvent) {
        downAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard let downAt else { return }
        if item.checkable, circle.insetBy(dx: -5, dy: -5).contains(downAt) { return onCheck?() ?? () }
        onClick?(event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downAt, let task = item.task else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downAt.x, point.y - downAt.y) > 3 else { return }
        self.downAt = nil
        let pasteboard = NSPasteboardItem()
        pasteboard.setString("\(task.notePath)\n\(task.ordinal)\n\(item.title)", forType: .prismTask)
        let dragged = NSDraggingItem(pasteboardWriter: pasteboard)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        dragged.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isHovered = false
    }
}

extension LensList: NSSearchFieldDelegate {
    /// ↓ in the field: into what was found, the first of it.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)), !rows.isEmpty else { return false }
        step(1)
        return true
    }
}
