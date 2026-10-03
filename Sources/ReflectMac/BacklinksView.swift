import AppKit
import ReflectCore
import ReflectUI

/// The backlinks of a topic note, under it: each note linking here, and
/// around each link the block of the note it sits in — as the sidebar shows
/// them, but at the note's own size, and whole.
final class BacklinksView: NSView {
    /// Told to open a note, at a link when there is one; with ⌘, beside.
    var onOpen: ((_ path: String, _ link: String?, _ inSplit: Bool) -> Void)?

    private let stack = NSStackView()
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows what links here: the sources, newest first, and their contexts.
    func show(_ sources: [BacklinkSource], titles: (String) -> String, fontSize: CGFloat) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        let heading = NSTextField(labelWithString: sources.isEmpty ? "No notes link here yet"
                                  : "Linked from \(sources.count) \(sources.count == 1 ? "note" : "notes")")
        heading.font = .systemFont(ofSize: round(fontSize * 0.8), weight: .semibold)
        heading.textColor = .secondaryLabelColor
        stack.addArrangedSubview(heading)
        stack.setCustomSpacing(12, after: heading)

        for source in sources {
            let isDay = GraphPaths.day(fromDailyPath: source.path) != nil
            let title = ClickableLabel(labelWithString: titles(source.path))
            title.font = .systemFont(ofSize: round(fontSize * 0.95), weight: .semibold)
            title.textColor = .labelColor
            title.image(named: isDay ? "calendar" : "doc.text")
            title.onClick = { [weak self] command in self?.onOpen?(source.path, nil, command) }
            stack.addArrangedSubview(title)
            stack.setCustomSpacing(4, after: title)
            for context in source.contexts {
                let text = ClickableLabel(wrappingLabelWithString: "")
                text.attributedStringValue = BacklinkText.attributed(context, size: round(fontSize * 0.9), rowLimit: 40)
                text.onClick = { [weak self] command in self?.onOpen?(source.path, context.link, command) }
                stack.addArrangedSubview(text)
                text.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18).isActive = true
                text.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor).isActive = true
                stack.setCustomSpacing(8, after: text)
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(18, after: last) }
        }
        needsLayout = true
    }

    /// How tall it is at a width.
    func height(forWidth width: CGFloat) -> CGFloat {
        for case let label as NSTextField in stack.arrangedSubviews { label.preferredMaxLayoutWidth = max(0, width - 18) }
        frame.size.width = width
        layoutSubtreeIfNeeded()
        return ceil(stack.fittingSize.height) + 24
    }
}

/// A label that is also a link: the pointing hand over it, and a click —
/// with ⌘ or not — told.
private final class ClickableLabel: NSTextField {
    var onClick: ((_ command: Bool) -> Void)?

    func image(named symbol: String) {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: (font?.pointSize ?? 13) * 0.9, weight: .regular)
                .applying(.init(hierarchicalColor: .secondaryLabelColor)))
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: "  " + stringValue, attributes: [.font: font ?? .systemFont(ofSize: 13),
                                                                                 .foregroundColor: textColor ?? .labelColor]))
        attributedStringValue = text
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags.contains(.command))
    }
}
