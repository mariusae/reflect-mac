import AppKit
import ReflectCore

/// Where a time block is: its card, the times at its left, the free time
/// after it.
package struct TimeBlockGeometry {
    /// The block's first paragraph, by index.
    package var head: Int
    /// The paragraphs it holds.
    package var paragraphs: Range<Int>
    package var slot: TimeSlot
    /// Its card, in the text view.
    package var card: NSRect
    /// The free time after it.
    package var free: NSRect
    /// Where the times are, at its left.
    package var gutter: NSRect
    /// The foot of its words: below, the card is empty.
    package var contentBottom: CGFloat
    /// The baseline of its first line.
    package var baseline: CGFloat

    /// Whether any row of a text is in a time block.
    static func any(in storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(.outlineTimeSlot, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The top of a block, in the text container: its first line's.
    static func top(of slot: TimeSlot, endingAt character: Int, in layoutManager: NSLayoutManager,
                    line: NSRange, fragment: NSRect) -> CGFloat {
        guard let storage = layoutManager.textStorage else { return fragment.minY }
        let text = storage.string as NSString
        var start = text.paragraphRange(for: NSRange(location: character, length: 0)).location
        for _ in 0..<slot.back where start > 0 {
            start = text.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: start)
        let style = storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
        let before = style?.paragraphSpacingBefore ?? 0
        if glyph >= line.location { return fragment.minY + before }
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true).minY + before
    }
}

extension OutlineLayoutManager {
    /// The time blocks among some paragraphs — those whose rows any of them
    /// is — with where they are.
    package func timeBlocks(touching range: Range<Int>? = nil, origin: NSPoint) -> [TimeBlockGeometry] {
        guard let storage = textStorage, let view = outlineView, storage.length > 0 else { return [] }
        let paragraphs = view.paragraphRanges
        let range = range ?? 0..<paragraphs.count
        guard !range.isEmpty else { return [] }
        var found: [TimeBlockGeometry] = []
        var index = range.lowerBound
        // From the head of the block the first is in.
        if index < paragraphs.count, let slot = storage.attribute(.outlineTimeSlot, at: paragraphs[index].location, effectiveRange: nil) as? TimeSlot {
            index = max(0, index - slot.back)
        }
        let width = view.textContainer?.size.width ?? view.bounds.width
        while index < min(range.upperBound, paragraphs.count) {
            guard let slot = storage.attribute(.outlineTimeSlot, at: paragraphs[index].location, effectiveRange: nil) as? TimeSlot,
                  slot.back == 0 else {
                index += 1
                continue
            }
            var last = index
            while last + 1 < paragraphs.count, !((storage.attribute(.outlineTimeSlot, at: paragraphs[last].location, effectiveRange: nil) as? TimeSlot)?.isLast ?? true) {
                last += 1
            }
            let headGlyph = glyphIndexForCharacter(at: paragraphs[index].location)
            let lastGlyph = glyphIndexForCharacter(at: NSMaxRange(paragraphs[last]) - 1)
            guard headGlyph < numberOfGlyphs, lastGlyph < numberOfGlyphs else { break }
            let headFragment = lineFragmentRect(forGlyphAt: headGlyph, effectiveRange: nil)
            let footFragment = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let footUsed = lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let style = storage.attribute(.paragraphStyle, at: paragraphs[index].location, effectiveRange: nil) as? NSParagraphStyle
            let top = headFragment.minY + (style?.paragraphSpacingBefore ?? 0)
            let cardBottom = footFragment.maxY - slot.freeHeight
            let row = OutlineText.style(storage, at: paragraphs[index].location).row
            let left = view.metrics.textIndent(for: row) + slot.measures.gutter - view.metrics.indent
            let card = NSRect(x: left - 4, y: top - slot.measures.pad, width: width - left + 4, height: cardBottom - top + slot.measures.pad)
                .offsetBy(dx: origin.x, dy: origin.y)
            let free = NSRect(x: card.minX, y: card.maxY, width: card.width, height: slot.freeHeight)
            let gutter = NSRect(x: card.minX - slot.measures.gutter, y: card.minY, width: slot.measures.gutter, height: card.height)
            let font = view.metrics.font(for: row)
            // The content's foot: its own lines', not the room the card is given.
            let contentFoot = footUsed.minY + min(footUsed.height, ceil(defaultLineHeight(for: font) * max(1, view.metrics.lineHeightMultiple)))
            found.append(TimeBlockGeometry(head: index, paragraphs: index..<(last + 1), slot: slot, card: card, free: free, gutter: gutter,
                                           contentBottom: contentFoot + origin.y,
                                           baseline: origin.y + baseline(ofLineAt: headGlyph, font: font)))
            index = last + 1
        }
        return found
    }

    /// Draws time blocks' cards, the times at their left, the free time
    /// between them and, on today's page, the time now.
    func drawTimeBlocks(_ blocks: [TimeBlockGeometry]) {
        guard let view = outlineView else { return }
        let ink = view.metrics.typography.ink
        let now = view.day == .today ? Calendar.current.dateComponents([.hour, .minute], from: Date()) : nil
        let nowMinutes = now.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) }
        for block in blocks {
            let slot = block.slot
            let measures = slot.measures
            let isNow = nowMinutes.map { $0 >= slot.start && $0 < slot.end } ?? false
            let card = block.card.insetBy(dx: 0, dy: 1)
            let path = NSBezierPath(roundedRect: card, xRadius: 7, yRadius: 7)
            let accent = NSColor.controlAccentColor
            (slot.done ? ink.text.withAlphaComponent(0.035) : accent.withAlphaComponent(isNow ? 0.17 : 0.09)).setFill()
            path.fill()
            // A bar down its left, as a calendar's events have.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            (slot.done ? ink.tertiary : accent.withAlphaComponent(isNow ? 0.95 : 0.6)).setFill()
            NSRect(x: card.minX, y: card.minY, width: 3, height: card.height).fill()
            NSGraphicsContext.restoreGraphicsState()

            // The times: the start by the first line, the end at the foot
            // when free time, or nothing, follows.
            let font = NSFont.monospacedDigitSystemFont(ofSize: measures.labelSize, weight: .medium)
            func label(_ minutes: Int, at y: CGFloat, color: NSColor, baseline: Bool) {
                let text = NSAttributedString(string: TimeStamp.shown(minutes, twelveHour: measures.twelveHour),
                                              attributes: [.font: font, .foregroundColor: color])
                let size = text.size()
                let x = card.minX - 8 - size.width
                text.draw(at: NSPoint(x: x, y: baseline ? y - font.ascender : y - size.height / 2))
            }
            label(slot.start, at: block.baseline, color: slot.done ? ink.tertiary : ink.secondary, baseline: true)
            // Only where it clears the start's.
            if slot.free > 0 || slot.isLastBlock, card.maxY - block.baseline > font.pointSize * 2.6 {
                label(slot.end, at: min(card.maxY - font.capHeight / 2 - 3, card.maxY), color: ink.tertiary, baseline: false)
            }
            // How long, at the right of its first line — but for the block
            // whose time is written out, which its words might run into.
            if !slot.revealed {
                let length = NSAttributedString(string: TimeStamp.length(slot.end - slot.start),
                                                attributes: [.font: font, .foregroundColor: ink.tertiary])
                let lengthSize = length.size()
                length.draw(at: NSPoint(x: card.maxX - 10 - lengthSize.width, y: block.baseline - font.ascender))
            }
            // The free time, told in it when there is room.
            if slot.free > 0, block.free.height >= font.pointSize + 6 {
                let free = NSAttributedString(string: "\(TimeStamp.length(slot.free)) free",
                                              attributes: [.font: NSFont.systemFont(ofSize: measures.labelSize), .foregroundColor: ink.tertiary])
                let size = free.size()
                free.draw(at: NSPoint(x: card.minX + 12, y: block.free.midY - size.height / 2))
            }
            // The time now: a line across, where it falls.
            if let nowMinutes {
                var y: CGFloat?
                if isNow {
                    y = card.minY + card.height * CGFloat(nowMinutes - slot.start) / CGFloat(max(1, slot.end - slot.start))
                } else if slot.free > 0, nowMinutes >= slot.end, nowMinutes < slot.end + slot.free {
                    y = block.free.minY + block.free.height * CGFloat(nowMinutes - slot.end) / CGFloat(slot.free)
                }
                if let y {
                    let red = NSColor.systemRed
                    red.setFill()
                    NSRect(x: card.minX - 6, y: y.rounded() - 0.75, width: card.maxX - card.minX + 6, height: 1.5).fill()
                    NSBezierPath(ovalIn: NSRect(x: card.minX - 10, y: y - 4, width: 8, height: 8)).fill()
                }
            }
        }
    }

    /// The time block at a point, and whether the point is on its foot —
    /// to make it longer or shorter — or on it, away from its words — to
    /// move it.
    package func timeBlockHit(at point: NSPoint, origin: NSPoint) -> (block: TimeBlockGeometry, resizing: Bool)? {
        for block in timeBlocks(origin: origin) {
            let foot = NSRect(x: block.card.minX, y: block.card.maxY - 4, width: block.card.width, height: 8)
            if foot.contains(point) { return (block, true) }
            if block.gutter.contains(point) { return (block, false) }
            if block.card.contains(point), point.y > block.contentBottom + 2 { return (block, false) }
        }
        return nil
    }
}

extension OutlineTextView {
    /// The cursor over a time block: to move it, or to make it longer.
    func timeBlockCursor(at point: NSPoint) -> NSCursor? {
        guard isEditable, let storage = textStorage, TimeBlockGeometry.any(in: storage),
              let hit = outlineLayout.timeBlockHit(at: point, origin: textContainerOrigin) else { return nil }
        return hit.resizing ? .resizeUpDown : .openHand
    }

    /// A time block taken by its times, its empty part or its foot, and
    /// dragged: moved, or made longer or shorter, by five minutes at a
    /// time — and the blocks after it with it, unless ⌥ is held. Clicked,
    /// it takes the caret at the end of its words. True when it was one.
    func dragTimeBlock(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard isEditable, let storage = textStorage, TimeBlockGeometry.any(in: storage),
              let hit = outlineLayout.timeBlockHit(at: point, origin: textContainerOrigin) else { return false }
        window?.makeFirstResponder(self)
        let original = rows
        guard let timeline = Timeline.find(original).first(where: { $0.blocks.contains { $0.row == hit.block.head } }),
              let index = timeline.blocks.firstIndex(where: { $0.row == hit.block.head }) else { return false }
        let perMinute = hit.block.slot.measures.perMinute
        let texts = original.map(\.text)
        let start = event.locationInWindow
        var applied = 0
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
            let alone = next.modifierFlags.contains(.option)
            guard minutes != applied || next.type == .flagsChanged else { continue }
            let changed = timeline.moved(index, by: minutes, resizing: hit.resizing, alone: alone, texts: texts)
            let before = rows
            var after = before
            for (row, text) in changed where row < after.count { after[row].text = text }
            for row in after.indices where changed[row] == nil && row < original.count && after[row].text != original[row].text
            && timeline.blocks.contains(where: { $0.row == row }) {
                // Let go of with ⌥: back where they were.
                after[row].text = original[row].text
            }
            let caret = caretPosition
            replace(before, with: after, actionName: hit.resizing ? "Change Block's Length" : "Move Block")
            restoreCaret(caret)
            applied = minutes
        }
        if !moved {
            // A click: the caret at the end of the block's words.
            let paragraphs = paragraphRanges
            let last = hit.block.paragraphs.upperBound - 1
            if last < paragraphs.count {
                if selectedRows != nil { leaveRowSelection() }
                setSelectedRange(NSRange(location: NSMaxRange(paragraphs[last]) - 1, length: 0))
            }
        }
        return true
    }
}
