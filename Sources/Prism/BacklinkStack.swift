import AppKit
import ReflectCore
import ReflectUI

/// The notes linking to a note, bunched as cards at its card's foot, on
/// the right: the newest on top, the edges of two more behind it. Hovered,
/// they are dealt out upward — each its note's name and the words around
/// the link — as the sheets beneath a column are dealt out across its top;
/// clicked, one opens, ⌘ in the column beside.
final class BacklinkStack: NSView {
    /// A note linking here, as its card shows it.
    struct Card: Equatable {
        var path: String
        var title: String
        var snippet: String
        /// The link, as written, to find it again in its note.
        var link: String = ""
        /// Where it is among what it stands for: a sheet's place on the stack.
        var index: Int = 0
    }

    var cards: [Card] = [] { didSet { if cards != oldValue { needsDisplay = true } } }
    /// The note they link to.
    var ref: NoteRef?
    /// Grown from its right edge — left of the toolbox — not its left.
    var anchorRight = false
    /// The front card's symbol, before its words.
    var symbol = "arrow.turn.up.left" { didSet { needsDisplay = true } }
    /// What the last card, past those dealt out, says: nil, all of them linking here.
    var moreTitle: String?
    /// Dashed and faint: what it shows is the way forward, not back.
    var faint = false { didSet { needsDisplay = true } }
    /// The bunch's height: the toolbox's, beside it.
    var bunchHeight: CGFloat = 34 { didSet { if bunchHeight != oldValue { needsDisplay = true } } }
    var face: Typeface = .lato { didSet { needsDisplay = true } }
    /// The widest it may be: the card it sits on, less a margin.
    var widest: CGFloat = .greatestFiniteMagnitude { didSet { if widest != oldValue { needsDisplay = true } } }
    /// A card clicked: its note — with ⌘, in a column of its own.
    var onOpen: ((Card, _ newColumn: Bool) -> Void)?
    /// All of them, past those dealt out: the backlinks' own sheet.
    var onShowAll: (() -> Void)?
    /// Dealt out or gathered: the column lays it out again, taller or not.
    var onSpread: (() -> Void)?
    /// Never shown bunched: dealt out from a mark the column has, when the
    /// pointer is on it — `show(_:)` — and gathered back into it.
    var hidesBunch = false { didSet { if hidesBunch != oldValue { needsDisplay = true } } }
    /// While true, the pointer leaving the cards does not gather them: it is
    /// on the mark they were dealt from.
    var keepsOpen: (() -> Bool)?

    /// Dealt out, or gathered, as the column asks.
    func show(_ out: Bool) {
        guard out != (target == 1) else { return }
        if !out { hovered = nil }
        spread(out)
    }

    /// Whether the pointer is on one of its cards.
    var pointerIsOver: Bool {
        guard let window, dealt > 0.01 else { return false }
        return card(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) != nil
    }

    /// How many show, bunched or dealt out: none bunched, when it never is.
    private var shownCount: Int {
        let all = dealtCards.count
        return dealt > 0.01 ? all : hidesBunch ? 0 : min(all, 3)
    }

    override var isFlipped: Bool { true }

    /// The bunch's size, and a dealt-out card's, as wide as there is room.
    static let bunch = NSSize(width: 210, height: 30)
    static let card = NSSize(width: 280, height: 52)
    /// As wide as its name wants, within so much.
    private var bunchWidth: CGFloat {
        let words = NSAttributedString(string: frontWords, attributes: [.font: face.font(size: 13.5, weight: .medium)])
        return min(ceil(words.size().width) + 48, 300, widest - Self.peek)
    }
    private var cardWidth: CGFloat { min(Self.card.width, max(widest, 220)) }
    /// What the bunch's front says: the newest by name, and how many more.
    private var frontWords: String {
        guard let first = cards.first else { return "" }
        return cards.count == 1 ? first.title : "\(first.title)  +\(cards.count - 1)"
    }
    /// How far each card dealt out is up from the one before it.
    private static let step: CGFloat = 46
    /// The most dealt out; past them, one more to show them all.
    private static let most = 7
    static let depth: CGFloat = 5
    /// How far the bunch's cards behind show past the front's right edge.
    private static let peek: CGFloat = 2 * depth

    /// How far they are dealt out: 0 bunched, 1 spread.
    private var dealt: CGFloat = 0
    private var target: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var hovered: Int?

    /// Whether it is dealt out, or going to be: the column gives it the room.
    private(set) var isSpread = false

    /// The cards dealt out: so many, and the last the rest, when there are more.
    private var dealtCards: [Card?] {
        cards.count > Self.most ? cards.prefix(Self.most - 1).map { $0 } + [nil] : cards.map { $0 }
    }

    /// Its size, bunched or spread: spread, as tall as its cards dealt out.
    var size: NSSize {
        // Bunched, as tall as the toolbox: those behind peek out at the right.
        guard isSpread else { return NSSize(width: bunchWidth + 2 * Self.depth + Self.peek, height: bunchHeight + 2 * Self.depth) }
        return NSSize(width: cardWidth + 2 * Self.depth,
                      height: Self.card.height + CGFloat(max(dealtCards.count - 1, 0)) * Self.step + 2 * Self.depth)
    }

    // MARK: Dealing out, and gathering in

    private func spread(_ out: Bool) {
        guard out != (target == 1) else { return }
        target = out ? 1 : 0
        if out {
            isSpread = true
            onSpread?()
        }
        run()
    }

    /// Moving toward where it is to be, a frame at a time.
    private func run() {
        guard link == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTick = 0
    }

    /// Put back in a window midway: on its way again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if dealt != target { run() }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTick == 0 ? 1.0 / 60 : min(now - lastTick, 1.0 / 20)
        lastTick = now
        dealt += (target - dealt) * CGFloat(1 - exp(-dt * (target > dealt ? 13 : 18)))
        window?.invalidateCursorRects(for: self)
        if abs(dealt - target) < 0.003 {
            dealt = target
            link.invalidate()
            self.link = nil
            if target == 0 {
                isSpread = false
                onSpread?()
            }
        }
        needsDisplay = true
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    // MARK: Where each card is

    /// A card's place, between bunched — level with the toolbox, each
    /// further down a little shorter and further right, peeking out past the
    /// one before it — and dealt out, upward, the newest
    /// at the foot. Those on top leave first.
    private func place(_ i: Int, of count: Int) -> NSRect {
        // From the toolbox's side: the left edge stays, the cards grow right and up.
        let foot = bounds.maxY - Self.depth
        let below = CGFloat(min(i, 2)) * Self.depth
        let left = anchorRight ? bounds.maxX - Self.depth - Self.peek - bunchWidth : Self.depth
        let shorter = below * 0.6
        let home = NSRect(x: left + below, y: foot - bunchHeight + shorter,
                          width: bunchWidth, height: bunchHeight - 2 * shorter)
        let outLeft = anchorRight ? bounds.maxX - Self.depth - cardWidth : Self.depth
        let out = NSRect(x: outLeft, y: foot - Self.card.height - CGFloat(i) * Self.step,
                         width: cardWidth, height: Self.card.height)
        let stagger: CGFloat = 0.35 * CGFloat(i) / CGFloat(max(count - 1, 1))
        let f = max(0, min(1, (dealt - stagger) / (1 - stagger)))
        let e = f * f * (3 - 2 * f)
        return NSRect(x: home.minX + (out.minX - home.minX) * e, y: home.minY + (out.minY - home.minY) * e,
                      width: home.width + (out.width - home.width) * e, height: home.height + (out.height - home.height) * e)
    }

    private func card(at point: NSPoint) -> Int? {
        let all = dealtCards
        // The one on top first: the newest, at the foot. None, bunched and never shown so.
        guard shownCount > 0 else { return nil }
        return all.indices.first { place($0, of: all.count).contains(point) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if faint { NSGraphicsContext.current?.cgContext.setAlpha(0.6) }
        let all = dealtCards
        guard !all.isEmpty else { return }
        let named = dealt > 0.6
        // Bunched, three at most show; the newest on top, at the foot.
        let count = shownCount
        for i in stride(from: count - 1, through: 0, by: -1) {
            let rect = place(i, of: all.count).insetBy(dx: 0.5, dy: 0.5)
            let lifted = named && i == hovered
            let drawn = lifted ? rect.offsetBy(dx: -2, dy: 0) : rect
            // Bunched, a capsule, as the toolbox beside it is.
            let radius = named ? 9 : drawn.height / 2
            let path = NSBezierPath(roundedRect: drawn, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(i == 0 || named ? 0.12 : 0.06)
            shadow.shadowBlurRadius = 5
            shadow.shadowOffset = NSSize(width: 0, height: -1.5)
            shadow.set()
            (lifted ? Ink.shelf : i == 0 || named ? Ink.paper : Ink.shelf).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            Ink.text.withAlphaComponent(i == 0 || named ? 0.14 : 0.1).setStroke()
            path.lineWidth = 1
            path.stroke()
            if named {
                drawCard(all[i], in: drawn)
            } else if i == 0 {
                drawBunchFront(in: drawn)
            }
        }
    }

    /// The bunch's front: how many link here, and the newest by name.
    private func drawBunchFront(in rect: NSRect) {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [Ink.secondary])))
        icon?.draw(in: NSRect(x: rect.minX + 13, y: rect.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        let text = NSAttributedString(string: frontWords, attributes: [
            .font: face.font(size: 13.5, weight: .medium), .foregroundColor: Ink.text,
            .paragraphStyle: Self.truncating,
        ])
        let height = ceil(text.size().height)
        text.draw(with: NSRect(x: rect.minX + 31, y: (rect.midY - height / 2).rounded(), width: rect.width - 44, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A card dealt out: its note's name, and the words around the link.
    private func drawCard(_ card: Card?, in rect: NSRect) {
        let inner = rect.insetBy(dx: 12, dy: 8)
        guard let card else {
            let text = NSAttributedString(string: moreTitle ?? "All \(cards.count) linking here…", attributes: [
                .font: face.font(size: 12.5, weight: .medium), .foregroundColor: Ink.secondary,
            ])
            let height = ceil(text.size().height)
            text.draw(at: NSPoint(x: inner.minX, y: (rect.midY - height / 2).rounded()))
            return
        }
        let title = NSAttributedString(string: card.title, attributes: [
            .font: face.font(size: 13, weight: .bold), .foregroundColor: Ink.text, .paragraphStyle: Self.truncating,
        ])
        let titleHeight = ceil(title.size().height)
        title.draw(with: NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: titleHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let snippet = NSAttributedString(string: card.snippet, attributes: [
            .font: face.font(size: 12), .foregroundColor: Ink.secondary, .paragraphStyle: Self.truncating,
        ])
        let snippetHeight = ceil(snippet.size().height)
        snippet.draw(with: NSRect(x: inner.minX, y: inner.minY + titleHeight + 2, width: inner.width, height: snippetHeight),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    // MARK: The pointer

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow,
                                                               .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// A hand over the cards: the note's text under them, its I-beam, is not
    /// what a click there does.
    override func cursorUpdate(with event: NSEvent) {
        if card(at: convert(event.locationInWindow, from: nil)) != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }

    override func resetCursorRects() {
        let all = dealtCards
        for i in 0..<shownCount { addCursorRect(place(i, of: all.count), cursor: .pointingHand) }
    }

    /// Only the cards are its own: the room about them, the note's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let all = dealtCards
        return (0..<shownCount).contains { place($0, of: all.count).contains(local) } ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { if !hidesBunch { spread(true) } }

    /// Dealt out at once, the newest pointed at: for a script's picture.
    func spreadForScript() {
        target = 1
        dealt = 1
        isSpread = true
        hovered = 0
        onSpread?()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !isSpread, !hidesBunch, card(at: point) != nil { spread(true) }
        let index = card(at: point)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        if index != nil { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
        if keepsOpen?() == true { return }
        spread(false)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = card(at: point) else { return }
        guard dealt > 0.6 else { return spread(true) }
        if let card = dealtCards[index] {
            onOpen?(card, event.modifierFlags.contains(.command))
        } else {
            onShowAll?()
        }
    }
}
