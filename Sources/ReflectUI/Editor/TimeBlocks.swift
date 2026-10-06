import AppKit
import ReflectCore

/// Where a time block is drawn, in the text view: its node on the line —
/// its bullet's place — its time and length over its words, the line down
/// to where it ends, and the free time after.
package struct TimeBlockGeometry {
    /// The block's first paragraph, by index.
    package var head: Int
    package var mark: TimeMark.Head
    package var measures: TimeSlot.Measures
    /// The node: its middle, and whether it is drawn (a checkbox is its own).
    package var node: NSPoint
    package var drawsNode: Bool
    /// Where the line leaves the node, and where its solid part ends: the
    /// block's end.
    package var lineTop: CGFloat
    package var end: CGFloat
    /// The free time after it — dashed — down to the next block's node.
    package var free: ClosedRange<CGFloat>?
    /// The room the free time is given after the block: where it is told.
    package var freeRoom: ClosedRange<CGFloat>?
    /// Where the time and length are written, over the words.
    package var label: NSRect
    package var freeLabel: String?

    /// Whether any row of a text is in a timeline.
    static func any(in storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(.outlineTimeSlot, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}

extension OutlineLayoutManager {
    private func slot(_ storage: NSTextStorage, _ paragraph: NSRange) -> TimeSlot? {
        paragraph.length > 0 ? storage.attribute(.outlineTimeSlot, at: paragraph.location, effectiveRange: nil) as? TimeSlot : nil
    }

    private func lastSlot(_ storage: NSTextStorage, _ paragraph: NSRange) -> TimeSlot? {
        paragraph.length > 0 ? storage.attribute(.outlineTimeSlot, at: NSMaxRange(paragraph) - 1, effectiveRange: nil) as? TimeSlot : nil
    }

    /// The node's middle for a row: where its bullet would be.
    private func nodeCenter(_ storage: NSTextStorage, _ paragraphs: [NSRange], _ index: Int, origin: NSPoint) -> (NSPoint, NSFont, CGFloat)? {
        guard let view = outlineView, index < paragraphs.count else { return nil }
        let row = OutlineText.style(storage, at: paragraphs[index].location).row
        let glyph = glyphIndexForCharacter(at: paragraphs[index].location)
        guard glyph < numberOfGlyphs else { return nil }
        let font = view.metrics.font(for: row)
        let baseline = origin.y + self.baseline(ofLineAt: glyph, font: font)
        let x = origin.x + view.metrics.textIndent(for: row) - view.metrics.indent / 2
        let y = row.task != nil ? baseline - font.capHeight / 2 : baseline - font.xHeight / 2
        return (NSPoint(x: x, y: y), font, baseline)
    }

    /// The time blocks starting among some paragraphs — and those before
    /// them whose lines reach into them — with where they are.
    package func timeBlocks(touching range: Range<Int>? = nil, origin: NSPoint) -> [TimeBlockGeometry] {
        guard let storage = textStorage, let view = outlineView, storage.length > 0 else { return [] }
        let paragraphs = view.paragraphRanges
        let range = range ?? 0..<paragraphs.count
        guard !range.isEmpty else { return [] }
        var found: [TimeBlockGeometry] = []
        // Back a way: a block above can run its line down into these rows.
        for index in max(0, range.lowerBound - 300)..<min(range.upperBound, paragraphs.count) {
            guard let slot = slot(storage, paragraphs[index]), let head = slot.mark.head else { continue }
            let reach = head.nextRow ?? head.lastRow
            guard index >= range.lowerBound || reach >= range.lowerBound else { continue }
            guard let (node, font, baseline) = nodeCenter(storage, paragraphs, index, origin: origin), head.lastRow < paragraphs.count else { continue }
            let measures = slot.measures
            let row = OutlineText.style(storage, at: paragraphs[index].location).row
            // Where the block ends: its last row's foot, after those of
            // blocks nested in it that end there too.
            let lastParagraph = paragraphs[head.lastRow]
            let lastGlyph = glyphIndexForCharacter(at: NSMaxRange(lastParagraph) - 1)
            guard lastGlyph < numberOfGlyphs else { continue }
            let foot = lastSlot(storage, lastParagraph)
            var cursor = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY + origin.y - (foot?.footHeight ?? 0)
            var end = cursor, free: ClosedRange<CGFloat>?
            var freeLabel: String?
            var freeRoom: ClosedRange<CGFloat>?
            for each in foot?.mark.feet ?? [] {
                let length = (each.length * measures.row).rounded()
                let rest = foot.map { $0.extent(each) } ?? 0
                if each.timeline == head.timeline && each.index == head.index {
                    end = cursor + length
                    if each.free > 0 {
                        // Down to the next block's node, dashed; its label
                        // in the room given to it.
                        let next = head.nextRow.flatMap { nodeCenter(storage, paragraphs, $0, origin: origin)?.0.y }
                        free = end...max(end, (next ?? cursor + rest) - 6)
                        freeRoom = end...(cursor + rest)
                        freeLabel = each.freeLabel
                    }
                    break
                }
                cursor += rest
            }
            // No free time: the line runs on to the next block's node.
            if free == nil, let next = head.nextRow.flatMap({ nodeCenter(storage, paragraphs, $0, origin: origin)?.0.y }) {
                end = max(end, next - 6)
            }
            let radius = row.task == nil ? 3.5 : font.pointSize * 0.48
            let labelX = origin.x + view.metrics.textIndent(for: row)
            let label = NSRect(x: labelX, y: baseline - font.ascender - measures.header,
                               width: max(40, view.bounds.width - labelX - 8), height: measures.header)
            found.append(TimeBlockGeometry(head: index, mark: head, measures: measures, node: node, drawsNode: row.task == nil,
                                           lineTop: node.y + radius + 2, end: end, free: free, freeRoom: freeRoom, label: label, freeLabel: freeLabel))
        }
        return found
    }

    /// Draws the timelines: lines, nodes, times over the words, free time,
    /// and, on today's page, the time now on the line it falls on.
    func drawTimeBlocks(_ blocks: [TimeBlockGeometry]) {
        guard let view = outlineView else { return }
        let ink = view.metrics.typography.ink
        let accent = NSColor.controlAccentColor
        let now = view.day == .today ? Calendar.current.dateComponents([.hour, .minute], from: Date()) : nil
        let nowMinutes = now.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) }
        for block in blocks {
            let mark = block.mark
            let color = mark.done ? ink.tertiary : accent
            let x = block.node.x
            // The line: solid while the block lasts, dashed while free.
            let solid = NSBezierPath()
            solid.move(to: NSPoint(x: x, y: block.lineTop))
            solid.line(to: NSPoint(x: x, y: max(block.lineTop, block.end)))
            solid.lineWidth = 1.5
            color.withAlphaComponent(mark.level > 0 ? 0.45 : 0.6).setStroke()
            if block.end > block.lineTop { solid.stroke() }
            // Its end, marked: where to take it to make it longer.
            if view.hoveredTimeBlock == block.head {
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: x - 4, y: block.end))
                tick.line(to: NSPoint(x: x + 4, y: block.end))
                tick.lineWidth = 1.5
                tick.stroke()
            }
            if let free = block.free, free.upperBound > free.lowerBound {
                let dashed = NSBezierPath()
                dashed.move(to: NSPoint(x: x, y: free.lowerBound + 2))
                dashed.line(to: NSPoint(x: x, y: free.upperBound))
                dashed.lineWidth = 1
                dashed.setLineDash([2, 3], count: 2, phase: 0)
                ink.tertiary.setStroke()
                dashed.stroke()
                if let text = block.freeLabel, let room = block.freeRoom {
                    let label = NSAttributedString(string: text, attributes: [
                        .font: NSFont.systemFont(ofSize: block.measures.labelSize), .foregroundColor: ink.tertiary])
                    let size = label.size()
                    if room.upperBound - room.lowerBound >= size.height {
                        label.draw(at: NSPoint(x: block.label.minX, y: (room.lowerBound + room.upperBound) / 2 - size.height / 2))
                    }
                }
            }
            // The node: filled; hollow for a block nested in another's.
            if block.drawsNode {
                let dot = NSRect(x: x - 3.5, y: block.node.y - 3.5, width: 7, height: 7)
                if mark.level > 0 {
                    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    color.setStroke()
                    ring.stroke()
                } else {
                    color.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
            // The time and length over the words — but for the row whose
            // time is written out, where it would say it twice.
            let revealed = (textStorage?.attribute(.outlineTimeSlot, at: view.paragraphRanges[block.head].location, effectiveRange: nil) as? TimeSlot)?.revealed ?? false
            if !revealed {
                let font = NSFont.monospacedDigitSystemFont(ofSize: block.measures.labelSize, weight: .regular)
                let text = NSMutableAttributedString(string: mark.label, attributes: [.font: font, .foregroundColor: ink.secondary])
                if let overlap = mark.overlap {
                    // Named, when there is room for it.
                    let room = (view.visibleRect.maxX - 8) - block.label.minX
                    let full = NSAttributedString(string: mark.label + " · " + overlap, attributes: [.font: font]).size().width
                    text.append(NSAttributedString(string: " · " + (full <= room ? overlap : mark.overlapShort ?? overlap),
                                                   attributes: [.font: font, .foregroundColor: NSColor.systemOrange]))
                }
                // One line, as long as it is: a time is not to be wrapped.
                text.draw(with: NSRect(x: block.label.minX, y: block.label.minY, width: 4000, height: block.label.height),
                          options: [.usesLineFragmentOrigin])
            }
            // The time now, on the line, where it falls.
            if let nowMinutes, mark.start <= nowMinutes, nowMinutes < mark.end {
                let share = CGFloat(nowMinutes - mark.start) / CGFloat(max(1, mark.end - mark.start))
                let y = block.lineTop + (max(block.lineTop, block.end) - block.lineTop) * share
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)).fill()
            }
        }
    }

    /// The time block at a point, and whether the point is at its line's
    /// end — to make it longer or shorter — or on its time — to move it.
    package func timeBlockHit(at point: NSPoint, origin: NSPoint) -> (block: TimeBlockGeometry, resizing: Bool)? {
        guard let storage = textStorage, TimeBlockGeometry.any(in: storage) else { return nil }
        for block in timeBlocks(origin: origin) {
            let grip = NSRect(x: block.node.x - 7, y: block.end - 5, width: 14, height: 10)
            if grip.contains(point) { return (block, true) }
            let font = NSFont.monospacedDigitSystemFont(ofSize: block.measures.labelSize, weight: .regular)
            let width = NSAttributedString(string: block.mark.label, attributes: [.font: font]).size().width
            if NSRect(x: block.label.minX - 2, y: block.label.minY, width: width + 4, height: block.label.height).contains(point) { return (block, false) }
        }
        return nil
    }
}

extension OutlineTextView {
    /// The cursor over a time block: to move it, or to make it longer.
    func timeBlockCursor(at point: NSPoint) -> NSCursor? {
        guard isEditable, let hit = outlineLayout.timeBlockHit(at: point, origin: textContainerOrigin) else {
            if hoveredTimeBlock != nil { hoveredTimeBlock = nil }
            return nil
        }
        if hoveredTimeBlock != hit.block.head { hoveredTimeBlock = hit.block.head }
        return hit.resizing ? .resizeUpDown : .openHand
    }

    /// A time block taken by its time, or its line's end, and dragged:
    /// moved, or made longer or shorter, five minutes at a time — and, with
    /// ⌥ held, the blocks after it with it. True when it was one.
    func dragTimeBlock(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard isEditable, let hit = outlineLayout.timeBlockHit(at: point, origin: textContainerOrigin) else { return false }
        window?.makeFirstResponder(self)
        let original = rows
        guard let timeline = Timeline.find(original).first(where: { $0.blocks.contains { $0.row == hit.block.head } }),
              let index = timeline.blocks.firstIndex(where: { $0.row == hit.block.head }) else { return false }
        let perMinute = hit.block.measures.perMinute
        let texts = original.map(\.text)
        let start = event.locationInWindow
        var applied: (minutes: Int, following: Bool) = (0, false)
        var moved = false
        (hit.resizing ? NSCursor.resizeUpDown : NSCursor.closedHand).push()
        defer { NSCursor.pop() }
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged]) {
            if next.type == .leftMouseUp { break }
            let dy = start.y - next.locationInWindow.y
            if !moved, abs(dy) < 3 { continue }
            moved = true
            let minutes = Int((dy / perMinute / 5).rounded()) * 5
            let following = next.modifierFlags.contains(.option)
            guard minutes != applied.minutes || following != applied.following else { continue }
            let changed = timeline.moved(index, by: minutes, resizing: hit.resizing, following: following, texts: texts)
            let before = rows
            var after = before
            // Each block as it was, then as this drag has it.
            for block in timeline.blocks where block.row < after.count { after[block.row].text = original[block.row].text }
            for (row, text) in changed where row < after.count { after[row].text = text }
            let caret = caretPosition
            replace(before, with: after, actionName: hit.resizing ? "Change Block's Length" : "Move Block")
            restoreCaret(caret)
            applied = (minutes, following)
        }
        if !moved {
            // A click: the caret at the end of the block's words.
            let paragraphs = paragraphRanges
            if hit.block.head < paragraphs.count {
                if isSelectingRows { leaveRowSelection() }
                setSelectedRange(NSRange(location: NSMaxRange(paragraphs[hit.block.head]) - 1, length: 0))
            }
        }
        return true
    }
}
