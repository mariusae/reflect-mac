import AppKit
import ReflectCore

/// A task hovered: in the margin before its checkbox, Move to… — a note
/// or a day, chosen or searched for — and ⋯, to move it among the rows
/// beside it, to the top or the bottom, or copy, cut or delete it.
///
/// Out in the margin, past the text, they are put on the page the text is
/// on, not in the text.
package final class RowButtons: NSView {
    /// The row the buttons are for.
    package fileprivate(set) var row = 0
    fileprivate let move = RowButtons.button("arrow.turn.down.right", "Move to…")
    fileprivate let more = RowButtons.button("ellipsis", "More")
    /// The pointer gone off them.
    fileprivate var onExit: (() -> Void)?
    package static let side: CGFloat = 22

    package override init(frame: NSRect) {
        super.init(frame: frame)
        for button in [more, move] { addSubview(button) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    package override var isFlipped: Bool { true }

    package var width: CGFloat { move.isHidden ? Self.side : Self.side * 2 + 2 }

    /// Move to…, ready to anchor what it shows.
    package var moveButton: NSView { move }

    package override func layout() {
        super.layout()
        let side = Self.side
        more.frame = NSRect(x: 0, y: 0, width: side, height: side)
        move.frame = NSRect(x: side + 2, y: 0, width: side, height: side)
    }

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    package override func mouseExited(with event: NSEvent) { onExit?() }

    package override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    /// Whether an event's pointer is over them, shown.
    package func contains(_ event: NSEvent) -> Bool {
        !isHidden && window === event.window && bounds.insetBy(dx: -3, dy: -3).contains(convert(event.locationInWindow, from: nil))
    }

    private static func button(_ symbol: String, _ tip: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let button = HoverButton(image: image ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        return button
    }
}

/// A button that lights as the pointer comes over it.
private final class HoverButton: NSButton {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = .tertiaryLabelColor
        layer?.backgroundColor = nil
    }
}

extension OutlineTextView {
    /// The buttons put in the margin before the hovered row, if it is a
    /// task or a checkbox — or taken away.
    package func placeRowButtons() {
        let all = rows
        let ranges = paragraphRanges
        guard isEditable, selectedRows == nil, draggedRows == nil, let index = hoveredRow, all.indices.contains(index),
              ranges.indices.contains(index), all[index].task != nil, let layout = layoutManager,
              let host = enclosingScrollView?.documentView ?? superview else {
            rowButtons?.isHidden = true
            return
        }
        let buttons = rowButtons ?? makeRowButtons()
        if buttons.superview !== host { host.addSubview(buttons) }
        buttons.row = index
        buttons.move.isHidden = onMoveRows == nil
        // Level with the checkbox, as it is drawn: about the middle of the
        // first line's small letters.
        let row = all[index]
        let font = metrics.font(for: row)
        let glyph = layout.glyphIndexForCharacter(at: ranges[index].location)
        let middle = textContainerOrigin.y + outlineLayout.baseline(ofLineAt: glyph, font: font) - font.xHeight / 2
        let handle = textContainerOrigin.x + metrics.textIndent(for: row) - metrics.indent
        let side = RowButtons.side
        var frame = host.convert(NSRect(x: handle - buttons.width, y: middle - side / 2, width: buttons.width, height: side), from: self)
        frame.origin.x = max(frame.minX, host.bounds.minX + 2)
        buttons.frame = frame.integral
        buttons.isHidden = false
        buttons.needsLayout = true
    }

    /// The pointer off the text: the buttons kept while it is over them,
    /// let go once it leaves them other than back onto the text.
    package func leaveRowButtons() {
        rowButtons?.onExit = { [weak self] in self?.rehover() }
    }

    private func makeRowButtons() -> RowButtons {
        let buttons = RowButtons(frame: .zero)
        buttons.move.target = self
        buttons.move.action = #selector(rowButtonsMove(_:))
        buttons.more.target = self
        buttons.more.action = #selector(rowButtonsMore(_:))
        rowButtons = buttons
        return buttons
    }

    @objc private func rowButtonsMove(_ sender: Any?) {
        guard let index = rowButtons?.row else { return }
        // Shown under the button, which stays until what it shows is done.
        onMoveRows?(self, index)
    }

    /// Where to show what Move to… asks, for a row: under its button, if
    /// that is showing, else under the row's first line.
    package func moveAnchor(forRow index: Int) -> (view: NSView, rect: NSRect) {
        if let buttons = rowButtons, !buttons.isHidden, buttons.row == index, !buttons.move.isHidden {
            return (buttons.move, buttons.move.bounds)
        }
        let ranges = paragraphRanges
        guard let layout = layoutManager, ranges.indices.contains(index) else { return (self, visibleRect) }
        let glyph = layout.glyphIndexForCharacter(at: ranges[index].location)
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let x = textContainerOrigin.x + metrics.textIndent(for: rows[index])
        return (self, NSRect(x: x, y: textContainerOrigin.y + line.minY, width: 24, height: line.height))
    }

    /// What the buttons showed is done: they go, unless the pointer is
    /// still on their row.
    package func settleRowButtons() { rehover() }

    @objc private func rowButtonsMore(_ sender: Any?) {
        guard let buttons = rowButtons else { return }
        let menu = rowButtonsMenu(buttons.row)
        menu.popUp(positioning: nil, at: NSPoint(x: buttons.more.frame.minX, y: buttons.more.frame.maxY + 4), in: buttons)
        rehover()
    }

    /// What ⋯ offers for a row: where among its siblings, then elsewhere.
    private func rowButtonsMenu(_ index: Int) -> NSMenu {
        let menu = NSMenu(title: "Row")
        menu.autoenablesItems = false
        let all = rows
        let one = index..<(index + 1)
        let reorder: [(String, String, (inout [Row], Range<Int>) -> Range<Int>?)] = [
            ("Move to Top", "arrow.up.to.line", { OutlineEditing.moveToTop(&$0, $1) }),
            ("Move Up", "arrow.up", { OutlineEditing.moveUp(&$0, $1) }),
            ("Move Down", "arrow.down", { OutlineEditing.moveDown(&$0, $1) }),
            ("Move to Bottom", "arrow.down.to.line", { OutlineEditing.moveToBottom(&$0, $1) }),
        ]
        if #available(macOS 14, *) { menu.addItem(.sectionHeader(title: "Reorder")) }
        for (title, symbol, transform) in reorder {
            var probe = all
            let item = ClosureMenuItem(title: title) { [weak self] in
                self?.perform(title, on: one, followingCaret: false, transform)
            }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.isEnabled = transform(&probe, one) != nil
            menu.addItem(item)
        }
        let elsewhere = dayItems(forRow: index)
        if !elsewhere.isEmpty {
            menu.addItem(.separator())
            for item in elsewhere { menu.addItem(item) }
        }
        menu.addItem(.separator())
        let copy = ClosureMenuItem(title: "Copy") { [weak self] in self?.copyRows(one) }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let cut = ClosureMenuItem(title: "Cut") { [weak self] in
            guard let self else { return }
            copyRows(one)
            perform("Cut", on: one, followingCaret: false) { rows, selection in
                let landing = OutlineEditing.delete(&rows, selection)
                return landing..<(landing + 1)
            }
        }
        cut.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)
        menu.addItem(copy)
        menu.addItem(cut)
        menu.addItem(.separator())
        let delete = ClosureMenuItem(title: "Delete") { [weak self] in
            self?.perform("Delete Row", on: one, followingCaret: false) { rows, selection in
                let landing = OutlineEditing.delete(&rows, selection)
                return landing..<(landing + 1)
            }
        }
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(delete)
        return menu
    }

    /// A row and all under it, as Markdown on the pasteboard.
    private func copyRows(_ selection: Range<Int>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(forRows: selection), forType: .string)
    }

    /// What is under the pointer now that the rows have moved under it.
    private func rehover() {
        rowButtons?.onExit = nil
        hover(at: nil)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if visibleRect.contains(point) { hover(at: point) }
    }
}
