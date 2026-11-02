import AppKit
import ReflectCore
import ReflectUI

/// Under a note, before what links to it: the notes related to it without
/// a link in its text — its frontmatter `related:`, and the notes naming it
/// in theirs — a pill each, opened with a click, ⌘-click beside; unrelated
/// from its menu; + relates another, chosen as ⌘K chooses.
final class RelatedBlock: NSView, ColumnBlock {
    private let label: ColumnLabel
    private let metrics: OutlineMetrics
    private(set) var related: [RelatedNote]
    private var pills: [NSButton] = []
    private let add = NSButton()
    var onOpen: ((RelatedNote, _ beside: Bool) -> Void)?
    var onUnrelate: ((RelatedNote) -> Void)?
    var onAdd: ((NSView) -> Void)?

    override var isFlipped: Bool { true }

    init(_ related: [RelatedNote], metrics: OutlineMetrics) {
        self.related = related
        self.metrics = metrics
        label = ColumnLabel("Related", metrics: metrics)
        super.init(frame: .zero)
        label.count = related.count
        addSubview(label)
        for (index, note) in related.enumerated() {
            let pill = RelatedPill(note.name, symbol: note.isOwn ? "link" : "arrow.turn.down.left", missing: note.path == nil, metrics: metrics)
            pill.target = self
            pill.action = #selector(open(_:))
            pill.tag = index
            pill.toolTip = note.path == nil ? "No note is called “\(note.name)” yet"
                : note.isOwn ? "Related here — ⌘-click opens it beside" : "“\(note.name)” relates itself to this — ⌘-click opens it beside"
            let menu = NSMenu()
            let unrelate = NSMenuItem(title: "Unrelate", action: #selector(unrelate(_:)), keyEquivalent: "")
            unrelate.target = self
            unrelate.tag = index
            menu.addItem(unrelate)
            pill.menu = menu
            addSubview(pill)
            pills.append(pill)
        }
        add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Relate to Another Note")?
            .withSymbolConfiguration(.init(pointSize: round(metrics.fontSize * 0.75), weight: .semibold))
        add.imagePosition = .imageOnly
        add.contentTintColor = Ink.secondary
        add.target = self
        add.action = #selector(addClicked)
        add.toolTip = "Relate to Another Note… (⌃⌘L)"
        addSubview(add)
        setAccessibilityLabel("Related to \(related.count) \(related.count == 1 ? "note" : "notes")")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func open(_ sender: NSButton) {
        guard related.indices.contains(sender.tag) else { return }
        onOpen?(related[sender.tag], NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    @objc private func unrelate(_ sender: NSMenuItem) {
        guard related.indices.contains(sender.tag) else { return }
        onUnrelate?(related[sender.tag])
    }

    @objc private func addClicked() { onAdd?(add) }

    // MARK: Laying out

    private var top: CGFloat { round(metrics.fontSize * 1.6) }
    private let gap: CGFloat = 6

    /// Where the column's words start, and how wide it is.
    private func column(_ width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let column = min(metrics.columnWidth, width - 48)
        let x = ((width - column) / 2).rounded() + metrics.indent - 2
        return (x, column - metrics.indent)
    }

    /// Each pill's frame, and + last, wrapping as words do.
    private func frames(width: CGFloat) -> [NSRect] {
        let (x0, room) = column(width)
        var x = x0
        var y = top + label.intrinsicContentSize.height + 8
        var frames: [NSRect] = []
        let height = RelatedPill.height(metrics)
        for button in pills + [add] {
            let size = NSSize(width: min(button === add ? height : button.fittingSize.width, room), height: height)
            if x > x0, x + size.width > x0 + room {
                x = x0
                y += height + gap
            }
            frames.append(NSRect(origin: NSPoint(x: x, y: y), size: size))
            x += size.width + gap
        }
        return frames
    }

    func desiredHeight(width: CGFloat) -> CGFloat { (frames(width: width).last?.maxY ?? top) + 4 }

    override func layout() {
        super.layout()
        let (x, room) = column(bounds.width)
        label.frame = NSRect(x: x, y: top, width: room, height: label.intrinsicContentSize.height)
        for (button, frame) in zip(pills + [add], frames(width: bounds.width)) { button.frame = frame }
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] {
        [ScrubMark(y: top, title: "Related", detail: nil, rank: 2)]
    }
}

/// A related note's pill: its name in the note's own type, on a capsule of
/// the rule's shade — slanted and fainter when no note has the name yet.
final class RelatedPill: NSButton {
    private let metrics: OutlineMetrics

    static func height(_ metrics: OutlineMetrics) -> CGFloat { round(metrics.fontSize * 1.7) }

    init(_ name: String, symbol: String, missing: Bool, metrics: OutlineMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        let size = round(metrics.fontSize * 0.88)
        var font = Typography.font(metrics.typography.bodyFamily, face: metrics.typography.bodyFace, size: size)
        if missing { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let ink: NSColor = missing ? Ink.secondary : Ink.text
        attributedTitle = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: ink])
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: round(size * 0.78), weight: .semibold))
        imagePosition = .imageLeading
        imageHugsTitle = true
        contentTintColor = Ink.secondary
        lineBreakMode = .byTruncatingTail
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let inner = super.fittingSize
        return NSSize(width: ceil(inner.width) + 20, height: Self.height(metrics))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        layer?.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Ink.rule.cgColor }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
