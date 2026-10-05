import AppKit
import ReflectCore
import ReflectUI

/// The sync, in the title bar: a ring turning while it runs, then a tick
/// — or, failed, a red cross, clicked for what went wrong — for a moment.
/// What it says, whole, in its tip.
final class SyncIndicator: NSView {
    private let spinner = NSProgressIndicator()
    private let mark = NSImageView()
    private var message = ""
    private var failed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        mark.isHidden = true
        addSubview(spinner)
        addSubview(mark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, busy: Bool, failed: Bool) {
        message = text
        self.failed = failed
        toolTip = text
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        mark.isHidden = busy
        mark.image = NSImage(systemSymbolName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill", accessibilityDescription: text)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular).applying(.init(paletteColors: [failed ? .systemRed : Ink.secondary])))
    }

    var fittingWidth: CGFloat { 18 }

    override func layout() {
        super.layout()
        let side: CGFloat = 16
        spinner.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        mark.frame = spinner.frame
    }

    override func mouseDown(with event: NSEvent) {
        guard failed, let window else { return }
        let alert = NSAlert()
        alert.messageText = "The sync failed"
        alert.informativeText = message.replacingOccurrences(of: "Sync failed: ", with: "")
        alert.beginSheetModal(for: window)
    }
}

/// The notes a sync left with both sides in them, to choose between: a
/// stack, and how many, at the window's foot — clicked, a menu of them.
final class ReviewPill: NSView {
    var paths: [String] = [] {
        didSet {
            isHidden = paths.isEmpty
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    /// What a note is called, for the menu.
    var title: (String) -> String = { $0 }
    var onOpen: ((String) -> Void)?
    var font: NSFont = .systemFont(ofSize: 12, weight: .medium) { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    /// How many: the stack says what they are, and the tip, in words.
    private var text: NSAttributedString {
        NSAttributedString(string: "\(paths.count)", attributes: [.font: font, .foregroundColor: Ink.text])
    }

    var fittingWidth: CGFloat { 10 + 16 + 5 + ceil(text.size().width) + 10 }

    override var toolTip: String? {
        get { "\(paths.count) \(paths.count == 1 ? "note" : "notes") to review: written on two devices at once" }
        set {}
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (hovering ? Ink.shelf : Ink.card).setFill()
        path.fill()
        NSColor.systemOrange.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
        if let icon = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium).applying(.init(paletteColors: [.systemOrange]))) {
            let size = icon.size
            icon.draw(in: NSRect(x: 10, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let text = text
        let height = text.size().height
        text.draw(at: NSPoint(x: 31, y: ((bounds.height - height) / 2).rounded()))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: self)
    }

    /// Each note to review: opened, its two sides shown, to choose between.
    func menu() -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: "Written on two devices at once — choose what to keep", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for path in paths {
            let item = ClosureMenuItem(title: title(path)) { [weak self] in self?.onOpen?(path) }
            item.image = NSImage(systemSymbolName: GraphPaths.day(fromDailyPath: path) != nil ? "calendar" : "doc.text",
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }
        return menu
    }
}
