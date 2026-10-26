import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// Down the window's left, under its buttons: the lenses, the one chosen
/// lit, the inbox's count; at the foot, the block it is now, notes to
/// review, and the sync.
final class Rail: NSView {
    static let width: CGFloat = 68
    var onLens: ((Lens) -> Void)?
    var onNow: (() -> Void)?
    var onReview: ((NSView) -> Void)?
    var onSync: (() -> Void)?
    var onNewNote: (() -> Void)?

    var lens: Lens = .daily { didSet { if lens != oldValue { buttons.forEach { $0.isChosen = $0.lens == lens } } } }
    var listShown = true { didSet { buttons.forEach { $0.isChosen = $0.lens == lens && listShown } } }
    var inboxCount = 0 { didSet { buttons.first { $0.lens == .inbox }?.badge = inboxCount } }
    var now: NowPill.Now? { didSet { if now != oldValue { nowRing.now = now; needsLayout = true } } }
    var toReview: [String] = [] { didSet { review.isHidden = toReview.isEmpty; needsLayout = true } }

    private var buttons: [RailButton] = []
    private let nowRing = NowRing()
    private let review = CloseButton(symbol: "exclamationmark.triangle", pointSize: 14, toolTip: "Notes to Review")
    private let sync = CloseButton(symbol: "arrow.triangle.2.circlepath", pointSize: 13, toolTip: "Sync Now (⌘R)")
    private let compose = CloseButton(symbol: "square.and.pencil", pointSize: 14, toolTip: "New Note (⌥⌘N)")

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        for lens in Lens.allCases {
            let button = RailButton(lens: lens)
            button.onClick = { [weak self] in self?.onLens?(lens) }
            addSubview(button)
            buttons.append(button)
        }
        buttons.forEach { $0.isChosen = $0.lens == lens }
        nowRing.onClick = { [weak self] in self?.onNow?() }
        addSubview(nowRing)
        for (button, action) in [(review, #selector(reviewClicked)), (sync, #selector(syncClicked)), (compose, #selector(composeClicked))] {
            button.contentTintColor = Ink.secondary
            button.target = self
            button.action = action
            addSubview(button)
        }
        review.contentTintColor = .systemOrange
        review.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reviewClicked() { onReview?(review) }
    @objc private func syncClicked() { onSync?() }
    @objc private func composeClicked() { onNewNote?() }

    /// What the sync is doing: turning, failed, or still.
    func showSync(_ status: SyncController.Status) {
        switch status {
        case .syncing:
            sync.contentTintColor = Ink.accent
            sync.toolTip = "Syncing…"
        case .failed(let message):
            sync.contentTintColor = .systemRed
            sync.toolTip = "Sync failed: " + message
        case .unavailable:
            sync.contentTintColor = Ink.faint
            sync.toolTip = "Not in a git repository"
        default:
            sync.contentTintColor = Ink.secondary
            sync.toolTip = "Synced — Sync Now (⌘R)"
        }
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 56
        for button in buttons {
            button.frame = NSRect(x: (bounds.width - 44) / 2, y: y, width: 44, height: 44)
            y += 50
        }
        var bottom = bounds.height - 14
        for button in [sync, review] where !button.isHidden {
            button.frame = NSRect(x: (bounds.width - 30) / 2, y: bottom - 30, width: 30, height: 30)
            bottom = button.frame.minY - 6
        }
        compose.frame = NSRect(x: (bounds.width - 30) / 2, y: y + 6, width: 30, height: 30)
        nowRing.isHidden = now == nil
        nowRing.frame = NSRect(x: (bounds.width - 44) / 2, y: bottom - 52, width: 44, height: 52)
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.page.setFill()
        bounds.fill()
        Ink.rule.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// A lens, in the rail: its symbol — filled, chosen — and a count.
private final class RailButton: NSView {
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
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 10, yRadius: 10).fill()
        }
        let symbol = isChosen ? lens.symbol + ".fill" : lens.symbol
        let image = (NSImage(systemSymbolName: symbol, accessibilityDescription: lens.title) ?? NSImage(systemSymbolName: lens.symbol, accessibilityDescription: lens.title))?
            .withSymbolConfiguration(.init(pointSize: 17, weight: isChosen ? .semibold : .regular))
        if let image {
            let tinted = image.tinted(isChosen ? Ink.text : Ink.secondary)
            let size = tinted.size
            tinted.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        }
        guard badge > 0 else { return }
        let text = NSAttributedString(string: "\(badge)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.white])
        let size = text.size()
        let pill = NSRect(x: bounds.maxX - size.width - 12, y: 5, width: max(15, size.width + 8), height: 15)
        Ink.accent.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 7.5, yRadius: 7.5).fill()
        text.draw(at: NSPoint(x: pill.midX - size.width / 2, y: pill.midY - size.height / 2))
    }
}

/// The block it is now, in the rail: a ring of how far along, in its
/// colour, the minutes left under it. Clicked: today's hours.
private final class NowRing: NSView {
    var now: NowPill.Now? { didSet { if now != oldValue { needsDisplay = true; toolTip = tip } } }
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }

    private var tip: String? {
        guard let now else { return nil }
        let name = InlineMarkup.plainText(now.block.title)
        return (name.isEmpty ? "New Block" : name) + " — " + BlockerClock.countdown(now.remaining) + " left"
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let now else { return }
        let color = WeekGrid.color(for: now.block)
        let ring = NSRect(x: (bounds.width - 30) / 2, y: 2, width: 30, height: 30)
        let track = NSBezierPath(ovalIn: ring)
        track.lineWidth = 3
        Ink.rule.setStroke()
        track.stroke()
        let total = Double(max(1, now.block.duration)) * 60
        let done = max(0, min(1, 1 - now.remaining / total))
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: 15, startAngle: -90, endAngle: -90 + 360 * done, clockwise: false)
        arc.lineWidth = 3
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
        let minutes = Int((now.remaining / 60).rounded(.up))
        let text = NSAttributedString(string: minutes >= 60 ? "\(minutes / 60)h\(minutes % 60 == 0 ? "" : "\(minutes % 60)")" : "\(minutes)m",
                                      attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: Ink.secondary])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: ring.maxY + 4))
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
