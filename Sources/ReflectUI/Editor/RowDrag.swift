import AppKit
import ReflectCore

/// Rows dragged by their bullets: a row and all under it — or the rows
/// selected, with theirs — picked up and put down between rows, here or in
/// another note, as deep as the pointer is far in. A line shows where.
///
/// Within the app the rows move, folded ones with what is folded in them;
/// dragged out of it, they are their Markdown.
extension OutlineTextView {
    package static let rowsType = NSPasteboard.PasteboardType("com.mariusae.reflect.rows")

    /// Where dragged rows go: before the row at an index, at a depth.
    package struct RowDrop: Equatable {
        package var index: Int
        package var depth: Int

        package init(index: Int, depth: Int) {
            self.index = index
            self.depth = depth
        }
    }

    // MARK: Dragging from

    /// Starts dragging the row whose bullet the mouse went down on — or,
    /// when it is among the rows selected, all of them — with what is under.
    package func beginDraggingRows(from index: Int, event: NSEvent) {
        let all = rows
        guard index < all.count else { return }
        let selection = selectedRows.flatMap { $0.contains(index) ? $0 : nil } ?? index..<(index + 1)
        let block = OutlineEditing.block(all, selection)
        draggedRows = block
        let markdown = markdown(forRows: selection)

        let item = NSPasteboardItem()
        item.setString(markdown, forType: Self.rowsType)
        item.setString(markdown, forType: .string)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let frame = rowsFrame(block)
        dragging.setDraggingFrame(frame, contents: snapshot(of: frame))
        LinkCard.shared.hide()
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    /// The rectangle some rows take, in the view.
    private func rowsFrame(_ block: Range<Int>) -> NSRect {
        guard let layout = layoutManager, let container = textContainer, !block.isEmpty else { return .zero }
        let ranges = paragraphRanges
        let characters = NSRange(location: ranges[block.lowerBound].location,
                                 length: NSMaxRange(ranges[block.upperBound - 1]) - ranges[block.lowerBound].location)
        let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var rect = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
        guard !rect.isNull else { return .zero }
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // From the bullets, not the margin.
        let left = textContainerOrigin.x + metrics.textIndent(for: rows[block.lowerBound]) - metrics.indent
        rect.size.width = min(rect.maxX, textContainerOrigin.x + container.size.width) - left
        rect.origin.x = left
        return rect.integral
    }

    private func snapshot(of rect: NSRect) -> NSImage {
        let image = NSImage(size: rect.size)
        guard rect.width > 0, rect.height > 0, let bitmap = bitmapImageRepForCachingDisplay(in: rect) else { return image }
        cacheDisplay(in: rect, to: bitmap)
        image.addRepresentation(bitmap)
        return NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.75)
            return true
        }
    }

    // MARK: Dropping on

    package func carriesRows(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(Self.rowsType) ?? false
    }

    /// Follows rows dragged over the view: a line where they would go.
    package func rowDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        if let event = NSApp.currentEvent { autoscroll(with: event) }
        let drop = rowDrop(at: convert(sender.draggingLocation, from: nil))
        guard !isInsideDragged(drop, from: sender) else {
            dropLine.isHidden = true
            return []
        }
        showDropLine(index: drop.index, depth: drop.depth)
        return sender.draggingSource is OutlineTextView ? .move : .copy
    }

    /// Puts dropped rows in place, taking them from where they were when
    /// they came from a note.
    package func dropRows(_ sender: NSDraggingInfo) -> Bool {
        dropLine.isHidden = true
        guard isEditable else { return false }
        let drop = rowDrop(at: convert(sender.draggingLocation, from: nil))
        guard !isInsideDragged(drop, from: sender) else { return false }
        if let source = sender.draggingSource as? OutlineTextView, let block = source.draggedRows {
            moveRows(block, from: source, to: drop)
            return true
        }
        guard let markdown = sender.draggingPasteboard.string(forType: Self.rowsType) else { return false }
        insertRows(OutlineMarkdown.parse(markdown).rows, at: drop)
        return true
    }

    /// Whether a drop would put rows inside themselves.
    private func isInsideDragged(_ drop: RowDrop, from sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? OutlineTextView, source === self, let block = draggedRows else { return false }
        return drop.index > block.lowerBound && drop.index < block.upperBound
    }

    /// Where rows dropped at a point go: above or below the row under it,
    /// whichever half it is in; as deep as the pointer is far in — no
    /// deeper than a child of the row before, and never so shallow as to
    /// take the children of the row after away from it.
    package func rowDrop(at point: NSPoint) -> RowDrop {
        let all = rows
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0, !all.isEmpty else {
            return RowDrop(index: 0, depth: 0)
        }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = min(layout.glyphIndex(for: inContainer, in: container), max(layout.numberOfGlyphs - 1, 0))
        let under = rowIndex(at: layout.characterIndexForGlyph(at: glyph))
        let frame = rowsFrame(under..<(under + 1))
        var index = point.y > frame.midY ? under + 1 : under
        if point.y > rowsFrame(all.indices.suffix(1)).maxY { index = all.count }
        let previous = index > 0 ? all[index - 1] : nil
        let deepest = previous.map { $0.depth + ($0.canHaveChildren ? 1 : 0) } ?? 0
        let shallowest = index < all.count && previous.map({ all[index].depth > $0.depth }) == true ? all[index].depth : 0
        let pointed = Int(((inContainer.x - metrics.indent / 2) / metrics.indent).rounded(.down))
        return RowDrop(index: index, depth: min(max(pointed, shallowest), max(deepest, shallowest)))
    }

    // MARK: Moving

    /// Rows moved here from a view — this one, or another note's.
    package func moveRows(_ block: Range<Int>, from source: OutlineTextView, to drop: RowDrop) {
        guard source !== self else {
            if drop.index > block.lowerBound && drop.index < block.upperBound { return }
            moveRows(block, to: drop)
            return
        }
        let moving = Array(source.rows[block])
        source.removeRows(block)
        insertRows(moving, at: drop)
    }

    /// Rows of this view moved to a place in it — or only made deeper or
    /// shallower, put down where they were.
    private func moveRows(_ block: Range<Int>, to drop: RowDrop) {
        let before = rows
        var after = before
        let moving = Self.takeOut(block, from: &after)
        var index = drop.index
        if index > block.lowerBound { index -= block.count }
        place(moving, at: RowDrop(index: index, depth: drop.depth), in: &after, before: before)
    }

    /// Rows from elsewhere put in at a place.
    package func insertRows(_ moving: [Row], at drop: RowDrop) {
        guard !moving.isEmpty else { return }
        let before = rows
        var after = before
        place(moving, at: drop, in: &after, before: before)
    }

    private func place(_ moving: [Row], at drop: RowDrop, in after: inout [Row], before: [Row]) {
        window?.makeFirstResponder(self)
        if selectedRows != nil { leaveRowSelection() }
        let shift = drop.depth - moving[0].depth
        var placed = moving.map { row -> Row in
            var row = row
            row.depth = max(0, row.depth + shift)
            return row
        }
        var start = min(drop.index, after.count)
        // The blank lines before where they go stay there: above them now.
        placed[0].gap = start < after.count ? after[start].gap : []
        if start < after.count { after[start].gap = [] }
        after.insert(contentsOf: placed, at: start)
        // A note that was only an empty row, where the rows came in, loses it.
        if after.count == placed.count + 1 {
            let empty = start == 0 ? after.count - 1 : 0
            if after[empty].text.isEmpty, after[empty].folded.isEmpty, after[empty].kind == .bullet {
                after.remove(at: empty)
                if empty < start { start -= 1 }
            }
        }
        OutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Move Rows")
        selectRows(anchor: start, head: start + placed.count - 1)
    }

    /// Takes rows out, and gives the blank lines before them — which are
    /// the note's, where they were — to the row that comes up in their place.
    package static func takeOut(_ block: Range<Int>, from rows: inout [Row]) -> [Row] {
        let taken = Array(rows[block])
        rows.removeSubrange(block)
        if let gap = taken.first?.gap, !gap.isEmpty, block.lowerBound < rows.count, rows[block.lowerBound].gap.isEmpty {
            rows[block.lowerBound].gap = gap
        }
        return taken
    }

    /// Takes rows out of this view, which moved elsewhere; a note left with
    /// nothing keeps an empty row to write in.
    package func removeRows(_ block: Range<Int>) {
        let before = rows
        guard block.upperBound <= before.count else { return }
        if selectedRows != nil { leaveRowSelection() }
        var after = before
        _ = Self.takeOut(block, from: &after)
        if after.isEmpty { after = [.blank] }
        OutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Move Rows")
    }
}
