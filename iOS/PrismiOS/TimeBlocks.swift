import UIKit
import ReflectCore

extension NSAttributedString.Key {
    /// A row a timeline draws something at, as a `PhoneTimeSlot`.
    static let prismTimeSlot = NSAttributedString.Key("PrismTimeSlot")
}

/// What a timeline draws at a row: a block starting there — its time and
/// length over its words, its bullet a node on the line — or blocks ending
/// there, and the room after them. (`TimeMark`, in points.)
final class PhoneTimeSlot: NSObject {
    /// Of the type: a row's height, the room for a time over a row, and
    /// how far a drag goes for a minute.
    struct Measures: Equatable {
        var row: CGFloat
        var header: CGFloat
        var labelSize: CGFloat
        var pad: CGFloat
        var perMinute: CGFloat
        var twelveHour: Bool

        init(_ metrics: PhoneMetrics) {
            row = metrics.lineHeight * metrics.size + metrics.rowGap
            labelSize = round(metrics.size * 0.7)
            header = ceil(labelSize * 1.3)
            pad = round(metrics.size * 0.4)
            // Five minutes a drag of a third of a row, or so.
            perMinute = row / 15
            twelveHour = TimeStamp.localeIsTwelveHour
        }
    }

    let mark: TimeMark
    /// Whether the block's time is written out in its row: the caret is there.
    let revealed: Bool
    let measures: Measures

    init(mark: TimeMark, revealed: Bool, measures: Measures) {
        self.mark = mark
        self.revealed = revealed
        self.measures = measures
    }

    /// The room a block ending here takes after the row: a little for its
    /// length, its free time, and, its timeline's last, a gap after.
    func extent(_ foot: TimeMark.Foot) -> CGFloat {
        ((foot.length + foot.freeLength) * measures.row).rounded() + (foot.isLast ? measures.pad : 0)
    }

    var footHeight: CGFloat { mark.feet.reduce(0) { $0 + extent($1) } }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PhoneTimeSlot else { return false }
        return mark == other.mark && revealed == other.revealed && measures == other.measures
    }

    override var hash: Int { var h = Hasher(); h.combine(mark.head?.index); h.combine(mark.feet.count); return h.finalize() }

    /// The slots of a text's rows, by where their paragraphs start.
    static func slots(_ storage: NSTextStorage, metrics: PhoneMetrics, caret: Int?) -> [Int: PhoneTimeSlot] {
        let text = storage.mutableString
        let paragraphs = OutlineText.paragraphs(text)
        guard !paragraphs.isEmpty else { return [:] }
        var depths: [Int] = [], texts: [String] = [], items: [Bool] = [], done: [Bool] = []
        for paragraph in paragraphs {
            let row = OutlineText.style(storage, at: paragraph.location).row
            depths.append(row.depth)
            items.append(row.kind.isListItem)
            done.append(row.task?.isDone == true)
            texts.append(text.substring(with: NSRange(location: paragraph.location, length: min(paragraph.length, 80))))
        }
        let measures = Measures(metrics)
        let marks = TimeMark.marks(depths: depths, texts: texts, isListItem: items, done: done, twelveHour: measures.twelveHour)
        var found: [Int: PhoneTimeSlot] = [:]
        for (row, mark) in marks where row < paragraphs.count {
            let paragraph = paragraphs[row]
            let revealed = mark.head != nil && (caret.map { $0 >= paragraph.location && $0 < NSMaxRange(paragraph) } ?? false)
            found[paragraph.location] = PhoneTimeSlot(mark: mark, revealed: revealed, measures: measures)
        }
        return found
    }

    /// Whether any row of a text is in a timeline.
    static func any(in storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(.prismTimeSlot, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The slot of a row that starts a block, if it does.
    static func head(_ storage: NSTextStorage, at location: Int) -> PhoneTimeSlot? {
        guard location < storage.length, let slot = storage.attribute(.prismTimeSlot, at: location, effectiveRange: nil) as? PhoneTimeSlot,
              slot.mark.head != nil else { return nil }
        return slot
    }
}

/// Where a time block is drawn, in the text container.
struct PhoneTimeBlock {
    var head: NSRange
    var mark: TimeMark.Head
    var measures: PhoneTimeSlot.Measures
    var node: CGPoint
    var drawsNode: Bool
    var lineTop: CGFloat
    var end: CGFloat
    var free: ClosedRange<CGFloat>?
    var freeRoom: ClosedRange<CGFloat>?
    var freeLabel: String?
    var label: CGRect
    var revealed: Bool
}

extension PhoneLayoutManager {
    /// The first character of a paragraph shown: hidden markup is laid out
    /// on the line before.
    func firstShown(in paragraph: NSRange) -> Int {
        guard let storage = textStorage else { return paragraph.location }
        var first = paragraph.location
        while first < NSMaxRange(paragraph) - 1, storage.attribute(.prismHidden, at: first, effectiveRange: nil) != nil { first += 1 }
        return first
    }

    /// The room after a line a timeline's blocks end at, when it is such a
    /// line: their lengths, and their free time.
    func timeBlockFoot(characters: NSRange, fragment: CGRect, line: NSRange) -> CGFloat? {
        guard let storage = textStorage, characters.length > 0 else { return nil }
        let text = plainText
        // Back over the next row's hidden start, to this row's line break.
        var end = NSMaxRange(characters) - 1
        while end > characters.location, text.character(at: end) != 0x0A,
              storage.attribute(.prismHidden, at: end, effectiveRange: nil) != nil { end -= 1 }
        guard text.character(at: end) == 0x0A,
              let slot = storage.attribute(.prismTimeSlot, at: end, effectiveRange: nil) as? PhoneTimeSlot, slot.footHeight > 0 else { return nil }
        return slot.footHeight
    }

    /// A row's node: where its bullet would be, on its first line.
    private func node(_ paragraph: NSRange) -> (CGPoint, UIFont, CGFloat, Row)? {
        guard let storage = textStorage else { return nil }
        let row = OutlineText.style(storage, at: paragraph.location).row
        let glyph = glyphIndexForCharacter(at: firstShown(in: paragraph))
        guard glyph < numberOfGlyphs else { return nil }
        let font = metrics.font(for: row)
        let baseline = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + location(forGlyphAt: glyph).y
        let x = metrics.indent * CGFloat(row.depth) + metrics.indent / 2
        let y = row.task != nil ? baseline - font.capHeight / 2 : baseline - font.xHeight / 2
        return (CGPoint(x: x, y: y), font, baseline, row)
    }

    /// The time blocks starting among some characters' rows — and those
    /// before whose lines reach into them — with where they are.
    func timeBlocks(in characters: NSRange? = nil) -> [PhoneTimeBlock] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let text = plainText
        let paragraphs = OutlineText.paragraphs(text)
        let firstRow: Int, lastRow: Int
        if let characters {
            firstRow = paragraphs.firstIndex { NSMaxRange($0) > characters.location } ?? paragraphs.count
            lastRow = paragraphs.lastIndex { $0.location < NSMaxRange(characters) } ?? -1
        } else {
            firstRow = 0
            lastRow = paragraphs.count - 1
        }
        guard lastRow >= 0 else { return [] }
        var found: [PhoneTimeBlock] = []
        for index in max(0, firstRow - 300)...min(lastRow, paragraphs.count - 1) {
            let paragraph = paragraphs[index]
            guard let slot = PhoneTimeSlot.head(storage, at: paragraph.location), let head = slot.mark.head else { continue }
            let reach = head.nextRow ?? head.lastRow
            guard index >= firstRow || reach >= firstRow, head.lastRow < paragraphs.count,
                  let (node, font, baseline, row) = node(paragraph) else { continue }
            let measures = slot.measures
            // Where the block ends: its last row's foot, after those of
            // blocks nested in it that end there too.
            let lastParagraph = paragraphs[head.lastRow]
            let lastGlyph = glyphIndexForCharacter(at: NSMaxRange(lastParagraph) - 1)
            guard lastGlyph < numberOfGlyphs else { continue }
            let foot = storage.attribute(.prismTimeSlot, at: NSMaxRange(lastParagraph) - 1, effectiveRange: nil) as? PhoneTimeSlot
            var cursor = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil).maxY - (foot?.footHeight ?? 0)
            var end = cursor
            var free: ClosedRange<CGFloat>?, freeRoom: ClosedRange<CGFloat>?, freeLabel: String?
            let nextY = head.nextRow.flatMap { $0 < paragraphs.count ? self.node(paragraphs[$0])?.0.y : nil }
            for each in foot?.mark.feet ?? [] {
                let rest = foot?.extent(each) ?? 0
                if each.timeline == head.timeline && each.index == head.index {
                    end = cursor + (each.length * measures.row).rounded()
                    if each.free > 0 {
                        free = end...max(end, (nextY ?? cursor + rest) - 6)
                        freeRoom = end...(cursor + rest)
                        freeLabel = each.freeLabel
                    }
                    break
                }
                cursor += rest
            }
            if free == nil, let nextY { end = max(end, nextY - 6) }
            let radius: CGFloat = row.task == nil ? 3.5 : font.pointSize * 0.45
            let labelX = metrics.textIndent(for: row)
            let label = CGRect(x: labelX, y: baseline - font.ascender - measures.header, width: 4000, height: measures.header)
            found.append(PhoneTimeBlock(head: paragraph, mark: head, measures: measures, node: node, drawsNode: row.task == nil,
                                        lineTop: node.y + radius + 2, end: end, free: free, freeRoom: freeRoom, freeLabel: freeLabel,
                                        label: label, revealed: slot.revealed))
        }
        return found
    }

    /// Draws the timelines: lines, nodes, times over the words, free time,
    /// and, on today's page, the time now on the line it falls on.
    func drawTimeBlocks(_ blocks: [PhoneTimeBlock], at origin: CGPoint, today: Bool) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let now = today ? Calendar.current.dateComponents([.hour, .minute], from: Date()) : nil
        let nowMinutes = now.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) }
        for block in blocks {
            let mark = block.mark
            let color = mark.done ? Ink.faint : Ink.accent
            let x = block.node.x + origin.x
            let top = block.lineTop + origin.y, end = block.end + origin.y
            context.saveGState()
            // The line: solid while the block lasts, dashed while free.
            if end > top {
                color.withAlphaComponent(mark.level > 0 ? 0.45 : 0.6).setStroke()
                let solid = UIBezierPath()
                solid.move(to: CGPoint(x: x, y: top))
                solid.addLine(to: CGPoint(x: x, y: end))
                solid.lineWidth = 1.5
                solid.stroke()
            }
            if let free = block.free, free.upperBound > free.lowerBound {
                Ink.faint.setStroke()
                let dashed = UIBezierPath()
                dashed.move(to: CGPoint(x: x, y: free.lowerBound + origin.y + 2))
                dashed.addLine(to: CGPoint(x: x, y: free.upperBound + origin.y))
                dashed.lineWidth = 1
                dashed.setLineDash([2, 3], count: 2, phase: 0)
                dashed.stroke()
            }
            context.restoreGState()
            if let text = block.freeLabel, let room = block.freeRoom {
                let label = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: block.measures.labelSize),
                                                                          .foregroundColor: Ink.faint])
                let size = label.size()
                if room.upperBound - room.lowerBound >= size.height {
                    label.draw(at: CGPoint(x: block.label.minX + origin.x, y: (room.lowerBound + room.upperBound) / 2 - size.height / 2 + origin.y))
                }
            }
            // The node: filled; hollow for a block nested in another's.
            if block.drawsNode {
                let dot = CGRect(x: x - 3.5, y: block.node.y + origin.y - 3.5, width: 7, height: 7)
                if mark.level > 0 {
                    let ring = UIBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                    ring.lineWidth = 1.5
                    color.setStroke()
                    ring.stroke()
                } else {
                    color.setFill()
                    UIBezierPath(ovalIn: dot).fill()
                }
            }
            // The time and length over the words — but for the row whose
            // time is written out, where it would say it twice.
            if !block.revealed {
                let font = UIFont.monospacedDigitSystemFont(ofSize: block.measures.labelSize, weight: .regular)
                let text = NSMutableAttributedString(string: mark.label, attributes: [.font: font, .foregroundColor: Ink.secondary])
                if let overlap = mark.overlap {
                    // Named, when there is room for it.
                    let room = (textContainers.first?.size.width ?? 320) - block.label.minX - 4
                    let full = NSAttributedString(string: mark.label + " · " + overlap, attributes: [.font: font]).size().width
                    text.append(NSAttributedString(string: " · " + (full <= room ? overlap : mark.overlapShort ?? overlap),
                                                   attributes: [.font: font, .foregroundColor: UIColor.systemOrange]))
                }
                text.draw(with: block.label.offsetBy(dx: origin.x, dy: origin.y), options: [.usesLineFragmentOrigin], context: nil)
            }
            // The time now, on the line, where it falls.
            if let nowMinutes, mark.start <= nowMinutes, nowMinutes < mark.end {
                let share = CGFloat(nowMinutes - mark.start) / CGFloat(max(1, mark.end - mark.start))
                let y = top + (max(top, end) - top) * share
                UIColor.systemRed.setFill()
                UIBezierPath(ovalIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)).fill()
            }
        }
    }

    /// The time block at a point in the container, and whether the point
    /// is at its line's end — to make it longer or shorter — or on its
    /// time — to move it.
    func timeBlockHit(at point: CGPoint) -> (block: PhoneTimeBlock, resizing: Bool)? {
        guard let storage = textStorage, PhoneTimeSlot.any(in: storage) else { return nil }
        for block in timeBlocks() {
            let grip = CGRect(x: block.node.x - 14, y: block.end - 12, width: 28, height: 24)
            if grip.contains(point) { return (block, true) }
            let font = UIFont.monospacedDigitSystemFont(ofSize: block.measures.labelSize, weight: .regular)
            let width = NSAttributedString(string: block.mark.label, attributes: [.font: font]).size().width
            if CGRect(x: block.label.minX - 6, y: block.label.minY - 6, width: width + 12, height: block.label.height + 12).contains(point) {
                return (block, false)
            }
        }
        return nil
    }
}

extension OutlineEditor {
    /// A time block held by its time, or its line's end, then dragged:
    /// moved, or made longer or shorter, five minutes at a time — that
    /// block alone.
    @objc func heldTimeBlock(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        switch gesture.state {
        case .began:
            // Where the finger went down: by the time the hold is sure, it
            // may have moved off the time it took hold of.
            let down = (gesture as? PictureHold)?.downPoint ?? point
            guard let hit = outlineLayout.timeBlockHit(at: CGPoint(x: down.x - textContainerInset.left, y: down.y - textContainerInset.top)) else { return }
            let all = rows
            let index = rowIndex(at: hit.block.head.location)
            guard let timeline = Timeline.find(all).first(where: { $0.blocks.contains { $0.row == index } }),
                  let block = timeline.blocks.firstIndex(where: { $0.row == index }) else { return }
            timeDrag = TimeDrag(timeline: timeline, index: block, resizing: hit.resizing, startY: down.y, original: all,
                                perMinute: hit.block.measures.perMinute, applied: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard var drag = timeDrag else { return }
            let minutes = Int(((point.y - drag.startY) / drag.perMinute / 5).rounded()) * 5
            guard minutes != drag.applied else { return }
            let changed = drag.timeline.moved(drag.index, by: minutes, resizing: drag.resizing, following: false,
                                              texts: drag.original.map(\.text))
            var after = rows
            for (row, text) in changed where row < after.count { after[row].text = text }
            inputDelegate?.textWillChange(self)
            replace(after, caret: isFirstResponder ? caret : nil, undoName: drag.resizing ? "Change Block's Length" : "Move Block")
            inputDelegate?.textDidChange(self)
            drag.applied = minutes
            timeDrag = drag
            UISelectionFeedbackGenerator().selectionChanged()
        default:
            timeDrag = nil
        }
    }

    struct TimeDrag {
        var timeline: Timeline
        var index: Int
        var resizing: Bool
        var startY: CGFloat
        var original: [Row]
        var perMinute: CGFloat
        var applied: Int
    }
}
