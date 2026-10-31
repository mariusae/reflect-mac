import AppKit
import ReflectUI
import PrismCore

/// ⌘O: a note found by typing some of its name, over the page.
final class Finder: NSView, NSTextFieldDelegate {
    /// The places a query finds, best first.
    var search: ((String) -> [Place])?
    /// Told what was chosen, and whether to open it in a column of its own.
    var onChoose: ((Place, _ newColumn: Bool) -> Void)?
    var onClose: (() -> Void)?

    private let card = NSView()
    private let field = NSTextField()
    private let divider = NSView()
    private let hint = NSTextField(labelWithString: "")
    /// The rows, scrolled when there are more than fit.
    private let list = NSScrollView()
    private let listDocument = FlippedView()
    private var rows: [FinderRow] = []
    private var places: [Place] = []
    private var selection = 0
    private var face: Typeface = .lato
    /// What the field asks for, empty.
    var placeholder = "Go to a note"
    var hintText = "↩ Open   ⌘↩ Beside"
    /// Where its card's top middle goes, opened from a title: nil, high in the middle.
    var anchor: NSPoint? { didSet { needsLayout = true } }
    private var rowHeight: CGFloat { places.contains { $0.trail != nil } ? 54 : 40 }

    private static let limit = 60
    /// How many rows show at once: the rest scrolled to.
    private static let shown = 9

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 0.5
        card.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            return shadow
        }()
        addSubview(card)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.textColor = Ink.text
        card.addSubview(field)
        divider.wantsLayer = true
        card.addSubview(divider)
        hint.alignment = .right
        card.addSubview(hint)
        list.drawsBackground = false
        list.contentView.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.scrollerStyle = .overlay
        list.verticalScrollElasticity = .none
        list.documentView = listDocument
        card.addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func open(face: Typeface, query: String = "") {
        self.face = face
        field.font = face.font(size: 21)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: face.font(size: 21), .foregroundColor: Ink.faint,
        ])
        field.stringValue = query
        window?.makeFirstResponder(field)
        mouse = NSEvent.mouseLocation
        refresh()
    }

    var query: String { field.stringValue }

    /// Where the pointer was last seen. A row choosing itself under a still
    /// pointer — opened over it, or come there as the query changed — is
    /// not the pointer's doing; only moving it chooses.
    private var mouse = NSPoint.zero

    private func hovered(_ index: Int) {
        let location = NSEvent.mouseLocation
        guard location != mouse else { return }
        mouse = location
        select(index)
    }

    private func refresh() {
        places = Array((search?(field.stringValue) ?? []).prefix(Self.limit))
        selection = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = places.enumerated().map { index, place in
            let row = FinderRow(place: place, face: face, thumbnail: places.contains { $0.cover != nil })
            row.onHover = { [weak self] in self?.hovered(index) }
            row.onClick = { [weak self] newColumn in self?.choose(index, newColumn: newColumn) }
            listDocument.addSubview(row)
            return row
        }
        select(0)
        needsLayout = true
    }

    private func select(_ index: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(index, 0), rows.count - 1)
        for (i, row) in rows.enumerated() { row.selected = i == selection }
        // Chosen past what shows: scrolled to.
        let row = rows[selection]
        if row.frame.height > 0 { row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -8)) }
    }

    private func choose(_ index: Int, newColumn: Bool = false) {
        guard places.indices.contains(index) else { return }
        onChoose?(places[index], newColumn)
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = Ink.paper.cgColor
            card.layer?.borderColor = Ink.rule.cgColor
            divider.layer?.backgroundColor = Ink.rule.cgColor
        }
        let width = min(600, bounds.width - 48)
        let fieldHeight: CGFloat = 60
        let listHeight = CGFloat(min(rows.count, Self.shown)) * rowHeight + 16
        let height = fieldHeight + (rows.isEmpty ? 0 : 1 + listHeight)
        if let anchor {
            // Dropped from the title it was opened from: under it, about its middle.
            let x = min(max(16, floor(anchor.x - width / 2)), bounds.width - 16 - width)
            card.frame = NSRect(x: x, y: anchor.y - height, width: width, height: height)
        } else {
            card.frame = NSRect(x: floor((bounds.width - width) / 2), y: bounds.height - floor(bounds.height * 0.18) - height,
                                width: width, height: height)
        }
        let fieldSize = field.intrinsicContentSize.height
        hint.attributedStringValue = NSAttributedString(string: hintText, attributes: [
            .font: face.font(size: 11.5), .foregroundColor: Ink.faint,
        ])
        // A label draws a couple of points in from its edges: room for them.
        let hintSize = hint.attributedStringValue.size()
        let hintWidth = ceil(hintSize.width) + 6
        hint.frame = NSRect(x: width - 22 - hintWidth, y: height - fieldHeight + floor((fieldHeight - hintSize.height) / 2),
                            width: hintWidth, height: ceil(hintSize.height) + 2)
        field.frame = NSRect(x: 22, y: height - fieldHeight + floor((fieldHeight - fieldSize) / 2),
                             width: hint.frame.minX - 22 - 12, height: fieldSize)
        divider.frame = NSRect(x: 0, y: height - fieldHeight - 1, width: width, height: rows.isEmpty ? 0 : 1)
        list.isHidden = rows.isEmpty
        list.frame = NSRect(x: 0, y: 0, width: width, height: rows.isEmpty ? 0 : listHeight)
        listDocument.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * rowHeight + 16)
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 8, y: 8 + CGFloat(i) * rowHeight, width: width - 16, height: rowHeight)
        }
    }

    /// The wheel over it: its list's, never the page's under it.
    override func scrollWheel(with event: NSEvent) {}

    override func mouseDown(with event: NSEvent) {
        if !card.frame.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    /// ⌘↩ opens the choice in a column of its own — taken here, before the
    /// menus, where it is the editor's.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command || flags == [.command, .shift], event.charactersIgnoringModifiers == "\r", window?.firstResponder === field.currentEditor() {
            choose(selection, newColumn: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(moveDown(_:)): select(selection + 1)
        case #selector(moveUp(_:)): select(selection - 1)
        case #selector(insertNewline(_:)): choose(selection)
        case #selector(cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }
}

final class FinderRow: NSView {
    var onHover: (() -> Void)?
    /// Clicked: with ⌘, for a column of its own.
    var onClick: ((_ newColumn: Bool) -> Void)?
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            title.textColor = selected ? Ink.text : Ink.secondary
            needsDisplay = true
        }
    }
    private let title: NSTextField
    private let detail: NSTextField
    private let trail: NSTextField?
    private let badges = NoteBadges()
    /// Its cover, small before the name; nil with no room kept for one.
    private let thumbnail: CoverBanner?

    init(place: Place, face: Typeface, thumbnail: Bool = false) {
        title = NSTextField(labelWithString: place.title)
        detail = NSTextField(labelWithString: place.detail ?? "")
        trail = place.trail.map { NSTextField(labelWithString: $0) }
        self.thumbnail = thumbnail ? Place.thumbnail(place.cover) : nil
        super.init(frame: .zero)
        if let thumbnail = self.thumbnail { addSubview(thumbnail) }
        if let trail {
            trail.font = face.font(size: 11.5)
            trail.textColor = Ink.faint
            trail.lineBreakMode = .byTruncatingHead
            addSubview(trail)
        }
        title.font = face.font(size: 15.5)
        title.textColor = Ink.secondary
        title.lineBreakMode = .byTruncatingTail
        detail.font = face.font(size: 12.5)
        detail.textColor = Ink.faint
        detail.alignment = .right
        addSubview(title)
        addSubview(detail)
        badges.flags = place.flags
        badges.size = 12
        addSubview(badges)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let detailWidth = min(180, ceil(detail.intrinsicContentSize.width) + 4)
        let h = title.intrinsicContentSize.height
        let marks = badges.intrinsicContentSize
        let room = marks.width > 0 ? marks.width + 10 : 0
        var x: CGFloat = 14
        if let thumbnail {
            let side: CGFloat = 26
            thumbnail.frame = NSRect(x: x, y: floor((bounds.height - side) / 2), width: side, height: side)
            x += side + 10
        }
        // The flags just after the name, however long it is.
        let titleWidth = min(ceil(title.attributedStringValue.size().width) + 4, bounds.width - x - 14 - detailWidth - 12 - room)
        // The path to a row over it, its own words under.
        let trailHeight = trail.map { ceil($0.intrinsicContentSize.height) } ?? 0
        let titleY = trail == nil ? floor((bounds.height - h) / 2) : floor((bounds.height - h - trailHeight) / 2)
        title.frame = NSRect(x: x, y: titleY, width: titleWidth, height: h)
        trail?.frame = NSRect(x: x, y: title.frame.maxY, width: bounds.width - x - 14 - detailWidth - 12, height: trailHeight)
        badges.frame = NSRect(x: title.frame.maxX + 6, y: floor((bounds.height - marks.height) / 2), width: marks.width, height: marks.height)
        let dh = detail.intrinsicContentSize.height
        detail.frame = NSRect(x: bounds.width - 14 - detailWidth, y: floor((bounds.height - dh) / 2), width: detailWidth, height: dh)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags.contains(.command)) }

    // To VoiceOver: what was found, to open — here, or beside.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title.stringValue }
    override func accessibilityValue() -> Any? { [detail.stringValue, trail?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ") }
    override func isAccessibilitySelected() -> Bool { selected }
    override func accessibilityPerformPress() -> Bool {
        onClick?(false)
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Open Beside") { [weak self] in
            self?.onClick?(true)
            return true
        }]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        Ink.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
