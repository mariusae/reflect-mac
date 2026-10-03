import AppKit
import ReflectCore
import PrismCore

extension NoteFlags {
    /// Whether a note says nothing but its title — a topic, too, shown by
    /// what links to it. The window says, from what the note holds.
    @MainActor static var isEmptyTopic: (NoteEntry) -> Bool = { _ in false }

    @MainActor init(_ entry: NoteEntry?) {
        self.init(entry, isEmptyTopic: entry.map { $0.day == nil && Self.isEmptyTopic($0) } ?? false)
    }
}

/// A note's flags as small symbols, quiet but for the inbox's, each saying
/// what it is when the pointer rests on it.
final class NoteBadges: NSView {
    var flags: NoteFlags = [] {
        didSet {
            guard flags != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            updateTips()
        }
    }
    var size: CGFloat = 12 { didSet { if size != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }

    private var spacing: CGFloat { round(size * 0.55) }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(flags.shown.count)
        return NSSize(width: count == 0 ? 0 : count * size + (count - 1) * spacing, height: size + 2)
    }

    private func image(_ symbol: String, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.85, weight: .semibold).applying(.init(paletteColors: [color])))
    }

    private func slots() -> [NSRect] {
        flags.shown.indices.map { i in
            NSRect(x: bounds.maxX - CGFloat(flags.shown.count - i) * (size + spacing) + spacing, y: (bounds.height - size) / 2,
                   width: size, height: size)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        for (flag, slot) in zip(flags.shown, slots()) {
            let color: NSColor = switch flag.weight {
            case .calling: Ink.accent
            case .telling: Ink.week
            case .quiet: Ink.faint
            }
            guard let image = image(flag.symbol, color: color) else { continue }
            // Centred in its slot, as symbols differ in width.
            let fit = image.size
            image.draw(in: NSRect(x: slot.midX - fit.width / 2, y: slot.midY - fit.height / 2, width: fit.width, height: fit.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTips()
    }

    private func updateTips() {
        removeAllToolTips()
        for (flag, slot) in zip(flags.shown, slots()) { addToolTip(slot.insetBy(dx: -3, dy: -3), owner: flag.label as NSString, userData: nil) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) && !flags.isEmpty ? self : nil
    }
}
