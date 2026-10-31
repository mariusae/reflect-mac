import UIKit
import ReflectCore

/// Rows chosen together, on the phone: Select Rows in a row's menu, then
/// each row tapped in or out — tinted while chosen — and, on glass at the
/// foot, what is done to them all: done, out, in, moved, deleted. ✕, or
/// a change made, and the choosing is over.
extension OutlineEditor {
    final class RowChoice {
        var rows: Set<Int>
        let tints = UIView()
        let bar = UIVisualEffectView(effect: UIGlassEffect())
        init(rows: Set<Int>) { self.rows = rows }
    }

    var isChoosingRows: Bool { rowChoice != nil }

    /// Choosing begun, with a row chosen.
    func beginChoosingRows(with index: Int) {
        guard rowChoice == nil, rows.indices.contains(index) else { return }
        if isFirstResponder { _ = resignFirstResponder() }
        let choice = RowChoice(rows: [index])
        choice.tints.isUserInteractionEnabled = false
        insertSubview(choice.tints, at: 0)
        rowChoice = choice
        showChoiceBar(choice)
        showChosen()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A row tapped while choosing: in, or out.
    func toggleChosen(_ index: Int) {
        guard let choice = rowChoice else { return }
        if choice.rows.contains(index) { choice.rows.remove(index) } else { choice.rows.insert(index) }
        UISelectionFeedbackGenerator().selectionChanged()
        if choice.rows.isEmpty { return endChoosingRows() }
        showChosen()
    }

    func endChoosingRows() {
        guard let choice = rowChoice else { return }
        rowChoice = nil
        choice.tints.removeFromSuperview()
        UIView.animate(withDuration: 0.2) { choice.bar.alpha = 0 } completion: { _ in choice.bar.removeFromSuperview() }
    }

    /// The rows chosen, tinted.
    func showChosen() {
        guard let choice = rowChoice else { return }
        choice.tints.subviews.forEach { $0.removeFromSuperview() }
        choice.tints.frame = bounds
        for index in choice.rows.sorted() where rows.indices.contains(index) {
            let tint = UIView(frame: rowsFrame(index..<(index + 1)).insetBy(dx: -6, dy: -1))
            tint.backgroundColor = Ink.pill
            tint.layer.cornerRadius = 8
            tint.layer.cornerCurve = .continuous
            choice.tints.addSubview(tint)
        }
    }

    /// Each chosen row with those under it, top to bottom — those inside
    /// another chosen row's left to it.
    var chosenBlocks: [Range<Int>] {
        guard let choice = rowChoice else { return [] }
        let all = rows
        var blocks: [Range<Int>] = []
        for index in choice.rows.sorted() where all.indices.contains(index) {
            if let last = blocks.last, last.contains(index) { continue }
            blocks.append(OutlineEditing.block(all, index..<(index + 1)))
        }
        return blocks
    }

    private func showChoiceBar(_ choice: RowChoice) {
        guard let window else { return }
        let symbols = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        let items: [(String, String, () -> Void)] = [
            ("checkmark.circle", "Done", { [weak self] in self?.markChosenDone() }),
            ("decrease.indent", "Outdent", { [weak self] in self?.shiftChosen(in: false) }),
            ("increase.indent", "Indent", { [weak self] in self?.shiftChosen(in: true) }),
            ("arrow.right.doc.on.clipboard", "Move to…", { [weak self] in
                guard let self, let first = rowChoice?.rows.min() else { return }
                onMoveRows?(self, first)
            }),
            ("trash", "Delete", { [weak self] in self?.deleteChosen() }),
            ("xmark", "Stop Choosing", { [weak self] in self?.endChoosingRows() }),
        ]
        let stack = UIStackView()
        stack.distribution = .fillEqually
        for (symbol, label, run) in items {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: symbols), for: .normal)
            button.tintColor = symbol == "trash" ? .systemRed : Ink.text
            button.accessibilityLabel = label
            button.addAction(UIAction { _ in run() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        choice.bar.cornerConfiguration = .capsule()
        choice.bar.contentView.addSubview(stack)
        let width = min(window.bounds.width - 32, 360), height: CGFloat = 52
        choice.bar.frame = CGRect(x: (window.bounds.width - width) / 2, y: window.bounds.height - window.safeAreaInsets.bottom - height - 84,
                                  width: width, height: height)
        stack.frame = choice.bar.bounds.insetBy(dx: 10, dy: 0)
        choice.bar.alpha = 0
        window.addSubview(choice.bar)
        UIView.animate(withDuration: 0.2) { choice.bar.alpha = 1 }
    }

    private func markChosenDone() {
        var all = rows
        for block in chosenBlocks {
            let row = block.lowerBound
            guard all[row].task != nil, all[row].task?.isDone != true else { continue }
            OutlineEditing.toggleDone(&all, row..<(row + 1))
        }
        replace(all, caret: nil, undoName: "Mark Done")
        endChoosingRows()
    }

    private func shiftChosen(in inward: Bool) {
        var all = rows
        // The lowest first: each row's moving leaves those above where they were.
        for block in chosenBlocks.reversed() {
            _ = inward ? OutlineEditing.indent(&all, block.lowerBound..<(block.lowerBound + 1))
                : OutlineEditing.outdent(&all, block.lowerBound..<(block.lowerBound + 1))
        }
        replace(all, caret: nil, undoName: inward ? "Indent" : "Outdent")
        showChosen()
    }

    private func deleteChosen() {
        var all = rows
        for block in chosenBlocks.reversed() { _ = OutlineEditing.delete(&all, block) }
        replace(all, caret: nil, undoName: "Delete Rows")
        endChoosingRows()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
