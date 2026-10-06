import AppKit
import ReflectCore

/// The two sides of a conflict wear these colours throughout — in the
/// blocks, and on the buttons that keep them — so what you see is what the
/// button keeps: this device in the accent colour, the other in grey.
package enum ConflictTone {
    case ours, theirs

    package var dot: NSColor { self == .ours ? .controlAccentColor : .systemGray }
    package var header: NSColor { self == .ours ? .controlAccentColor : .secondaryLabelColor }
    package var ground: NSColor {
        self == .ours ? NSColor.controlAccentColor.withAlphaComponent(0.08) : NSColor.quaternaryLabelColor.withAlphaComponent(0.1)
    }

    /// A dot, or a pair of them, to set beside a label.
    package static func dots(_ tones: [ConflictTone], size: CGFloat = 8) -> NSImage {
        let width = size + CGFloat(tones.count - 1) * (size - 2)
        return NSImage(size: NSSize(width: width, height: size), flipped: false) { _ in
            for (index, tone) in tones.enumerated().reversed() {
                let rect = NSRect(x: CGFloat(index) * (size - 2), y: 0, width: size, height: size)
                if tones.count > 1 {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
                }
                tone.dot.setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            return true
        }
    }
}

/// A wrapping label and the height it takes at a width.
private func label(_ text: String, font: NSFont, color: NSColor = .labelColor, selectable: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = font
    field.textColor = color
    field.isSelectable = selectable
    return field
}

private func fieldHeight(_ field: NSTextField, width: CGFloat) -> CGFloat {
    ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0)
}

/// A rounded, tinted notice with a message and buttons, in the manner of
/// Reflect's inline alerts.
package class NoticeView: NSView {
    private let icon: NSImageView?
    private let messages: [NSTextField]
    private let warning: Bool
    /// The notice's buttons; set once they can target what they act on.
    package var buttons: [NSButton] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            buttons.forEach(addSubview)
            needsLayout = true
        }
    }
    private static let padding: CGFloat = 12

    package override var isFlipped: Bool { true }

    package init(symbol: String?, messages: [NSTextField], warning: Bool) {
        icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.map { NSImageView(image: $0) }
        self.messages = messages
        self.warning = warning
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        if let icon {
            icon.contentTintColor = warning ? .systemOrange : .secondaryLabelColor
            addSubview(icon)
        }
        messages.forEach(addSubview)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func updateLayer() {
        let tint = warning ? NSColor.systemYellow : NSColor.systemGray
        layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
        layer?.borderColor = tint.withAlphaComponent(0.4).cgColor
    }

    package override var wantsUpdateLayer: Bool { true }

    private var textInset: CGFloat { icon == nil ? Self.padding : Self.padding + 22 }

    /// The height the notice takes at a width, its buttons wrapping onto
    /// more rows when they do not fit on one.
    package func height(forWidth width: CGFloat) -> CGFloat {
        layoutContent(width: width, apply: false)
    }

    package override func layout() {
        super.layout()
        _ = layoutContent(width: bounds.width, apply: true)
    }

    private func layoutContent(width: CGFloat, apply: Bool) -> CGFloat {
        let textWidth = max(40, width - textInset - Self.padding)
        var y = Self.padding
        if apply, let icon { icon.frame = NSRect(x: Self.padding, y: y + 1, width: 16, height: 16) }
        for message in messages {
            let height = fieldHeight(message, width: textWidth)
            if apply { message.frame = NSRect(x: textInset, y: y, width: textWidth, height: height) }
            y += height + 2
        }
        y += 8
        var x = textInset
        var rowHeight: CGFloat = 0
        for button in buttons {
            let size = button.fittingSize
            if x > textInset && x + size.width > width - Self.padding {
                x = textInset
                y += rowHeight + 6
            }
            if apply { button.frame = NSRect(x: x, y: y, width: size.width, height: size.height) }
            x += size.width + 8
            rowHeight = max(rowHeight, size.height)
        }
        return ceil(y + rowHeight + Self.padding)
    }

    package static func button(_ title: String, image: NSImage?, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .push
        button.controlSize = .regular
        if let image {
            button.image = image
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        return button
    }
}

/// A note carrying a sync conflict: Reflect's notice, and then the note as
/// it is on disk, each conflict shown as its two sides, labelled and
/// coloured by device, instead of raw marker lines. It is read only;
/// the notice's buttons settle it.
package final class SyncConflictView: NSView {
    private let notice: NoticeView
    private var parts: [NSView] = []
    private let resolve: (ConflictMarkers.Resolution) -> Void
    private static let spacing: CGFloat = 12

    package override var isFlipped: Bool { true }

    package init(source: String, fontSize: CGFloat, resolve: @escaping (ConflictMarkers.Resolution) -> Void) {
        self.resolve = resolve
        let labels = ConflictMarkers.labels(source)
        let manySided = ConflictMarkers.blockCount(source) > 1
        // Git's generic labels read best as they are; a device's own name
        // says which it keeps.
        let named = labels.map { $0.ours != ConflictMarkers.ourLabel } ?? false
        let small = NSFont.systemFont(ofSize: round(fontSize * 0.87))
        let messages = [
            label("This note was edited on two devices at once.", font: .systemFont(ofSize: small.pointSize, weight: .semibold)),
            label("Both versions are highlighted below. Choose what to keep — every version stays recoverable in the backup history.",
                  font: small),
        ]
        notice = NoticeView(symbol: "arrow.triangle.merge", messages: messages, warning: true)
        super.init(frame: .zero)
        notice.buttons = [
            NoticeView.button(named ? "Keep “\(labels!.ours)”" : "Keep This Device’s Version",
                              image: ConflictTone.dots([.ours]), target: self, action: #selector(keepOurs(_:))),
            NoticeView.button(manySided ? "Keep the Other Versions" : named ? "Keep “\(labels!.theirs)”" : "Keep the Other Device’s",
                              image: ConflictTone.dots([.theirs]), target: self, action: #selector(keepTheirs(_:))),
            NoticeView.button(manySided ? "Keep All" : "Keep Both",
                              image: ConflictTone.dots([.ours, .theirs]), target: self, action: #selector(keepBoth(_:))),
        ]
        addSubview(notice)

        let body = NSFont.systemFont(ofSize: fontSize)
        for segment in ConflictMarkers.segments(source) {
            switch segment {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { continue }
                parts.append(label(trimmed, font: body, selectable: true))
            case .conflict(let ours, let theirs):
                parts.append(ConflictBlockView(ours: ours, theirs: theirs, font: body))
            }
        }
        parts.forEach(addSubview)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    @objc private func keepOurs(_ sender: Any?) { resolve(.ours) }
    @objc private func keepTheirs(_ sender: Any?) { resolve(.theirs) }
    @objc private func keepBoth(_ sender: Any?) { resolve(.both) }

    package func height(forWidth width: CGFloat) -> CGFloat {
        layoutContent(width: width, apply: false)
    }

    package override func layout() {
        super.layout()
        _ = layoutContent(width: bounds.width, apply: true)
    }

    private func layoutContent(width: CGFloat, apply: Bool) -> CGFloat {
        var y: CGFloat = 0
        let noticeHeight = notice.height(forWidth: width)
        if apply { notice.frame = NSRect(x: 0, y: y, width: width, height: noticeHeight) }
        y += noticeHeight + Self.spacing
        for part in parts {
            let height: CGFloat
            if let block = part as? ConflictBlockView {
                height = block.height(forWidth: width)
            } else if let field = part as? NSTextField {
                height = fieldHeight(field, width: width)
            } else {
                height = 0
            }
            if apply { part.frame = NSRect(x: 0, y: y, width: width, height: height) }
            y += height + Self.spacing
        }
        return ceil(y - Self.spacing)
    }

}

/// One conflict: this device's side over the other device's, in a card.
private final class ConflictBlockView: NSView {
    private let sides: [(tone: ConflictTone, header: NSTextField, dot: NSImageView, body: NSTextField)]
    private static let padding: CGFloat = 10

    override var isFlipped: Bool { true }

    init(ours: ConflictMarkers.Side, theirs: ConflictMarkers.Side, font: NSFont) {
        let headerFont = NSFont.systemFont(ofSize: round(font.pointSize * 0.8), weight: .medium)
        sides = [(ConflictTone.ours, ours), (ConflictTone.theirs, theirs)].map { tone, side in
            let header = label(side.label, font: headerFont, color: tone.header)
            let dot = NSImageView(image: ConflictTone.dots([tone]))
            let body = side.text.isEmpty
                ? label("Empty on this side", font: NSFont.systemFont(ofSize: headerFont.pointSize).adding(.italic), color: .tertiaryLabelColor)
                : label(side.text, font: font, selectable: true)
            return (tone, header, dot, body)
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        for side in sides {
            addSubview(side.dot)
            addSubview(side.header)
            addSubview(side.body)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.borderColor = NSColor.separatorColor.cgColor }

    private var sideFrames: [NSRect] = []

    func height(forWidth width: CGFloat) -> CGFloat { layoutContent(width: width, apply: false) }

    override func layout() {
        super.layout()
        _ = layoutContent(width: bounds.width, apply: true)
        needsDisplay = true
    }

    private func layoutContent(width: CGFloat, apply: Bool) -> CGFloat {
        let inner = max(40, width - 2 * Self.padding)
        var y: CGFloat = 0
        var frames: [NSRect] = []
        for side in sides {
            let top = y
            y += Self.padding
            let headerHeight = fieldHeight(side.header, width: inner - 14)
            if apply {
                side.dot.frame = NSRect(x: Self.padding, y: y + (headerHeight - 8) / 2, width: 8, height: 8)
                side.header.frame = NSRect(x: Self.padding + 14, y: y, width: inner - 14, height: headerHeight)
            }
            y += headerHeight + 4
            let bodyHeight = fieldHeight(side.body, width: inner)
            if apply { side.body.frame = NSRect(x: Self.padding, y: y, width: inner, height: bodyHeight) }
            y += bodyHeight + Self.padding
            frames.append(NSRect(x: 0, y: top, width: width, height: y - top))
        }
        if apply { sideFrames = frames }
        return ceil(y)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (side, frame) in zip(sides, sideFrames) {
            side.tone.ground.setFill()
            frame.fill()
        }
        if sideFrames.count == 2 {
            NSColor.separatorColor.setFill()
            NSRect(x: 0, y: sideFrames[1].minY, width: bounds.width, height: 1).fill()
        }
    }
}
