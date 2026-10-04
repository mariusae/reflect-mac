import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// A sheet of a column's stack: what a column showed — the timeline, a
/// note, what links to a note, the inbox — and where it was scrolled, put
/// beneath when the column went somewhere else. Going somewhere puts what
/// was there on the stack; going back takes it off again. The stack is the
/// column's history.
struct Sheet {
    var kind: Column.Kind
    /// The note at its top, and how far into it.
    var place: Column.Place?
    /// How far down it was scrolled, for a sheet of no notes of its own.
    var offset: CGFloat
    var title: String
    /// What it looked like when it was left, for ⌘E.
    var snapshot: NSImage?
}

extension Column {
    /// What the column shows now, as a sheet.
    var currentSheet: Sheet {
        Sheet(kind: kind, place: place, offset: scrollOffset, title: Self.title(of: kind, top: current?.ref), snapshot: snapshot())
    }

    /// What a sheet is called: the note it shows, or the day at its top.
    static func title(of kind: Kind, top: NoteRef?) -> String {
        switch kind {
        case .timeline: top.map { name(of: $0).title } ?? "Timeline"
        case .note(let ref): name(of: ref).title
        case .backlinks(let ref): "Linked to " + name(of: ref).title
        case .inbox: "Inbox"
        case .tasks: "Tasks"
        case .search(let query): query.isEmpty ? "Search" : "“\(query)”"
        }
    }

    /// A picture of what the column shows, at three quarters of the
    /// screen's points: enough for a card, small enough to keep many.
    func snapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 0.75), pixelsHigh: Int(bounds.height * 0.75),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = bounds.size
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// The band at a column's top: the edges of the sheets beneath, peeking
/// out over the top one like a stack of paper — each further back higher,
/// a little narrower, a shade darker — and the top sheet's own edge; or,
/// with no stacks, a handle when the pointer is near. Dragged, it picks up
/// the top sheet; clicked, brings up the one just beneath; hovered, lists
/// them.
final class SheetEdges: NSView {
    var count = 0 { didSet { if count != oldValue { needsDisplay = true } } }
    /// The deepest stack's, among the columns: the band's height.
    var depth = 0 { didSet { if depth != oldValue { needsDisplay = true } } }
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// The pointer went down here and moved: the top sheet is picked up.
    var onDrag: ((NSEvent) -> Void)?

    static let most = 3
    /// How far into the top sheet the band reaches.
    static let reach: CGFloat = 8

    override var isFlipped: Bool { true }

    private static let shades = [Ink.dynamic(NSColor(srgbRed: 0.937, green: 0.922, blue: 0.894, alpha: 1),
                                             NSColor(srgbRed: 0.16, green: 0.149, blue: 0.137, alpha: 1)),
                                 Ink.dynamic(NSColor(srgbRed: 0.91, green: 0.894, blue: 0.863, alpha: 1),
                                             NSColor(srgbRed: 0.137, green: 0.125, blue: 0.114, alpha: 1)),
                                 Ink.dynamic(NSColor(srgbRed: 0.882, green: 0.863, blue: 0.831, alpha: 1),
                                             NSColor(srgbRed: 0.118, green: 0.106, blue: 0.098, alpha: 1))]

    override func draw(_ dirtyRect: NSRect) {
        guard depth > 0 else {
            // A sheet alone, and no stacks: a handle to pick it up by, when wanted.
            guard hovering else { return }
            let grip = NSRect(x: bounds.midX - 20, y: bounds.midY - 2, width: 40, height: 4)
            Ink.faint.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
            return
        }
        let top = bounds.height - Self.reach
        let edge = hovering ? Ink.secondary.withAlphaComponent(0.55) : Ink.text.withAlphaComponent(0.16)
        // The sheets beneath, the deepest first, each tucked under the nearer.
        for level in (0..<min(count, Self.most)).reversed() {
            let inset = 6 + CGFloat(level) * 6
            let y = top - CGFloat(level + 1) * Column.sheetStep
            let sheet = NSBezierPath(roundedRect: NSRect(x: inset, y: y, width: bounds.width - 2 * inset, height: top - y + 6),
                                     xRadius: 6, yRadius: 6)
            NSGraphicsContext.saveGraphicsState()
            NSRect(x: 0, y: 0, width: bounds.width, height: top).clip()
            Self.shades[level].setFill()
            sheet.fill()
            edge.setStroke()
            sheet.lineWidth = 0.5
            sheet.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        // The top sheet's own edge: a hairline over its rounded top.
        let r: CGFloat = 6, w = bounds.width, y = top + 0.25
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0.25, y: bounds.height))
        path.line(to: NSPoint(x: 0.25, y: y + r))
        path.appendArc(withCenter: NSPoint(x: r + 0.25, y: y + r), radius: r, startAngle: 180, endAngle: 270, clockwise: false)
        path.line(to: NSPoint(x: w - r - 0.25, y: y))
        path.appendArc(withCenter: NSPoint(x: w - r - 0.25, y: y + r), radius: r, startAngle: 270, endAngle: 0, clockwise: false)
        path.line(to: NSPoint(x: w - 0.25, y: bounds.height))
        path.lineWidth = 0.5
        edge.setStroke()
        path.stroke()
    }

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            onHover?(hovering)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var downAt: NSPoint?

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt else { return }
        let moved = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        guard moved > 4 else { return }
        downAt = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        onClick?()
    }
}

/// The sheets beneath, listed under their edges, the most lately left first.
final class SheetList: NSView {
    var onChoose: ((Int) -> Void)?
    /// A row was picked up and moved: that sheet is being dragged.
    var onDrag: ((Int, NSEvent) -> Void)?
    /// Told when the pointer leaves it.
    var onLeave: (() -> Void)?
    private var rows: [FinderRow] = []

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -4)
            return shadow
        }()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let rowHeight: CGFloat = 34

    /// Shows sheets: their titles, and what kind each is.
    func show(_ sheets: [Sheet], face: Typeface) {
        rows.forEach { $0.removeFromSuperview() }
        rows = sheets.map { sheet in
            let detail: String? = switch sheet.kind {
            case .timeline: "Timeline"
            case .note: nil
            case .backlinks: "Backlinks"
            case .inbox, .tasks: nil
            case .search: "Search"
            }
            let row = FinderRow(place: Place(title: sheet.title, path: "", detail: detail), face: face)
            addSubview(row)
            return row
        }
        needsLayout = true
    }

    var fittingHeight: CGFloat { CGFloat(rows.count) * Self.rowHeight + 12 }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Ink.paper.cgColor
            layer?.borderColor = Ink.rule.cgColor
        }
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 6, y: 6 + CGFloat(i) * Self.rowHeight, width: bounds.width - 12, height: Self.rowHeight)
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseExited(with event: NSEvent) { onLeave?() }

    // Its rows are clicked to raise their sheets, or picked up and dragged.

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    private func row(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return rows.firstIndex { $0.frame.contains(point) }
    }

    private var down: (row: Int, at: NSPoint)?

    override func mouseMoved(with event: NSEvent) {
        let hovered = row(at: event)
        for (i, row) in rows.enumerated() { row.selected = i == hovered }
    }

    override func mouseDown(with event: NSEvent) {
        down = row(at: event).map { ($0, event.locationInWindow) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down else { return }
        guard hypot(event.locationInWindow.x - down.at.x, event.locationInWindow.y - down.at.y) > 4 else { return }
        self.down = nil
        onDrag?(down.row, event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down else { return }
        self.down = nil
        if row(at: event) == down.row { onChoose?(down.row) }
    }
}

/// ⌘E: the column's sheets as the cards of a file, within it, as
/// manifold has them. The sheets beneath the one chosen hang at the back,
/// leaning away, only their title bars showing; the chosen one stands in
/// front of them, whole; those passed over lie flat along the bottom. Each
/// E flips the next one down; letting go of ⌘ brings the chosen one forward
/// to fill the column.
final class SheetSwitcher: NSView {
    private(set) var cards: [SwitcherCard]
    /// The card chosen, by its place in the stack (0 at the bottom).
    private(set) var selection: Int
    private let contentSize: NSSize
    private let background = SwitcherBackground()
    var onPick: ((Int) -> Void)?

    /// Where each card is drawn from: the chosen place, eased toward
    /// `selection`; and how far the switcher is open (0 is the column as it
    /// was, the home card filling it).
    private var place: CGFloat
    private var openness: CGFloat = 0
    private var targetOpenness: CGFloat = 1
    /// The card that fills the column when closed: the top at first, the
    /// chosen one on the way out.
    private var home: Int
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var onClosed: (() -> Void)?
    private(set) var isClosing = false
    private var scrolled: CGFloat = 0

    override var isFlipped: Bool { false }

    /// `sheets` bottom to top.
    init(sheets: [Sheet], contentSize: NSSize, selection: Int, face: Typeface) {
        self.contentSize = contentSize
        self.selection = selection
        // Starting from the top, so the first choice flips down into place.
        place = CGFloat(sheets.count - 1)
        home = sheets.count - 1
        cards = sheets.map { SwitcherCard(sheet: $0, contentSize: contentSize, face: face) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(background)
        for (i, card) in cards.enumerated() {
            card.onClick = { [weak self] in self?.pick(i) }
            addSubview(card)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens, the top sheet dropping down to show the others.
    func present() {
        targetOpenness = 1
        startAnimating()
    }

    /// Moves the choice along: down the stack by default.
    func move(_ delta: Int) {
        guard !isClosing else { return }
        // A stack, not a ring: back down it, or up to the top, no further.
        let next = min(max(selection + delta, 0), cards.count - 1)
        guard next != selection else { return NSSound.beep() }
        selection = next
        startAnimating()
    }

    /// Closes on a card, which comes forward to fill the column, then calls `done`.
    func dismiss(to index: Int, done: @escaping () -> Void) {
        isClosing = true
        home = index
        selection = index
        targetOpenness = 0
        onClosed = done
        startAnimating()
    }

    private func pick(_ i: Int) {
        guard !isClosing else { return }
        selection = i
        onPick?(i)
    }

    // MARK: Animation

    private func startAnimating() {
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            lastTick = 0
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        // Eased toward where they're going, quickly at first.
        place += (CGFloat(selection) - place) * CGFloat(1 - exp(-dt * 14))
        openness += (targetOpenness - openness) * CGFloat(1 - exp(-dt * (isClosing ? 20 : 14)))
        let settled = abs(place - CGFloat(selection)) < 0.002 && abs(openness - targetOpenness) < 0.002
        if settled {
            place = CGFloat(selection)
            openness = targetOpenness
            link.invalidate()
            self.link = nil
        }
        layoutCards()
        if settled, isClosing, let done = onClosed {
            onClosed = nil
            done()
        }
    }

    /// Settles at once where the animation is going: for a script's picture.
    func settle() {
        place = CGFloat(selection)
        openness = targetOpenness
        link?.invalidate()
        link = nil
        layoutCards()
    }

    func tearDown() {
        link?.invalidate()
        link = nil
    }

    override func layout() {
        super.layout()
        background.frame = bounds
        layoutCards()
    }

    /// Where a card is, by its place relative to the chosen one (`r`):
    /// below 0, still to come, hanging at the back; 0, chosen; above 0,
    /// passed over, lying flat along the bottom.
    private struct Pose {
        var top: CGFloat    // its top edge, down from the top
        var tilt: CGFloat   // how far it leans back, in degrees
        var fog: CGFloat    // how far it's faded into the background
        var alpha: CGFloat
    }

    private static let pileStep: CGFloat = 22
    private static let maxPile: CGFloat = 4
    private static let topMargin: CGFloat = 44
    private static let lean: CGFloat = 14
    /// How much of the cards passed over shows, nearest first.
    private static let shelf: [CGFloat] = [0, 58, 24, 6, -16]

    private func pose(_ r: CGFloat) -> Pose {
        let pile = min(place, Self.maxPile)
        let chosenTop = Self.topMargin + pile * Self.pileStep
        if r <= 0 {
            let slot = pile + r
            return Pose(top: Self.topMargin + slot * Self.pileStep, tilt: Self.lean,
                        fog: 0.08 + min(1, -r) * 0.4, alpha: max(0, min(1, slot + 1)))
        }
        // Passed over: down onto the shelf, flattening as it goes.
        func shelfTop(_ n: Int) -> CGFloat { bounds.height - Self.shelf[min(n, Self.shelf.count - 1)] }
        let n = Int(r.rounded(.down)), f = r - CGFloat(n)
        let from = n == 0 ? chosenTop : shelfTop(n)
        return Pose(top: from + (shelfTop(n + 1) - from) * f, tilt: n == 0 ? Self.lean * (1 - f) : 0,
                    fog: n == 0 ? 0.08 + 0.22 * f : 0.3, alpha: 1)
    }

    private func layoutCards() {
        guard contentSize.width > 0, contentSize.height > 0, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let p = openness
        background.alphaValue = p
        let width = (bounds.width * 0.84).rounded()
        let scale = width / contentSize.width
        let homeFrame = NSRect(origin: .zero, size: contentSize)
        for (i, card) in cards.enumerated() {
            let pose = pose(CGFloat(i) - place)
            let height = SwitcherCard.headerHeight + contentSize.height * scale
            var frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - pose.top - height,
                               width: width, height: height)
            var tilt = pose.tilt, fog = pose.fog, alpha = pose.alpha * p
            var chrome: CGFloat = 1
            if i == home {
                // Fills the column when closed, as it did before opening.
                let q = 1 - p
                frame = NSRect(x: frame.minX + (homeFrame.minX - frame.minX) * q,
                               y: frame.minY + (homeFrame.minY - frame.minY) * q,
                               width: frame.width + (homeFrame.width - frame.width) * q,
                               height: frame.height + (homeFrame.height - frame.height) * q)
                tilt *= p
                fog *= p
                alpha = pose.alpha + (1 - pose.alpha) * q
                chrome = p
            }
            card.chrome = chrome
            card.fog = fog
            card.alphaValue = alpha
            card.isHidden = alpha < 0.01
            card.frame = frame
            card.layoutSubtreeIfNeeded()
            card.lean(tilt)
        }
        CATransaction.commit()
    }

    // MARK: Mouse

    // The frontmost card under the mouse takes a click (the cards lean, so
    // this is approximate near their lower corners).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return cards.last { !$0.isHidden && $0.frame.contains(local) } ?? self
    }

    override func mouseDown(with event: NSEvent) {}

    override func scrollWheel(with event: NSEvent) {
        scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
        while abs(scrolled) >= 36 {
            move(scrolled > 0 ? 1 : -1)
            scrolled -= scrolled > 0 ? 36 : -36
        }
    }
}

/// Behind the cards: a wash from a shade off the paper down to a deeper,
/// still warm, one.
final class SwitcherBackground: NSView {
    private static let top = Ink.dynamic(NSColor(srgbRed: 0.925, green: 0.906, blue: 0.875, alpha: 1),
                                         NSColor(srgbRed: 0.16, green: 0.149, blue: 0.137, alpha: 1))
    private static let bottom = Ink.dynamic(NSColor(srgbRed: 0.835, green: 0.808, blue: 0.769, alpha: 1),
                                            NSColor(srgbRed: 0.098, green: 0.09, blue: 0.082, alpha: 1))

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: Self.bottom, ending: Self.top)?.draw(in: bounds, angle: 90)
    }
}

/// A sheet in the switcher: a title bar with its kind and name, then the
/// sheet as it was left, scaled to fit.
final class SwitcherCard: NSView {
    private let contentSize: NSSize
    private let holder = NSView()
    private let picture = NSImageView()
    /// For a sheet not seen since a restart, with no picture: its name, as
    /// its page would have it.
    private let placeholder = NSTextField(labelWithString: "")
    private let fogView = NSView()
    private let header = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?

    static let headerHeight: CGFloat = 24

    /// How much of the card's chrome shows: its title bar, corners, and
    /// shadow (none when filling the column).
    var chrome: CGFloat = 1 {
        didSet {
            guard chrome != oldValue else { return }
            holder.layer?.cornerRadius = 8 * chrome
            layer?.shadowOpacity = Float(0.22 * chrome)
            needsLayout = true
        }
    }
    var fog: CGFloat = 0 { didSet { fogView.alphaValue = fog } }

    init(sheet: Sheet, contentSize: NSSize, face: Typeface) {
        self.contentSize = contentSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        holder.wantsLayer = true
        holder.layer?.cornerRadius = 8
        holder.layer?.cornerCurve = .continuous
        holder.layer?.masksToBounds = true
        holder.layer?.borderWidth = 0.5
        addSubview(holder)
        picture.image = sheet.snapshot
        picture.imageScaling = .scaleAxesIndependently
        holder.addSubview(picture)
        if sheet.snapshot == nil {
            placeholder.stringValue = sheet.title
            placeholder.font = face.font(size: 26, weight: .semibold)
            placeholder.textColor = Ink.text
            placeholder.lineBreakMode = .byTruncatingTail
            holder.addSubview(placeholder)
        }
        fogView.wantsLayer = true
        fogView.alphaValue = 0
        holder.addSubview(fogView)
        header.wantsLayer = true
        holder.addSubview(header)
        let symbol = switch sheet.kind {
        case .timeline: "calendar"
        case .note: "doc.text"
        case .backlinks: "link"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .search: "magnifyingglass"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = Ink.secondary
        title.stringValue = sheet.title
        title.font = face.font(size: 11.5, weight: .semibold)
        title.textColor = Ink.text
        title.lineBreakMode = .byTruncatingTail
        header.addSubview(icon)
        header.addSubview(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Leans the card back from its top edge, in perspective. The lean is
    /// the card's transform for what's in it, not the card's own: AppKit
    /// doesn't draw a view whose own layer is turned in depth.
    func lean(_ degrees: CGFloat) {
        guard let layer else { return }
        guard degrees > 0.01 else {
            layer.sublayerTransform = CATransform3DIdentity
            return
        }
        // About the middle of the top edge, wherever AppKit put the anchor.
        let w = bounds.width, h = bounds.height
        let axis = CGPoint(x: w / 2 - layer.anchorPoint.x * w, y: h - layer.anchorPoint.y * h)
        var t = CATransform3DMakeTranslation(-axis.x, -axis.y, 0)
        t = CATransform3DConcat(t, CATransform3DMakeRotation(degrees * .pi / 180, 1, 0, 0))
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1000
        t = CATransform3DConcat(t, perspective)
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(axis.x, axis.y, 0))
        layer.sublayerTransform = t
    }

    override func layout() {
        super.layout()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            holder.layer?.backgroundColor = Ink.paper.cgColor
            holder.layer?.borderColor = Ink.rule.cgColor
            fogView.layer?.backgroundColor = Ink.dynamic(NSColor(srgbRed: 0.87, green: 0.85, blue: 0.82, alpha: 1),
                                                         NSColor(srgbRed: 0.12, green: 0.11, blue: 0.1, alpha: 1)).cgColor
            header.layer?.backgroundColor = Ink.shelf.cgColor
        }
        holder.frame = bounds
        let hh = (Self.headerHeight * chrome).rounded()
        header.frame = NSRect(x: 0, y: bounds.height - hh, width: bounds.width, height: hh)
        header.alphaValue = chrome
        let body = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - hh)
        picture.frame = body
        fogView.frame = body
        // Where its page's name would be, at the card's scale.
        let scale = bounds.width / max(contentSize.width, 1)
        placeholder.font = placeholder.font.map { NSFont(descriptor: $0.fontDescriptor, size: max(11, 30 * scale)) } ?? nil
        let ph = ceil(placeholder.intrinsicContentSize.height)
        placeholder.frame = NSRect(x: round(96 * scale), y: body.maxY - round(70 * scale) - ph, width: body.width - round(120 * scale), height: ph)
        title.sizeToFit()
        let tw = min(title.frame.width, bounds.width - 60)
        let x = ((bounds.width - 21 - tw) / 2).rounded()
        icon.frame = NSRect(x: x, y: (hh - 14) / 2, width: 16, height: 14)
        title.frame = NSRect(x: x + 21, y: ((hh - title.frame.height) / 2).rounded(), width: tw, height: title.frame.height)
    }

    // The card takes the click, not what is in it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}
