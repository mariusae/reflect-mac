import UIKit
import ReflectCore

/// A row held: picked up with the rows under it, carried, and put down
/// where the line shows — before a row, at a depth set by how far across.
extension OutlineEditor {
    final class RowDragState {
        var block: Range<Int>
        let lifted: UIView
        let line = UIView()
        var drop: (index: Int, depth: Int)?
        var grab: CGPoint
        var autoscroll: CADisplayLink?
        var lastPoint: CGPoint = .zero
        /// Where the finger was when the row was picked up.
        var start: CGPoint = .zero

        init(block: Range<Int>, lifted: UIView, grab: CGPoint) {
            self.block = block
            self.lifted = lifted
            self.grab = grab
        }
    }

    /// The rectangle some rows take, in the editor.
    func rowsFrame(_ block: Range<Int>) -> CGRect {
        let ranges = paragraphRanges
        guard !block.isEmpty, block.upperBound <= ranges.count else { return .zero }
        let characters = NSRange(location: ranges[block.lowerBound].location,
                                 length: NSMaxRange(ranges[block.upperBound - 1]) - ranges[block.lowerBound].location)
        let glyphs = outlineLayout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rect = CGRect.null
        outlineLayout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
        guard !rect.isNull else { return .zero }
        rect = rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        let left = textContainerInset.left + metrics.indent * CGFloat(rows[block.lowerBound].depth)
        rect.size.width = rect.maxX - left
        rect.origin.x = left
        return rect.integral
    }

    /// The row a point is on.
    func rowUnder(_ point: CGPoint) -> Int? {
        guard textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = outlineLayout.glyphIndex(for: inContainer, in: textContainer)
        let line = outlineLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard inContainer.y >= line.minY - 4, inContainer.y <= line.maxY + 4 else { return nil }
        return rowIndex(at: outlineLayout.characterIndexForGlyph(at: glyph))
    }

    /// Where rows would go, dropped at a point: before which row, how deep.
    func rowDrop(at point: CGPoint, left: CGFloat? = nil) -> (index: Int, depth: Int) {
        let all = rows
        guard !all.isEmpty else { return (0, 0) }
        let under = rowUnder(point) ?? (point.y > rowsFrame(all.indices.suffix(1)).maxY ? all.count - 1 : 0)
        let frame = rowsFrame(under..<(under + 1))
        var index = point.y > frame.midY ? under + 1 : under
        if point.y > rowsFrame(all.indices.suffix(1)).maxY { index = all.count }
        let previous = index > 0 ? all[index - 1] : nil
        let deepest = previous.map { $0.depth + ($0.canHaveChildren ? 1 : 0) } ?? 0
        let shallowest = index < all.count && previous.map({ all[index].depth > $0.depth }) == true ? all[index].depth : 0
        // How deep: where the carried rows' bullet is, across — moved sideways to change it.
        let x = left ?? (point.x - textContainerInset.left - metrics.indent / 2)
        let pointed = Int((x / metrics.indent).rounded())
        return (index, min(max(pointed, shallowest), max(deepest, shallowest)))
    }

    @objc func heldRow(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard let index = rowUnder(point) else { return gesture.cancel() }
            let block = OutlineEditing.block(rows, index..<(index + 1))
            let frame = rowsFrame(block)
            guard frame.width > 0, let picture = resizableSnapshotView(from: frame, afterScreenUpdates: false, withCapInsets: .zero) else {
                return gesture.cancel()
            }
            let lifted = UIView(frame: frame)
            lifted.backgroundColor = Ink.card
            lifted.layer.cornerRadius = 8
            lifted.layer.shadowColor = UIColor.black.cgColor
            lifted.layer.shadowOpacity = 0.18
            lifted.layer.shadowRadius = 10
            lifted.layer.shadowOffset = CGSize(width: 0, height: 4)
            picture.frame = lifted.bounds
            lifted.addSubview(picture)
            addSubview(lifted)
            let state = RowDragState(block: block, lifted: lifted, grab: CGPoint(x: point.x - frame.minX, y: point.y - frame.minY))
            state.start = point
            state.line.backgroundColor = Ink.accent
            state.line.layer.cornerRadius = 1.5
            state.line.isHidden = true
            addSubview(state.line)
            rowDrag = state
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIView.animate(withDuration: 0.15) { lifted.transform = CGAffineTransform(scaleX: 1.03, y: 1.03) }
            if isFirstResponder { _ = resignFirstResponder() }
            followDrag(to: point)
            let link = CADisplayLink(target: self, selector: #selector(autoscrollDrag))
            link.add(to: .main, forMode: .common)
            state.autoscroll = link
        case .changed:
            followDrag(to: point)
        case .ended:
            // Let go where it was picked up, by a checklist's ring: what can
            // be done to the list, not a move.
            if let state = rowDrag, hypot(point.x - state.start.x, point.y - state.start.y) < 10, hasChecklist(under: state.block.lowerBound) {
                finishDrag(dropping: false)
                showListMenu(forRow: state.block.lowerBound, at: point)
                return
            }
            finishDrag(dropping: true)
        default:
            finishDrag(dropping: false)
        }
    }

    private func followDrag(to point: CGPoint) {
        guard let state = rowDrag else { return }
        state.lastPoint = point
        state.lifted.frame.origin = CGPoint(x: point.x - state.grab.x, y: point.y - state.grab.y)
        let left = state.lifted.frame.minX - textContainerInset.left
        let drop = rowDrop(at: point, left: left)
        // Within what is carried: nowhere to go.
        if drop.index > state.block.lowerBound && drop.index < state.block.upperBound {
            state.drop = nil
            state.line.isHidden = true
            return
        }
        if state.drop.map({ $0 != drop }) ?? true { UISelectionFeedbackGenerator().selectionChanged() }
        state.drop = drop
        let all = rows
        let y = drop.index < all.count ? rowsFrame(drop.index..<(drop.index + 1)).minY : rowsFrame(all.indices.suffix(1)).maxY
        let x = textContainerInset.left + metrics.indent * CGFloat(drop.depth) + metrics.indent / 2
        state.line.frame = CGRect(x: x, y: y - 1.5, width: max(20, bounds.width - x - 8), height: 3)
        state.line.isHidden = false
        bringSubviewToFront(state.lifted)
    }

    /// Near the top or bottom of the screen: the sheet scrolls along.
    @objc private func autoscrollDrag() {
        guard let state = rowDrag, let outer = enclosingScroll else { return }
        let inOuter = convert(state.lastPoint, to: outer)
        let visible = outer.bounds.inset(by: outer.adjustedContentInset)
        let edge: CGFloat = 70
        var delta: CGFloat = 0
        if inOuter.y < visible.minY + edge { delta = -(visible.minY + edge - inOuter.y) / 6 }
        if inOuter.y > visible.maxY - edge { delta = (inOuter.y - (visible.maxY - edge)) / 6 }
        guard delta != 0 else { return }
        let top = -outer.adjustedContentInset.top
        let bottom = max(top, outer.contentSize.height - outer.bounds.height + outer.adjustedContentInset.bottom)
        let y = min(max(outer.contentOffset.y + delta, top), bottom)
        let moved = y - outer.contentOffset.y
        guard moved != 0 else { return }
        outer.contentOffset.y = y
        followDrag(to: CGPoint(x: state.lastPoint.x, y: state.lastPoint.y + moved))
    }

    private var enclosingScroll: UIScrollView? {
        var view = superview
        while let current = view {
            if let scroll = current as? UIScrollView, !(scroll is UITextView) { return scroll }
            view = current.superview
        }
        return nil
    }

    private func finishDrag(dropping: Bool) {
        guard let state = rowDrag else { return }
        rowDrag = nil
        state.autoscroll?.invalidate()
        state.line.removeFromSuperview()
        UIView.animate(withDuration: 0.15, animations: { state.lifted.alpha = 0 }) { _ in state.lifted.removeFromSuperview() }
        guard dropping, let drop = state.drop else { return }
        let before = rows
        var after = before
        let taken = Array(after[state.block])
        after.removeSubrange(state.block)
        // The blank lines before them are the note's, where they were: kept there.
        if let gap = taken.first?.gap, !gap.isEmpty, state.block.lowerBound < after.count, after[state.block.lowerBound].gap.isEmpty {
            after[state.block.lowerBound].gap = gap
        }
        var index = drop.index
        if index > state.block.lowerBound { index -= state.block.count }
        index = min(index, after.count)
        let shift = drop.depth - taken[0].depth
        var placed = taken.map { row -> Row in
            var row = row
            row.depth = max(0, row.depth + shift)
            if shift != 0 { row.extraIndent = 0 }
            return row
        }
        // Those where they go keep the blank lines before them, above.
        placed[0].gap = index < after.count ? after[index].gap : []
        if index < after.count { after[index].gap = [] }
        after.insert(contentsOf: placed, at: index)
        OutlineEditing.normalize(&after)
        guard after != before else { return }
        replace(after, caret: nil, undoName: "Move Rows")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

private extension UIGestureRecognizer {
    func cancel() {
        isEnabled = false
        isEnabled = true
    }
}
