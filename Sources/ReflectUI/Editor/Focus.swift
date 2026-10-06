import AppKit
import ReflectCore

/// Focus, as Bike has it: a row and all under it shown as if it were the
/// whole note — the rest of the note set aside, as it was, until the focus
/// is left. Edits in focus are the note's: written, it is whole again,
/// the rows set aside around those on screen.
///
/// Outline ▸ Focus In (⌥⌘→), or ⌥-click a bullet; Focus Out (⌥⌘←) to the
/// row above, and on out; Unfocus, at once. The path from the note to the
/// row shows above it, each step a way back.
package struct OutlineFocus {
    /// The note's rows before the focused ones, and after, as they were.
    package var before: [Row]
    package var after: [Row]
    /// How far in the focused row is: the rows on screen are that much less deep.
    package var shift: Int
    /// The rows above the focused one, outermost first: their words, and
    /// where they are among the note's rows.
    package var ancestors: [(text: String, index: Int)]
}

extension OutlineTextView {
    /// The note's rows: those on screen, and, in focus, those set aside
    /// around them. What is written.
    package var fullRows: [Row] {
        guard let focus else { return rows }
        return focus.before + rows.map { row in
            var row = row
            row.depth += focus.shift
            return row
        } + focus.after
    }

    /// Where a row on screen is among the note's rows.
    package func fullIndex(of index: Int) -> Int { (focus?.before.count ?? 0) + index }

    // MARK: Commands

    @objc package func focusIn(_ sender: Any?) {
        let index = selectedRows?.lowerBound ?? rowIndex(at: selectedRange().location)
        // Already the focused row, alone at the top: nothing further in.
        guard focus == nil || index > 0 || rows.count > 1 else { NSSound.beep(); return }
        focusOn(fullRow: fullIndex(of: index))
    }

    @objc package func focusOut(_ sender: Any?) {
        guard let focus else { NSSound.beep(); return }
        if let parent = focus.ancestors.last {
            focusOn(fullRow: parent.index, caretOnFullRow: focus.before.count)
        } else {
            unfocus(sender)
        }
    }

    @objc package func unfocus(_ sender: Any?) {
        guard let focus else { return }
        let caret = caretPosition
        let all = fullRows
        load(all)
        restoreCaret(CaretPosition(row: focus.before.count + caret.row, offset: caret.offset))
        scrollRangeToVisible(selectedRange())
        onFocusChange?()
    }

    /// Focuses on a row of the note — by where it is among all its rows —
    /// the caret on another of them, when it is in what is shown, or else
    /// at the end of the focused row.
    package func focusOn(fullRow index: Int, caretOnFullRow caretRow: Int? = nil) {
        if selectedRows != nil { leaveRowSelection() }
        var all = fullRows
        guard index < all.count else { return }
        // A folded row is opened: what is in it is what is focused on.
        if all[index].isFolded { OutlineEditing.unfold(&all, at: index) }
        let block = OutlineEditing.block(all, index..<(index + 1))
        let shift = all[index].depth
        // Above it, the rows whose blocks hold it: list parents, and the
        // headings whose sections it is in.
        let ancestors = (0..<index).filter { OutlineEditing.block(all, $0..<($0 + 1)).contains(index) }
            .map { (text: InlineMarkup.plainText(all[$0].text), index: $0) }
        let shown = all[block].map { row -> Row in
            var row = row
            row.depth -= shift
            return row
        }
        focus = OutlineFocus(before: Array(all[..<block.lowerBound]), after: Array(all[block.upperBound...]),
                             shift: shift, ancestors: ancestors)
        load(shown, keepingFocus: true)
        if let caretRow, block.contains(caretRow) {
            restoreCaret(CaretPosition(row: caretRow - block.lowerBound, offset: 0))
        } else {
            restoreCaret(CaretPosition(row: 0, offset: (shown[0].text as NSString).length))
        }
        scrollRangeToVisible(NSRange(location: 0, length: 0))
        onFocusChange?()
    }
}

/// The path from the note to the row focused on, over it: the note, then
/// each row the focused one is in — each a click back to there.
package final class FocusBar: NSView {
    /// Told the step clicked: nil for the whole note, else a row among the note's.
    package var onStep: ((Int?) -> Void)?
    private let stack = NSStackView()

    package override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package static let height: CGFloat = 24

    package func show(note: String, ancestors: [(text: String, index: Int)], fontSize: CGFloat) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let font = NSFont.systemFont(ofSize: round(fontSize * 0.82), weight: .medium)
        func step(_ title: String, symbol: String?, index: Int?) -> NSButton {
            let button = NSButton(title: title, target: self, action: #selector(stepped(_:)))
            button.isBordered = false
            button.font = font
            button.contentTintColor = .secondaryLabelColor
            button.tag = index ?? -1
            button.lineBreakMode = .byTruncatingTail
            if let symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .semibold))
                button.imagePosition = .imageLeading
            }
            button.toolTip = index == nil ? "Unfocus: the whole note" : "Focus on “\(title)”"
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return button
        }
        func separator() -> NSTextField {
            let label = NSTextField(labelWithString: "›")
            label.font = font
            label.textColor = .tertiaryLabelColor
            return label
        }
        // Each as it reads — a link by its words, not its brackets.
        func plain(_ text: String) -> String { InlineMarkup.plainText(text).replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
        let name = plain(note)
        stack.addArrangedSubview(step(name, symbol: "chevron.left", index: nil))
        // The note's own title heading is the note, already first: not said again.
        for (i, ancestor) in ancestors.enumerated() {
            let text = plain(ancestor.text)
            guard !text.isEmpty, !(i == 0 && text.caseInsensitiveCompare(name) == .orderedSame) else { continue }
            stack.addArrangedSubview(separator())
            stack.addArrangedSubview(step(text, symbol: nil, index: ancestor.index))
        }
        needsLayout = true
    }

    package override func layout() {
        super.layout()
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }

    @objc private func stepped(_ sender: NSButton) {
        onStep?(sender.tag < 0 ? nil : sender.tag)
    }
}

extension OutlineTextView {
    /// Brings a row of the note into the editor — by its place among all
    /// the note's rows, folded ones unfolded — leaving any focus and opening
    /// the folds it is in. Returns where it now is among the rows shown.
    @discardableResult
    package func showRow(unfolded target: Int) -> Int? {
        if focus != nil { unfocus(nil) }
        // Each pass opens the fold the row is in, nearest the top first.
        for _ in 0..<64 {
            var place = 0
            var opened = false
            for (index, row) in rows.enumerated() {
                if place == target { return index }
                let inside = Row.unfold(row.folded).count
                if target > place, target <= place + inside {
                    perform("Expand", on: index..<(index + 1)) { rows, selection in
                        OutlineEditing.unfold(&rows, at: selection.lowerBound)
                        return selection
                    }
                    opened = true
                    break
                }
                place += 1 + inside
            }
            if !opened { return nil }
        }
        return nil
    }
}
