import AppKit
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
    private var rows: [FinderRow] = []
    private var places: [Place] = []
    private var selection = 0
    private var face: Typeface = .lato
    /// What the field asks for, empty.
    var placeholder = "Go to a note"
    var hintText = "↩ Open   ⌘↩ Beside   ⇧⌘↩ New Column"
    private var rowHeight: CGFloat { places.contains { $0.trail != nil } ? 54 : 40 }

    private static let limit = 9

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
        refresh()
    }

    var query: String { field.stringValue }

    private func refresh() {
        places = Array((search?(field.stringValue) ?? []).prefix(Self.limit))
        selection = 0
        rows.forEach { $0.removeFromSuperview() }
        rows = places.enumerated().map { index, place in
            let row = FinderRow(place: place, face: face)
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] newColumn in self?.choose(index, newColumn: newColumn) }
            card.addSubview(row)
            return row
        }
        select(0)
        needsLayout = true
    }

    private func select(_ index: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(index, 0), rows.count - 1)
        for (i, row) in rows.enumerated() { row.selected = i == selection }
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
        let height = fieldHeight + (rows.isEmpty ? 0 : 1 + 8 + CGFloat(rows.count) * rowHeight + 8)
        card.frame = NSRect(x: floor((bounds.width - width) / 2), y: bounds.height - floor(bounds.height * 0.18) - height,
                            width: width, height: height)
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
        var y = height - fieldHeight - 1 - 8
        for row in rows {
            y -= rowHeight
            row.frame = NSRect(x: 8, y: y, width: width - 16, height: rowHeight)
        }
    }

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

    init(place: Place, face: Typeface) {
        title = NSTextField(labelWithString: place.title)
        detail = NSTextField(labelWithString: place.detail ?? "")
        trail = place.trail.map { NSTextField(labelWithString: $0) }
        super.init(frame: .zero)
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
        // The flags just after the name, however long it is.
        let titleWidth = min(ceil(title.attributedStringValue.size().width) + 4, bounds.width - 28 - detailWidth - 12 - room)
        // The path to a row over it, its own words under.
        let trailHeight = trail.map { ceil($0.intrinsicContentSize.height) } ?? 0
        let titleY = trail == nil ? floor((bounds.height - h) / 2) : floor((bounds.height - h - trailHeight) / 2)
        title.frame = NSRect(x: 14, y: titleY, width: titleWidth, height: h)
        trail?.frame = NSRect(x: 14, y: title.frame.maxY, width: bounds.width - 28 - detailWidth - 12, height: trailHeight)
        badges.frame = NSRect(x: title.frame.maxX + 6, y: floor((bounds.height - marks.height) / 2), width: marks.width, height: marks.height)
        let dh = detail.intrinsicContentSize.height
        detail.frame = NSRect(x: bounds.width - 14 - detailWidth, y: floor((bounds.height - dh) / 2), width: detailWidth, height: dh)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags.contains(.command)) }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        Ink.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
