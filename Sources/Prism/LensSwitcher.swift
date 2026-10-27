import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// The lenses, in a row: at the top of the list, while it is out; else on
/// a capsule of glass at the window's foot, left — so a lens is always to
/// hand. The one shown lit; the inbox's count over its mark.
final class LensSwitcher: NSView {
    var onLens: ((Lens) -> Void)?
    var lens: Lens = .daily { didSet { if lens != oldValue { buttons.forEach { $0.isChosen = $0.lens == lens } } } }
    var inboxCount = 0 { didSet { buttons.first { $0.lens == .inbox }?.badge = inboxCount } }
    /// The block on now: about Daily's mark, a ring running down.
    var now: NowPill.Now? { didSet { if now != oldValue { buttons.first { $0.lens == .daily }?.now = now } } }

    private var buttons: [LensButton] = []
    private let glass = NSGlassEffectView()
    private let row = FlippedView()
    /// On glass of its own, floating; else on the list's.
    var floats = false { didSet { glass.isHidden = !floats; needsLayout = true } }

    static let side: CGFloat = 34
    static let gap: CGFloat = 2
    static var width: CGFloat { CGFloat(Lens.allCases.count) * (side + gap) - gap }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: .zero)
        glass.isHidden = true
        addSubview(glass)
        addSubview(row)
        for lens in Lens.allCases {
            let button = LensButton(lens: lens)
            button.onClick = { [weak self] in self?.onLens?(lens) }
            row.addSubview(button)
            buttons.append(button)
        }
        buttons.forEach { $0.isChosen = $0.lens == lens }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// As wide and tall as it wants: on its glass, a margin about the row.
    var preferredSize: NSSize { floats ? NSSize(width: Self.width + 12, height: Self.side + 12) : NSSize(width: Self.width, height: Self.side) }

    override func layout() {
        super.layout()
        // A glass view hidden is drawn all the same: none, unless it floats.
        glass.isHidden = !floats
        glass.frame = floats ? bounds : .zero
        glass.cornerRadius = bounds.height / 2
        let inset: CGFloat = floats ? 6 : 0
        row.frame = bounds.insetBy(dx: inset, dy: inset)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(i) * (Self.side + Self.gap), y: 0, width: Self.side, height: Self.side)
        }
    }
}

/// A lens's mark: filled, chosen; lit, the pointer on it; a count.
private final class LensButton: NSView {
    let lens: Lens
    var onClick: (() -> Void)?
    var isChosen = false { didSet { needsDisplay = true } }
    var badge = 0 { didSet { if badge != oldValue { needsDisplay = true } } }
    var now: NowPill.Now? {
        didSet {
            guard now != oldValue else { return }
            needsDisplay = true
            toolTip = now.map { now in
                let name = InlineMarkup.plainText(now.block.title)
                return "\(lens.title) (⌘\(lens.key)) — now: \(name.isEmpty ? "New Block" : name), \(BlockerClock.countdown(now.remaining)) left"
            } ?? "\(lens.title) (⌘\(lens.key))"
        }
    }
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(lens: Lens) {
        self.lens = lens
        super.init(frame: .zero)
        toolTip = "\(lens.title) (⌘\(lens.key))"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isChosen || hovering {
            (isChosen ? Ink.text.withAlphaComponent(0.1) : Ink.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let symbol = isChosen ? lens.symbol + ".fill" : lens.symbol
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: lens.title) ?? NSImage(systemSymbolName: lens.symbol, accessibilityDescription: lens.title))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: isChosen ? .semibold : .regular))
        if let image {
            let tinted = image.tinted(isChosen ? Ink.text : Ink.secondary)
            let size = tinted.size
            tinted.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        if let now { NowRing.draw(now, in: bounds.insetBy(dx: 1.5, dy: 1.5)) }
        guard badge > 0 else { return }
        let text = NSAttributedString(string: "\(badge)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        let pill = NSRect(x: bounds.maxX - max(13, size.width + 6) + 1, y: 1, width: max(13, size.width + 6), height: 13)
        Ink.accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6.5, yRadius: 6.5).fill()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }
}

extension NSImage {
    /// The symbol in a colour of its own.
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// The block on now, about Daily's mark: how far along it is, as the now
/// line is down it on the hours — round from twelve o'clock, a bead where
/// now is; in now's red, heavier than a note's dark ring of its tasks, the
/// rest of the circle a faint red track.
@MainActor
enum NowRing {
    static func draw(_ now: NowPill.Now, in rect: NSRect, flipped: Bool = true) {
        let total = Double(max(1, now.block.duration)) * 60
        let along = max(0, min(1, 1 - now.remaining / total))
        let width: CGFloat = 2.5
        let radius = min(rect.width, rect.height) / 2 - width / 2
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
        track.lineWidth = width
        Ink.now.withAlphaComponent(0.16).setStroke()
        track.stroke()
        // From twelve o'clock, round as a clock goes, as far as it has come.
        let start: CGFloat = flipped ? -90 : 90
        let end = start + (flipped ? 1 : -1) * 360 * CGFloat(along)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: !flipped)
        arc.lineWidth = width
        arc.lineCapStyle = .round
        Ink.now.setStroke()
        arc.stroke()
        let tip = NSPoint(x: center.x + radius * cos(end * .pi / 180), y: center.y + radius * sin(end * .pi / 180))
        Ink.now.setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - 2.75, y: tip.y - 2.75, width: 5.5, height: 5.5)).fill()
    }
}
