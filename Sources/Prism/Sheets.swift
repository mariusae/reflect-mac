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
        // The sheet, without what floats over it: its bunch, its bar.
        let floating = chrome.filter { !$0.isHidden }
        floating.forEach { $0.isHidden = true }
        cacheDisplay(in: bounds, to: rep)
        floating.forEach { $0.isHidden = false }
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A grip at a column's top, shown as the pointer comes near: dragged, it
/// picks up the column's sheet, to put on another column or one of its own.
final class SheetGrip: NSView {
    /// The pointer went down here and moved: the top sheet is picked up.
    var onDrag: ((NSEvent) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        let grip = NSRect(x: bounds.midX - 20, y: bounds.midY - 2, width: 40, height: 4)
        Ink.faint.setFill()
        NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
    }

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var downAt: NSPoint?

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        downAt = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { downAt = nil }
}

/// The sheets beneath a column's own, bunched in its title bar: the one
/// going back would show, by its name, over the edges of those under it.
/// Hovered, they are listed, each shown as it was; clicked, the column goes
/// back to the nearest.
final class StackPill: NSView {
    /// The sheets beneath, the bottom first.
    var sheets: [Sheet] = [] { didSet { restyle() } }
    var face: Typeface = .mona { didSet { restyle() } }
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Picked up and moved: the column's own sheet, to put elsewhere.
    var onDrag: ((NSEvent) -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    /// The edges of the sheets further down, up to so many.
    private static let most = 3
    private static let height: CGFloat = 24
    private static let step: CGFloat = 4

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(title)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var behind: Int { min(max(sheets.count - 1, 0), Self.most - 1) }

    private func restyle() {
        guard let top = sheets.last else { return }
        icon.image = NSImage(systemSymbolName: StackPill.symbol(for: top.kind), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = Ink.secondary
        title.attributedStringValue = NSAttributedString(string: top.title, attributes: [
            .font: face.font(size: 12.5, weight: .medium), .foregroundColor: Ink.text,
        ])
        toolTip = sheets.count == 1 ? "Back to “\(top.title)”" : "Back to “\(top.title)” — \(sheets.count) sheets beneath"
        needsLayout = true
        needsDisplay = true
    }

    static func symbol(for kind: Column.Kind) -> String {
        switch kind {
        case .timeline: "calendar"
        case .note: "doc.text"
        case .backlinks: "link"
        case .inbox: "tray"
        case .tasks: "checklist"
        case .search: "magnifyingglass"
        }
    }

    /// As wide as its name wants, within so much.
    func fittingWidth(within most: CGFloat) -> CGFloat {
        let text = ceil(title.attributedStringValue.size().width)
        return min(most, text + 40 + CGFloat(behind) * Self.step)
    }

    static var fittingHeight: CGFloat { height + CGFloat(most - 1) * step }

    /// Where the front one is: the others peek out above and to its left.
    var front: NSRect {
        let inset = CGFloat(behind) * Self.step
        return NSRect(x: inset, y: inset, width: bounds.width - inset, height: Self.height)
    }

    override func layout() {
        super.layout()
        let front = front
        icon.frame = NSRect(x: front.minX + 9, y: front.midY - 7, width: 15, height: 14)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: front.minX + 27, y: (front.midY - titleHeight / 2).rounded(), width: front.width - 36, height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let front = front
        // The furthest first, each a little up and left of the one before it.
        for level in stride(from: behind, through: 0, by: -1) {
            let offset = CGFloat(level) * Self.step
            let rect = front.offsetBy(dx: -offset, dy: -offset).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            (level == 0 ? (hovering ? Ink.shelf : Ink.paper) : Ink.shelf).setFill()
            path.fill()
            Ink.text.withAlphaComponent(level == 0 ? 0.14 : 0.1).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
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

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private var downAt: NSPoint?

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        downAt = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        onClick?()
    }
}

/// The bunched sheets, hovered: spread across the column's top, one after
/// another, the oldest at the left and the column's own at the right — to
/// scrub along, the column showing each as the pointer passes over it, and
/// to click, going back to it.
final class StackScrubber: NSView {
    /// The sheet under the pointer, by its place (0 at the bottom; the
    /// column's own last).
    var onHover: ((Int) -> Void)?
    var onChoose: ((Int) -> Void)?
    /// A sheet picked up and moved: being dragged.
    var onDrag: ((Int, NSEvent) -> Void)?
    var onLeave: (() -> Void)?

    private var sheets: [Sheet] = []
    private var face: Typeface = .mona
    private(set) var hovered: Int?
    /// Whether its sheets are named: not while it spreads and gathers.
    var spread = true { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// `sheets` bottom to top, the column's own last.
    func show(_ sheets: [Sheet], face: Typeface) {
        self.sheets = sheets
        self.face = face
        hovered = nil
        needsDisplay = true
    }

    private func segment(_ i: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(sheets.count, 1))
        return NSRect(x: CGFloat(i) * width, y: 0, width: width, height: bounds.height).insetBy(dx: 2, dy: 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        Ink.paper.setFill()
        outline.fill()
        Ink.text.withAlphaComponent(0.14).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        guard spread else { return }
        let own = sheets.count - 1
        for (i, sheet) in sheets.enumerated() {
            let rect = segment(i)
            if i == hovered {
                Ink.shelf.setFill()
                NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
            }
            if i > 0, i != hovered, i - 1 != hovered {
                Ink.rule.setFill()
                NSRect(x: rect.minX - 2.5, y: rect.midY - 6, width: 1, height: 12).fill()
            }
            let color = i == own || i == hovered ? Ink.text : Ink.secondary
            var x = rect.minX + 10
            if rect.width > 48, let icon = NSImage(systemSymbolName: StackPill.symbol(for: sheet.kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
                let size = icon.size
                icon.draw(in: NSRect(x: x, y: (rect.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += size.width + 5
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: sheet.title, attributes: [
                .font: face.font(size: 12, weight: i == own ? .semibold : .medium), .foregroundColor: color, .paragraphStyle: style,
            ])
            let height = ceil(title.size().height)
            title.draw(with: NSRect(x: x, y: (rect.midY - height / 2).rounded(), width: max(0, rect.maxX - 8 - x), height: height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -6).contains(point), !sheets.isEmpty else { return nil }
        return min(sheets.count - 1, max(0, Int(point.x / (bounds.width / CGFloat(sheets.count)))))
    }

    /// Points at a sheet, as the pointer does.
    func hover(_ i: Int) {
        guard sheets.indices.contains(i), i != hovered else { return }
        hovered = i
        needsDisplay = true
        onHover?(i)
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = index(at: event) { hover(i) }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { onLeave?() }

    private var down: (index: Int, at: NSPoint)?

    override func mouseDown(with event: NSEvent) { down = index(at: event).map { ($0, event.locationInWindow) } }

    override func mouseDragged(with event: NSEvent) {
        guard let down, hypot(event.locationInWindow.x - down.at.x, event.locationInWindow.y - down.at.y) > 4 else { return }
        self.down = nil
        onDrag?(down.index, event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let down else { return }
        self.down = nil
        if index(at: event) == down.index { onChoose?(down.index) }
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
    /// Where the sheets beneath fly out from as it opens, and back into as
    /// it closes: their bunch in the title bar, in its own coordinates.
    var origin: NSRect?

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
            } else if let origin {
                // Out of the bunch in the title bar, and back into it.
                let e = p * p * (3 - 2 * p)
                frame = NSRect(x: origin.minX + (frame.minX - origin.minX) * e,
                               y: origin.minY + (frame.minY - origin.minY) * e,
                               width: origin.width + (frame.width - origin.width) * e,
                               height: origin.height + (frame.height - origin.height) * e)
                tilt *= e
                alpha = pose.alpha * min(1, p * 4)
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
