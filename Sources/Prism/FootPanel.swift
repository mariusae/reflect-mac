import AppKit
import ReflectUI

/// A column's controls, as a quiet browser has them: one glass panel at its
/// foot. Over, a soft field with the name of what is shown — its cover, or
/// its view's mark, before it — clicked to search. Under, plain marks in a
/// row: back, its sheets dealt out when hovered; home, the views held or
/// right-clicked; what links here, with how many, dealt out when hovered;
/// the menu; and + for a new note. On a column not in use, the field alone.
final class FootPanel: NSView {
    var onSearch: (() -> Void)?
    var onBack: (() -> Void)?
    var onHome: (() -> Void)?
    /// Home held, or right-clicked: the views, from it.
    var onViews: ((NSView) -> Void)?
    var onBacklinks: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onPlus: (() -> Void)?
    /// The pointer onto back's mark, or off it: the sheets behind dealt out, or gathered.
    var onHoverBack: ((Bool) -> Void)?
    /// The pointer onto what links here, or off it.
    var onHoverLinks: ((Bool) -> Void)?

    static let height: CGFloat = 46
    static let compactHeight: CGFloat = 32
    static let width: CGFloat = 250
    private static let fieldHeight: CGFloat = 32
    private static let inset: CGFloat = 7

    override var isFlipped: Bool { true }

    private let glass = NSGlassEffectView()
    private let content = PanelContent()
    private let field = PanelField()
    private let round = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let back = PanelMark(symbol: "chevron.left", tip: "Back")
    private let home = PanelMark(symbol: "house", tip: "Today — hold for the views")
    private let links = PanelMark(symbol: "arrow.turn.up.left", tip: "Linked Here")
    private let more = PanelMark(symbol: "ellipsis", tip: "Note Menu")
    private let plus = PanelMark(symbol: "plus", tip: "New Note")
    private var marks: [PanelMark] { [back, home, links, more, plus] }

    /// Not the column in use: the field alone, small.
    var compact = false { didSet { if compact != oldValue { needsLayout = true } } }
    var canGoBack = false { didSet { back.isEnabled = canGoBack } }
    private(set) var backlinkCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glass)
        glass.contentView = content
        field.wantsLayer = true
        field.onClick = { [weak self] in self?.onSearch?() }
        field.toolTip = "Search (⌘L)"
        content.addSubview(field)
        round.imageScaling = .scaleProportionallyUpOrDown
        round.wantsLayer = true
        round.layer?.masksToBounds = true
        field.addSubview(round)
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .center
        name.textColor = Ink.text
        field.addSubview(name)
        for mark in marks { content.addSubview(mark) }
        back.isEnabled = false
        back.onClick = { [weak self] in self?.onBack?() }
        back.onHover = { [weak self] inside in self?.onHoverBack?(inside) }
        home.onClick = { [weak self] in self?.onHome?() }
        home.onHold = { [weak self] in
            guard let self else { return }
            onViews?(home)
        }
        links.onClick = { [weak self] in self?.onBacklinks?() }
        links.onHover = { [weak self] inside in self?.onHoverLinks?(inside) }
        links.isEnabled = false
        more.onClick = { [weak self] in
            guard let self else { return }
            onMenu?(more)
        }
        plus.onClick = { [weak self] in self?.onPlus?() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: What is shown

    /// The name of what is shown, in the field: its cover before it, or —
    /// a view, not a note — its mark.
    func show(_ title: String, font: NSFont, cover: NSImage?, symbol: String) {
        name.stringValue = title
        name.font = font
        if let cover {
            round.image = cover
            round.contentTintColor = nil
            round.layer?.backgroundColor = nil
        } else {
            round.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            round.contentTintColor = Ink.secondary
            round.layer?.backgroundColor = Ink.text.withAlphaComponent(0.06).cgColor
        }
        needsLayout = true
    }

    /// How many notes link to what is shown: their count by its mark; none, the mark faint.
    func showBacklinks(_ count: Int) {
        backlinkCount = count
        links.count = count
        links.isEnabled = count > 0
    }

    /// Back's mark and what links here's, in this view: what is dealt out comes from them.
    var backFrame: NSRect { back.frame.offsetBy(dx: glass.frame.minX, dy: glass.frame.minY) }
    var linksFrame: NSRect { links.frame.offsetBy(dx: glass.frame.minX, dy: glass.frame.minY) }

    /// The size it wants: whole, or — not in use — as wide as its name.
    var fittingWidth: CGFloat {
        guard compact else { return Self.width }
        let words = nameWidth
        return min(Self.width, max(120, words + 20 + 7 + 28))
    }
    var fittingHeight: CGFloat { compact ? Self.compactHeight : Self.height }

    /// How wide the name is, as its label draws it.
    private var nameWidth: CGFloat { ceil(name.cell?.cellSize.width ?? name.intrinsicContentSize.width) + 4 }

    // MARK: Layout

    override func layout() {
        super.layout()
        glass.frame = bounds
        glass.cornerRadius = compact ? bounds.height / 2 : 20
        content.frame = glass.bounds
        let width = bounds.width, inset = Self.inset
        field.frame = compact ? bounds : NSRect(x: inset, y: inset, width: width - 2 * inset, height: Self.fieldHeight)
        field.layer?.cornerRadius = field.frame.height / 2
        field.layer?.backgroundColor = compact ? nil : Ink.text.withAlphaComponent(0.06).cgColor
        // Controls alone: the name is the window's top's, once its heading has gone up under it.
        field.isHidden = true
        let side: CGFloat = compact ? 20 : 22
        let room = max(0, field.bounds.width - 2 * 12 - side - 7)
        let words = min(room, nameWidth)
        let group = side + 7 + words
        let x = max(12, (field.bounds.width - group) / 2)
        round.frame = NSRect(x: x, y: (field.bounds.height - side) / 2, width: side, height: side)
        round.layer?.cornerRadius = side / 2
        let nameHeight = ceil(name.intrinsicContentSize.height)
        name.frame = NSRect(x: round.frame.maxX + 7, y: (field.bounds.height - nameHeight) / 2, width: words, height: nameHeight)
        // The marks, evenly along the row.
        let rowY: CGFloat = 3
        let slot = (width - 2 * inset) / CGFloat(marks.count)
        for (i, mark) in marks.enumerated() {
            mark.frame = NSRect(x: inset + CGFloat(i) * slot + (slot - 40) / 2, y: rowY, width: 40, height: bounds.height - rowY - inset)
            mark.isHidden = compact
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

/// The glass's content, laid out from the top.
private final class PanelContent: NSView {
    override var isFlipped: Bool { true }
}

/// The field a column's name is in: clicked, searching.
private final class PanelField: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A plain mark in the panel's row: hovered, a soft ground under it.
final class PanelMark: NSButton {
    var onClick: (() -> Void)?
    /// Held a moment, or right-clicked: a second thing it does.
    var onHold: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// A count beside the mark: what links here.
    var count = 0 { didSet { updateTitle() } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var held: Timer?
    private var didHold = false

    init(symbol: String, tip: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        imagePosition = .imageLeading
        isBordered = false
        contentTintColor = Ink.text
        toolTip = tip
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        attributedTitle = count > 0
            ? NSAttributedString(string: " \(count)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                                    .foregroundColor: Ink.text])
            : NSAttributedString(string: "")
        imagePosition = count > 0 ? .imageLeading : .imageOnly
    }

    override var isEnabled: Bool {
        // Not to be used now, but legible still: half the ink, not the faintest.
        didSet { contentTintColor = isEnabled ? Ink.text : Ink.text.withAlphaComponent(0.42) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if isEnabled { onHover?(true) }
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        didHold = false
        if onHold != nil {
            held = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.didHold = true
                    self.onHold?()
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        held?.invalidate()
        held = nil
        guard isEnabled, !didHold, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let onHold { onHold() } else { super.rightMouseDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, isEnabled {
            Ink.hover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}
