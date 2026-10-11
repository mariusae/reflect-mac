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
    }

    var cards: [Card] = [] { didSet { if cards != oldValue { needsDisplay = true } } }
    var face: Typeface = .lato { didSet { needsDisplay = true } }
    /// The widest it may be: the card it sits on, less a margin.
    var widest: CGFloat = .greatestFiniteMagnitude { didSet { if widest != oldValue { needsDisplay = true } } }
    /// A card clicked: its note — with ⌘, in a column of its own.
    var onOpen: ((Card, _ newColumn: Bool) -> Void)?
    /// All of them, past those dealt out: the backlinks' own sheet.
    var onShowAll: (() -> Void)?
    /// Dealt out or gathered: the column lays it out again, taller or not.
    var onSpread: (() -> Void)?

    override var isFlipped: Bool { true }

    /// The bunch's size, and a dealt-out card's, as wide as there is room.
    static let bunch = NSSize(width: 210, height: 30)
    static let card = NSSize(width: 280, height: 52)
    private var bunchWidth: CGFloat { min(Self.bunch.width, widest - 2 * Self.depth) }
    private var cardWidth: CGFloat { min(Self.card.width, widest - 2 * Self.depth) }
    /// How far each card dealt out is up from the one before it.
    private static let step: CGFloat = 46
    /// The most dealt out; past them, one more to show them all.
    private static let most = 7
    private static let depth: CGFloat = 5

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
        guard isSpread else { return NSSize(width: bunchWidth + 2 * Self.depth, height: Self.bunch.height + 2 * Self.depth) }
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

    /// A card's place, between bunched — at the foot, on the right, each
    /// further down a little up and left — and dealt out, upward, the newest
    /// at the foot. Those on top leave first.
    private func place(_ i: Int, of count: Int) -> NSRect {
        let foot = bounds.maxY - Self.depth
        let right = bounds.maxX - Self.depth
        let below = CGFloat(min(i, 2)) * Self.depth
        let home = NSRect(x: right - bunchWidth + below, y: foot - Self.bunch.height - below,
                          width: bunchWidth - 2 * below, height: Self.bunch.height)
        let out = NSRect(x: right - cardWidth, y: foot - Self.card.height - CGFloat(i) * Self.step,
                         width: cardWidth, height: Self.card.height)
        let stagger: CGFloat = 0.35 * CGFloat(i) / CGFloat(max(count - 1, 1))
        let f = max(0, min(1, (dealt - stagger) / (1 - stagger)))
        let e = f * f * (3 - 2 * f)
        return NSRect(x: home.minX + (out.minX - home.minX) * e, y: home.minY + (out.minY - home.minY) * e,
                      width: home.width + (out.width - home.width) * e, height: home.height + (out.height - home.height) * e)
    }

    private func card(at point: NSPoint) -> Int? {
        let all = dealtCards
        // The one on top first: the newest, at the foot.
        return all.indices.first { place($0, of: all.count).contains(point) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let all = dealtCards
        guard !all.isEmpty else { return }
        let named = dealt > 0.6
        // Bunched, three at most show; the newest on top, at the foot.
        let count = dealt > 0.01 ? all.count : min(all.count, 3)
        for i in stride(from: count - 1, through: 0, by: -1) {
            let rect = place(i, of: all.count).insetBy(dx: 0.5, dy: 0.5)
            let lifted = named && i == hovered
            let drawn = lifted ? rect.offsetBy(dx: -2, dy: 0) : rect
            let path = NSBezierPath(roundedRect: drawn, xRadius: 9, yRadius: 9)
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
        let icon = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [Ink.secondary])))
        icon?.draw(in: NSRect(x: rect.minX + 10, y: rect.midY - 6, width: 12, height: 12), from: .zero, operation: .sourceOver,
                   fraction: 1, respectFlipped: true, hints: nil)
        let words = cards.count == 1 ? cards[0].title : "\(cards[0].title)  +\(cards.count - 1)"
        let text = NSAttributedString(string: words, attributes: [
            .font: face.font(size: 12.5, weight: .medium), .foregroundColor: Ink.text,
            .paragraphStyle: Self.truncating,
        ])
        let height = ceil(text.size().height)
        text.draw(with: NSRect(x: rect.minX + 28, y: (rect.midY - height / 2).rounded(), width: rect.width - 38, height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A card dealt out: its note's name, and the words around the link.
    private func drawCard(_ card: Card?, in rect: NSRect) {
        let inner = rect.insetBy(dx: 12, dy: 8)
        guard let card else {
            let text = NSAttributedString(string: "All \(cards.count) linking here…", attributes: [
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    /// Only the cards are its own: the room about them, the note's.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let all = dealtCards
        let count = dealt > 0.01 ? all.count : min(all.count, 3)
        return (0..<count).contains { place($0, of: all.count).contains(local) } ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { spread(true) }

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
        if !isSpread, card(at: point) != nil { spread(true) }
        let index = card(at: point)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        spread(false)
        NSCursor.arrow.set()
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
