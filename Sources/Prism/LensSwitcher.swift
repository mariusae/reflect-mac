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
        glass.frame = bounds
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
