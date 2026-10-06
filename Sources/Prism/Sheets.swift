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
    /// Kept when the column goes back past it: it stays on the stack, just
    /// under where the column went back to.
    var pinned = false
    /// When it was last looked at: left, or seen again.
    var seen = Date()

    /// How long since it was looked at, from 0 (just now) to 1 (two days
    /// and more): the sheet yellows and its name fades as it ages.
    var age: CGFloat {
        let hours = Date().timeIntervalSince(seen) / 3600
        return CGFloat(min(1, max(0, (hours - 0.5) / 47.5)).squareRoot())
    }
}

/// Paper left a while: yellowed toward old newsprint, as far as `age` says.
enum Aging {
    private static let yellowed = Ink.dynamic(NSColor(srgbRed: 0.94, green: 0.87, blue: 0.66, alpha: 1),
                                              NSColor(srgbRed: 0.27, green: 0.23, blue: 0.15, alpha: 1))

    static func fill(_ base: NSColor, age: CGFloat) -> NSColor {
        guard age > 0.01 else { return base }
        return base.blended(withFraction: 0.55 * age, of: yellowed) ?? base
    }

    /// How much of a name still shows, aged.
    static func ink(_ age: CGFloat) -> CGFloat { 1 - 0.4 * age }
}

extension Column {
    /// What the column shows now, as a sheet.
    var currentSheet: Sheet {
        Sheet(kind: kind, place: place, offset: scrollOffset, title: Self.title(of: kind, top: current?.ref), snapshot: snapshot(),
              pinned: isPinned, seen: Date())
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
        case .web(let ref): name(of: ref).title
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
    /// In the title bar: a click here is its own, not the start of moving the window.
    override var mouseDownCanMoveWindow: Bool { false }
    /// A click here counts, though the window was not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
    /// In the title bar: a click here is its own, not the start of moving the window.
    override var mouseDownCanMoveWindow: Bool { false }
    /// A click here counts, though the window was not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The sheets beneath, the bottom first.
    var sheets: [Sheet] = [] { didSet { restyle() } }
    /// With none beneath, the nearest gone back from: forward, faintly.
    var forward: Sheet? { didSet { restyle() } }
    var face: Typeface = .lato { didSet { restyle() } }
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    /// Picked up and moved: the column's own sheet, to put elsewhere.
    var onDrag: ((NSEvent) -> Void)?

    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    /// The edges of the sheets further down, up to so many.
    private static let most = 3
    /// As tall as the toolbox it sits beside.
    private static let height: CGFloat = 34
    private static let step: CGFloat = 6

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
    private var isForward: Bool { sheets.isEmpty && forward != nil }

    private func restyle() {
        guard let top = sheets.last ?? forward else { return }
        icon.image = NSImage(systemSymbolName: isForward ? "arrow.forward" : StackPill.symbol(for: top.kind), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        icon.contentTintColor = Ink.secondary
        let name = NSMutableAttributedString(string: top.title, attributes: [
            .font: face.font(size: 13.5, weight: .medium),
            .foregroundColor: (isForward ? Ink.secondary : Ink.text).withAlphaComponent(Aging.ink(top.age)),
        ])
        if top.pinned, !isForward {
            let pin = NSTextAttachment()
            pin.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular).applying(.init(paletteColors: [Ink.secondary])))
            name.append(NSAttributedString(string: "  "))
            name.append(NSAttributedString(attachment: pin))
        }
        title.attributedStringValue = name
        toolTip = isForward ? "Forward to “\(top.title)”"
            : sheets.count == 1 ? "Back to “\(top.title)”" : "Back to “\(top.title)” — \(sheets.count) sheets beneath"
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
        case .web: "safari"
        }
    }

    /// As wide as its name wants, within so much.
    func fittingWidth(within most: CGFloat) -> CGFloat {
        let text = ceil(title.attributedStringValue.size().width)
        return min(most, text + 40 + CGFloat(behind) * Self.step)
    }

    static var fittingHeight: CGFloat { height }

    /// Its smallest: the icon alone, on the edges of those beneath.
    var compactWidth: CGFloat { 34 + CGFloat(behind) * Self.step }
    /// Too narrow for any of its name: the icon alone, centred.
    private var isCompact: Bool { front.width < 64 }

    /// Where the front one is: the others, level with it, peek out at its left.
    var front: NSRect {
        let inset = CGFloat(behind) * Self.step
        return NSRect(x: inset, y: 0, width: bounds.width - inset, height: Self.height)
    }

    override func layout() {
        super.layout()
        let front = front
        title.isHidden = isCompact
        icon.frame = isCompact ? NSRect(x: (front.midX - 7.5).rounded(), y: front.midY - 7, width: 15, height: 14)
            : NSRect(x: front.minX + 9, y: front.midY - 7, width: 15, height: 14)
        let titleHeight = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: front.minX + 27, y: (front.midY - titleHeight / 2).rounded(), width: front.width - 36, height: titleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let front = front
        // The furthest first, each a little left of the one before it, level
        // with it: the rightmost on top.
        for level in stride(from: behind, through: 0, by: -1) {
            let offset = CGFloat(level) * Self.step
            let rect = front.offsetBy(dx: -offset, dy: 0).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
            let base = level == 0 ? (hovering ? Ink.shelf : Ink.paper) : Ink.shelf
            Aging.fill(base, age: level == 0 ? (sheets.last ?? forward)?.age ?? 0 : 0).withAlphaComponent(isForward ? 0.6 : 1).setFill()
            path.fill()
            Ink.text.withAlphaComponent(level == 0 ? 0.14 : 0.1).setStroke()
            path.lineWidth = 1
            // The way forward, not a sheet on the stack: dashed.
            if isForward { path.setLineDash([3, 2], count: 2, phase: 0) }
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

/// The bunched sheets, hovered: dealt out across the column's top, each
/// tucked under the one to its right — the oldest at the left, furthest
/// down; the column's own at the right, on top. To scrub along, the column
/// showing each as the pointer passes over it, and to click, going back.
final class StackScrubber: NSView {
    /// In the title bar: a click here is its own, not the start of moving the window.
    override var mouseDownCanMoveWindow: Bool { false }
    /// A click here counts, though the window was not in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The sheet under the pointer, by its place (0 at the bottom; the
    /// column's own last).
    var onHover: ((Int) -> Void)?
    var onChoose: ((Int) -> Void)?
    /// A sheet picked up and moved: being dragged.
    var onDrag: ((Int, NSEvent) -> Void)?
    var onLeave: (() -> Void)?
    /// A sheet pinned or unpinned from its menu, by its place.
    var onPin: ((Int) -> Void)?

    private var sheets: [Sheet] = []
    /// Whether they are the way forward, gone back from: dashed, fainter.
    private var forward = false
    /// The one on top: pointed at, or — till one is — the nearest, at the right.
    private var top: Int { hovered ?? max(0, sheets.count - 1) }
    /// The bunch's front: they gather to it, the rightmost on top.
    private var own: Int { max(0, sheets.count - 1) }
    private var face: Typeface = .lato
    private(set) var hovered: Int?
    /// How far they are dealt out: 0 in their bunch, at the right; 1 across.
    private var dealt: CGFloat = 0
    private var target: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var onSettled: (() -> Void)?
    /// Where they gather to: the bunch's front, in its own coordinates.
    var bunch: NSRect = .zero

    override var isFlipped: Bool { true }

    /// `sheets` oldest first — the column's own not among them: the nearest
    /// at the right, where the bunch showed it — or, `forward`, the way
    /// forward, the nearest at the right too.
    func show(_ sheets: [Sheet], forward: Bool, face: Typeface) {
        self.sheets = sheets
        self.forward = forward
        self.face = face
        needsDisplay = true
    }

    // MARK: Dealing out, and gathering in

    /// Deals them out from the bunch, the nearest first.
    func deal(animated: Bool) {
        target = 1
        onSettled = nil
        guard animated else {
            dealt = 1
            needsDisplay = true
            return
        }
        start()
    }

    /// Stops partway dealt out, so far: for a script's picture.
    func freeze(at dealt: CGFloat) {
        link?.invalidate()
        link = nil
        self.dealt = dealt
        target = dealt
        needsDisplay = true
    }

    /// Gathers them back into the bunch, then calls `done`.
    func gather(done: @escaping () -> Void) {
        target = 0
        onSettled = done
        start()
    }

    private func start() {
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        dealt += (target - dealt) * CGFloat(1 - exp(-dt * (target > dealt ? 13 : 18)))
        if abs(dealt - target) < 0.003 {
            dealt = target
            link.invalidate()
            self.link = nil
            needsDisplay = true
            let done = onSettled
            onSettled = nil
            done?()
            return
        }
        needsDisplay = true
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    // MARK: Where each sheet is

    /// How far a sheet reaches under the one to its right.
    private static let tuck: CGFloat = 18
    /// The most a sheet's shown part is wide: enough for its name, to peek.
    static let widest: CGFloat = 190

    /// How wide so many sheets are, dealt out, each as wide as it may be.
    static func width(for count: Int) -> CGFloat { CGFloat(count) * widest + tuck }

    /// A sheet's place: dealt out, each one's share of the width and a
    /// tuck more, under its neighbour; gathered, all at the bunch, each
    /// further down a little up and left of the one on it. Those nearest
    /// the top leave the bunch first.
    private func place(_ i: Int) -> NSRect {
        let n = CGFloat(max(sheets.count, 1))
        let share = (bounds.width - Self.tuck) / n
        let out = NSRect(x: CGFloat(i) * share, y: 0, width: share + Self.tuck, height: bounds.height)
        let below = CGFloat(abs(own - i))
        let depth = min(below, 2) * 6
        let home = NSRect(x: bunch.minX - depth, y: bunch.minY, width: bunch.width, height: bunch.height)
        // Staggered: the further down, the later it leaves, the sooner it's back.
        let stagger: CGFloat = 0.35 * below / max(CGFloat(max(own, sheets.count - 1 - own)), 1)
        let f = max(0, min(1, (dealt - stagger) / (1 - stagger)))
        let e = f * f * (3 - 2 * f)
        return NSRect(x: home.minX + (out.minX - home.minX) * e, y: home.minY + (out.minY - home.minY) * e,
                      width: home.width + (out.width - home.width) * e, height: home.height + (out.height - home.height) * e)
    }

    /// What of a sheet shows, across: the top one whole; left of it, each
    /// up to where the next starts; right of it, each from where the one
    /// before ends — those on both sides tucked under it.
    private func shown(_ i: Int) -> ClosedRange<CGFloat> {
        let rect = place(i)
        if i < top { return rect.minX...max(rect.minX, place(i + 1).minX) }
        if i > top { return min(rect.maxX, place(i - 1).maxX)...rect.maxX }
        return rect.minX...rect.maxX
    }

    override func draw(_ dirtyRect: NSRect) {
        let named = dealt > 0.7
        // Each lies on the one further from the top one; it, on them all.
        let top = top
        let order = Array(0..<top) + Array(sheets.indices.dropFirst(top + 1).reversed()) + [top]
        for i in order where sheets.indices.contains(i) {
            let sheet = sheets[i]
            let ahead = forward
            let rect = place(i).insetBy(dx: 0.5, dy: 0.5)
            let lifted = i == hovered
            let sheetRect = lifted ? rect.offsetBy(dx: 0, dy: -1.5) : rect
            let path = NSBezierPath(roundedRect: sheetRect, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            // A soft shadow, cast toward the sheet beneath.
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(ahead ? 0.05 : i == 0 ? 0.06 : 0.12)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: i > top ? 2 : -2, height: -1)
            shadow.set()
            // Solid, each hiding what it lies on; the way forward is told by
            // its dashes and fainter names, not by being seen through.
            let aged = i == top || lifted ? 0 : sheet.age
            Aging.fill(lifted || i == top || ahead ? Ink.paper : Ink.shelf, age: aged).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            Ink.text.withAlphaComponent(lifted ? 0.22 : 0.13).setStroke()
            path.lineWidth = 1
            // The way forward, gone back from: dashed, faint.
            if ahead { path.setLineDash([3, 2], count: 2, phase: 0) }
            path.stroke()
            guard named else { continue }
            let span = shown(i)
            let fade = min(1, (dealt - 0.7) / 0.3)
            let color = (i == top || lifted ? Ink.text : Ink.secondary)
                .withAlphaComponent(fade * (ahead && !lifted ? 0.6 : 1) * Aging.ink(aged))
            var x = i > top ? span.lowerBound + 8 : sheetRect.minX + 11
            var right = i < top ? span.upperBound - 4 : sheetRect.maxX - 8
            // Pinned: a pin at its shown part's end.
            if sheet.pinned, right - x > 30,
               let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
                let size = pin.size
                pin.draw(in: NSRect(x: right - size.width, y: (sheetRect.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                         from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                right -= size.width + 5
            }
            if right - x > 40, let icon = NSImage(systemSymbolName: StackPill.symbol(for: sheet.kind), accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10.5, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) {
                let size = icon.size
                icon.draw(in: NSRect(x: x, y: (sheetRect.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += size.width + 5
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let title = NSAttributedString(string: sheet.title, attributes: [
                .font: face.font(size: 12.5, weight: i == top ? .semibold : .medium), .foregroundColor: color, .paragraphStyle: style,
            ])
            let height = ceil(title.size().height)
            title.draw(with: NSRect(x: x, y: (sheetRect.midY - height / 2).rounded(), width: max(0, right - x), height: height),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    /// The sheet showing under a point: the topmost whose shown part it is in.
    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.insetBy(dx: -2, dy: -6).contains(point), !sheets.isEmpty, dealt > 0.5 else { return nil }
        let top = top
        if place(top).minX...place(top).maxX ~= point.x { return top }
        if point.x < place(top).minX { return (0..<top).last { place($0).minX <= point.x } ?? 0 }
        return sheets.indices.dropFirst(top + 1).first { place($0).maxX >= point.x } ?? sheets.count - 1
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

    /// A sheet's own menu: pinning it, on the stack.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(at: event), !forward else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title: sheets[i].pinned ? "Unpin Sheet" : "Pin Sheet", action: #selector(pinChosen(_:)), keyEquivalent: "")
        item.target = self
        item.tag = i
        item.image = NSImage(systemSymbolName: sheets[i].pinned ? "pin.slash" : "pin", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc private func pinChosen(_ item: NSMenuItem) { onPin?(item.tag) }
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
    /// What was typed, to find a sheet by: those it fits stand clear, the
    /// others fade back. Nil, while nothing has been.
    private(set) var query: String?
    private let queryLabel = NSTextField(labelWithString: "")
    private var titles: [String] = []

    override var isFlipped: Bool { false }

    /// `sheets` bottom to top.
    init(sheets: [Sheet], contentSize: NSSize, selection: Int, face: Typeface) {
        self.contentSize = contentSize
        self.selection = selection
        // Starting from the top, so the first choice flips down into place.
        place = CGFloat(sheets.count - 1)
        home = sheets.count - 1
        cards = sheets.map { SwitcherCard(sheet: $0, contentSize: contentSize, face: face) }
        titles = sheets.map { $0.title.lowercased() }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(background)
        for (i, card) in cards.enumerated() {
            card.onClick = { [weak self] in self?.pick(i) }
            addSubview(card)
        }
        queryLabel.isHidden = true
        queryLabel.alignment = .center
        addSubview(queryLabel)
    }

    /// Whether a sheet fits what was typed.
    private func fits(_ i: Int) -> Bool {
        guard let query, !query.isEmpty else { return true }
        return titles[i].contains(query.lowercased())
    }

    /// Finds by what was typed: the nearest sheet down the stack that fits,
    /// chosen — or the choice left, when none does.
    func find(_ typed: String) {
        guard !isClosing else { return }
        query = typed
        let fitting = cards.indices.filter(fits)
        if let nearest = fitting.filter({ $0 < cards.count - 1 }).last ?? fitting.last {
            selection = nearest
        } else {
            NSSound.beep()
        }
        queryLabel.isHidden = typed.isEmpty
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        queryLabel.attributedStringValue = NSAttributedString(string: typed, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: Ink.text, .paragraphStyle: centred,
        ])
        queryLabel.wantsLayer = true
        queryLabel.drawsBackground = false
        queryLabel.layer?.cornerRadius = 12
        effectiveAppearance.performAsCurrentDrawingAppearance {
            queryLabel.layer?.backgroundColor = Ink.paper.cgColor
            queryLabel.layer?.borderColor = Ink.rule.cgColor
        }
        queryLabel.layer?.borderWidth = 1
        needsLayout = true
        startAnimating()
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

    /// Stops partway open, so far: for a script's picture of the animation.
    func freeze(at openness: CGFloat) {
        place = CGFloat(selection)
        self.openness = openness
        link?.invalidate()
        link = nil
        layoutCards()
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
        // What was typed, on a slip of paper, over the cards hanging.
        let size = queryLabel.attributedStringValue.size()
        let width = ceil(size.width) + 32, height = ceil(size.height) + 6
        queryLabel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: bounds.height - 8 - height, width: width, height: height)
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
            } else if var origin = origin {
                // Out of the bunch in the title bar, and back into it: the
                // card in small, its own shape, at the bunch's top.
                origin = NSRect(x: origin.minX, y: origin.maxY - origin.width * frame.height / max(frame.width, 1),
                                width: origin.width, height: origin.width * frame.height / max(frame.width, 1))
                let e = p * p * (3 - 2 * p)
                frame = NSRect(x: origin.minX + (frame.minX - origin.minX) * e,
                               y: origin.minY + (frame.minY - origin.minY) * e,
                               width: origin.width + (frame.width - origin.width) * e,
                               height: origin.height + (frame.height - origin.height) * e)
                tilt *= e
                alpha = pose.alpha * min(1, p * 4)
            }
            card.chrome = chrome
            // Not fitting what was typed: faded back.
            if !fits(i), i != home || p > 0.5 { fog = max(fog, 0.6) }
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
        case .web: "safari"
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

/// A column folded away: a narrow strip, its name up its length, how many
/// sheets it holds. Hovered, it shows what is in it; clicked, opens again.
final class CollapsedStrip: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var symbol = "doc.text" { didSet { needsDisplay = true } }
    var count = 1 { didSet { needsDisplay = true } }
    var face: Typeface = .lato { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true; onHover?(hovering) } } }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let width: CGFloat = 40

    override func draw(_ dirtyRect: NSRect) {
        (hovering ? Ink.shelf : Ink.paper).setFill()
        bounds.fill()
        Ink.rule.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        var top = bounds.height - 56
        if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Ink.secondary]))) {
            let size = icon.size
            icon.draw(in: NSRect(x: (bounds.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height))
            top -= size.height + 12
        }
        // Its name down its length, as a book's spine.
        let name = NSAttributedString(string: title, attributes: [
            .font: face.font(size: 12.5, weight: .semibold), .foregroundColor: Ink.text,
        ])
        let length = min(ceil(name.size().width), max(0, top - 60))
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.midX + 5, y: top)
        context.rotate(by: -.pi / 2)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let fitted = NSMutableAttributedString(attributedString: name)
        fitted.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: fitted.length))
        fitted.draw(with: NSRect(x: 0, y: -14, width: length, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        context.restoreGState()
        if count > 1 {
            let more = NSAttributedString(string: "\(count)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: Ink.secondary,
            ])
            let size = more.size()
            more.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: 24))
        }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        hovering = false
        onClick?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
