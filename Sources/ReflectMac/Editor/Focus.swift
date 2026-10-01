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
struct OutlineFocus {
    /// The note's rows before the focused ones, and after, as they were.
    var before: [Row]
    var after: [Row]
    /// How far in the focused row is: the rows on screen are that much less deep.
    var shift: Int
    /// The rows above the focused one, outermost first: their words, and
    /// where they are among the note's rows.
    var ancestors: [(text: String, index: Int)]
}

extension OutlineTextView {
    /// The note's rows: those on screen, and, in focus, those set aside
    /// around them. What is written.
    var fullRows: [Row] {
        guard let focus else { return rows }
        return focus.before + rows.map { row in
            var row = row
            row.depth += focus.shift
            return row
        } + focus.after
    }

    /// Where a row on screen is among the note's rows.
    func fullIndex(of index: Int) -> Int { (focus?.before.count ?? 0) + index }

    // MARK: Commands

    @objc func focusIn(_ sender: Any?) {
        let index = selectedRows?.lowerBound ?? rowIndex(at: selectedRange().location)
        // Already the focused row, alone at the top: nothing further in.
        guard focus == nil || index > 0 || rows.count > 1 else { NSSound.beep(); return }
        focusOn(fullRow: fullIndex(of: index))
    }

    @objc func focusOut(_ sender: Any?) {
        guard let focus else { NSSound.beep(); return }
        if let parent = focus.ancestors.last {
            focusOn(fullRow: parent.index, caretOnFullRow: focus.before.count)
        } else {
            unfocus(sender)
        }
    }

    @objc func unfocus(_ sender: Any?) {
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
    func focusOn(fullRow index: Int, caretOnFullRow caretRow: Int? = nil) {
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
final class FocusBar: NSView {
    /// Told the step clicked: nil for the whole note, else a row among the note's.
    var onStep: ((Int?) -> Void)?
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let height: CGFloat = 24

    func show(note: String, ancestors: [(text: String, index: Int)], fontSize: CGFloat) {
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
        stack.addArrangedSubview(step(note, symbol: "chevron.left", index: nil))
        // The note's own title heading is the note, already first.
        for ancestor in ancestors where !(ancestor.index == 0 && ancestor.text == note) && !ancestor.text.isEmpty {
            stack.addArrangedSubview(separator())
            stack.addArrangedSubview(step(ancestor.text, symbol: nil, index: ancestor.index))
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
    }

    @objc private func stepped(_ sender: NSButton) {
        onStep?(sender.tag < 0 ? nil : sender.tag)
    }
}
