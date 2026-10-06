import UIKit
import ReflectCore

extension NSAttributedString.Key {
    /// A row of a time block, as a `PhoneTimeSlot`.
    static let prismTimeSlot = NSAttributedString.Key("PrismTimeSlot")
}

/// A row's place in a time block: how far it is set in, how tall its block
/// stands, and the free time after it.
final class PhoneTimeSlot: NSObject {
    /// Of the type: how far the times push the rows in, and how tall a minute is.
    struct Measures: Equatable {
        var gutter: CGFloat
        var perMinute: CGFloat
        var pad: CGFloat
        var labelSize: CGFloat
        var twelveHour: Bool

        init(_ metrics: PhoneMetrics) {
            let row = metrics.lineHeight * metrics.size + metrics.rowGap
            // An hour as tall as two and a half rows: a quarter of one, a row.
            perMinute = row * 2.5 / 60
            pad = round(metrics.size * 0.3)
            labelSize = round(metrics.size * 0.72)
            twelveHour = TimeStamp.localeIsTwelveHour
            let label = NSAttributedString(string: twelveHour ? "12:30 PM" : "23:30",
                                           attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: labelSize, weight: .medium)])
            gutter = ceil(label.size().width) + round(metrics.size * 0.7)
        }
    }

    let index: Int
    let back: Int
    let isLast: Bool
    let stamp: TimeStamp?
    let revealed: Bool
    let start: Int
    let end: Int
    let free: Int
    let isLastBlock: Bool
    let done: Bool
    let measures: Measures

    init(index: Int, back: Int, isLast: Bool, stamp: TimeStamp?, revealed: Bool, start: Int, end: Int, free: Int,
         isLastBlock: Bool, done: Bool, measures: Measures) {
        self.index = index
        self.back = back
        self.isLast = isLast
        self.stamp = stamp
        self.revealed = revealed
        self.start = start
        self.end = end
        self.free = free
        self.isLastBlock = isLastBlock
        self.done = done
        self.measures = measures
    }

    var cardHeight: CGFloat { (CGFloat(max(end - start, 5)) * measures.perMinute).rounded() }
    var freeHeight: CGFloat {
        if isLastBlock { return measures.pad * 2 }
        return free == 0 ? 0 : (CGFloat(min(free, 60)) * measures.perMinute).rounded() + measures.pad
    }
    /// The room above the block's first row.
    var spaceBefore: CGFloat { back != 0 ? 0 : index == 0 ? measures.pad * 2 : measures.pad }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? PhoneTimeSlot else { return false }
        return index == other.index && back == other.back && isLast == other.isLast && stamp == other.stamp
            && revealed == other.revealed && start == other.start && end == other.end && free == other.free
            && isLastBlock == other.isLastBlock && done == other.done && measures == other.measures
    }

    override var hash: Int { var h = Hasher(); h.combine(index); h.combine(back); h.combine(start); h.combine(end); return h.finalize() }

    /// The slots of the rows of a text's timelines, by where their paragraphs start.
    static func slots(_ storage: NSTextStorage, metrics: PhoneMetrics, caret: Int?) -> [Int: PhoneTimeSlot] {
        let text = storage.mutableString
        let paragraphs = OutlineText.paragraphs(text)
        guard paragraphs.count >= 2 else { return [:] }
        var depths: [Int] = [], texts: [String] = [], items: [Bool] = [], tasks: [Row.Task?] = []
        for paragraph in paragraphs {
            let row = OutlineText.style(storage, at: paragraph.location).row
            depths.append(row.depth)
            items.append(row.kind.isListItem)
            tasks.append(row.task)
            texts.append(text.substring(with: NSRange(location: paragraph.location, length: min(paragraph.length, 48))))
        }
        let timelines = Timeline.find(depths: depths, texts: texts, isListItem: items)
        guard !timelines.isEmpty else { return [:] }
        let measures = Measures(metrics)
        var found: [Int: PhoneTimeSlot] = [:]
        for timeline in timelines {
            for (n, block) in timeline.blocks.enumerated() {
                let head = paragraphs[block.row]
                let revealed = caret.map { $0 >= head.location && $0 < NSMaxRange(head) } ?? false
                for row in block.rows {
                    found[paragraphs[row].location] = PhoneTimeSlot(
                        index: n, back: row - block.row, isLast: row == block.rows.upperBound - 1,
                        stamp: row == block.row ? block.stamp : nil, revealed: row == block.row && revealed,
                        start: block.start, end: block.end, free: block.free, isLastBlock: n == timeline.blocks.count - 1,
                        done: tasks[block.row]?.isDone == true, measures: measures)
                }
            }
        }
        return found
    }

    /// Whether any row of a text is in a time block.
    static func any(in storage: NSTextStorage) -> Bool {
        var found = false
        storage.enumerateAttribute(.prismTimeSlot, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    static func gutter(_ storage: NSTextStorage, at location: Int) -> CGFloat {
        guard location < storage.length else { return 0 }
        return (storage.attribute(.prismTimeSlot, at: location, effectiveRange: nil) as? PhoneTimeSlot)?.measures.gutter ?? 0
    }
}

/// Where a time block is, in the text container.
struct PhoneTimeBlock {
    var head: NSRange
    var slot: PhoneTimeSlot
    var card: CGRect
    var free: CGRect
    var gutter: CGRect
    var contentBottom: CGFloat
    var baseline: CGFloat
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

    /// The extra a time block's last line takes: down as far as the block
    /// lasts, and the free time after it. Nil for a line that is no such.
    func timeBlockFoot(characters: NSRange, fragment: CGRect, line: NSRange) -> CGFloat? {
        guard let storage = textStorage, characters.length > 0 else { return nil }
        let text = plainText
        // Back over the next row's hidden start, to this row's line break.
        var end = NSMaxRange(characters) - 1
        while end > characters.location, text.character(at: end) != 0x0A,
              storage.attribute(.prismHidden, at: end, effectiveRange: nil) != nil { end -= 1 }
        guard text.character(at: end) == 0x0A,
              let slot = storage.attribute(.prismTimeSlot, at: end, effectiveRange: nil) as? PhoneTimeSlot, slot.isLast else { return nil }
        var start = text.paragraphRange(for: NSRange(location: end, length: 0)).location
        for _ in 0..<slot.back where start > 0 {
            start = text.paragraphRange(for: NSRange(location: start - 1, length: 0)).location
        }
        let head = text.paragraphRange(for: NSRange(location: start, length: 0))
        let glyph = glyphIndexForCharacter(at: firstShown(in: head))
        let top = glyph >= line.location
            ? fragment.minY + slot.spaceBefore
            : lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true).minY + slot.spaceBefore
        let cardBottom = max(fragment.maxY, top + slot.cardHeight)
        return cardBottom + slot.freeHeight - fragment.maxY
    }

    /// The time blocks among some characters' rows, with where they are.
    func timeBlocks(in characters: NSRange? = nil) -> [PhoneTimeBlock] {
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return [] }
        let text = plainText
        var location = characters?.location ?? 0
        let limit = characters.map { NSMaxRange($0) } ?? text.length
        // From the head of the block the first is in.
        if location < text.length, let slot = storage.attribute(.prismTimeSlot, at: location, effectiveRange: nil) as? PhoneTimeSlot {
            location = text.paragraphRange(for: NSRange(location: location, length: 0)).location
            for _ in 0..<slot.back where location > 0 {
                location = text.paragraphRange(for: NSRange(location: location - 1, length: 0)).location
            }
        }
        var found: [PhoneTimeBlock] = []
        while location < min(limit, text.length) {
            let head = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard let slot = storage.attribute(.prismTimeSlot, at: head.location, effectiveRange: nil) as? PhoneTimeSlot, slot.back == 0 else {
                location = NSMaxRange(head)
                continue
            }
            var last = head
            while NSMaxRange(last) < text.length,
                  !((storage.attribute(.prismTimeSlot, at: last.location, effectiveRange: nil) as? PhoneTimeSlot)?.isLast ?? true) {
                last = text.paragraphRange(for: NSRange(location: NSMaxRange(last), length: 0))
            }
            let headGlyph = glyphIndexForCharacter(at: firstShown(in: head))
            let lastGlyph = glyphIndexForCharacter(at: NSMaxRange(last) - 1)
            guard headGlyph < numberOfGlyphs, lastGlyph < numberOfGlyphs else { break }
            let headFragment = lineFragmentRect(forGlyphAt: headGlyph, effectiveRange: nil)
            let footFragment = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let footUsed = lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let top = headFragment.minY + slot.spaceBefore
            let cardBottom = footFragment.maxY - slot.freeHeight
            let row = OutlineText.style(storage, at: head.location).row
            let left = metrics.textIndent(for: row) + slot.measures.gutter - metrics.indent
            let card = CGRect(x: left - 2, y: top - slot.measures.pad, width: container.size.width - left - 2,
                              height: cardBottom - top + slot.measures.pad)
            let font = metrics.font(for: row)
            found.append(PhoneTimeBlock(
                head: head, slot: slot, card: card,
                free: CGRect(x: card.minX, y: card.maxY, width: card.width, height: slot.freeHeight),
                gutter: CGRect(x: card.minX - slot.measures.gutter, y: card.minY, width: slot.measures.gutter, height: card.height),
                contentBottom: footUsed.minY + min(footUsed.height, ceil(metrics.lineHeight * metrics.size)),
                baseline: headFragment.minY + self.location(forGlyphAt: headGlyph).y))
            _ = font
            location = NSMaxRange(last)
        }
        return found
    }

    /// Draws time blocks: their cards, the times at their left, the free
    /// time between and, on today's page, the time now.
    func drawTimeBlocks(_ blocks: [PhoneTimeBlock], at origin: CGPoint, today: Bool) {
        let now = today ? Calendar.current.dateComponents([.hour, .minute], from: Date()) : nil
        let nowMinutes = now.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) }
        for block in blocks {
            let slot = block.slot
            let isNow = nowMinutes.map { $0 >= slot.start && $0 < slot.end } ?? false
            let card = block.card.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: 1)
            let path = UIBezierPath(roundedRect: card, cornerRadius: 8)
            (slot.done ? Ink.text.withAlphaComponent(0.04) : Ink.accent.withAlphaComponent(isNow ? 0.18 : 0.1)).setFill()
            path.fill()
            if let context = UIGraphicsGetCurrentContext() {
                context.saveGState()
                path.addClip()
                (slot.done ? Ink.faint : Ink.accent.withAlphaComponent(isNow ? 0.95 : 0.65)).setFill()
                UIRectFill(CGRect(x: card.minX, y: card.minY, width: 3, height: card.height))
                context.restoreGState()
            }
            let font = UIFont.monospacedDigitSystemFont(ofSize: slot.measures.labelSize, weight: .medium)
            let baseline = block.baseline + origin.y
            func label(_ minutes: Int, y: CGFloat, color: UIColor, onBaseline: Bool) {
                let text = NSAttributedString(string: TimeStamp.shown(minutes, twelveHour: slot.measures.twelveHour),
                                              attributes: [.font: font, .foregroundColor: color])
                let size = text.size()
                text.draw(at: CGPoint(x: card.minX - 6 - size.width, y: onBaseline ? y - font.ascender : y - size.height / 2))
            }
            label(slot.start, y: baseline, color: slot.done ? Ink.faint : Ink.secondary, onBaseline: true)
            if slot.free > 0 || slot.isLastBlock, card.maxY - baseline > font.pointSize * 2.6 {
                label(slot.end, y: card.maxY - font.capHeight / 2 - 3, color: Ink.faint, onBaseline: false)
            }
            let length = NSAttributedString(string: TimeStamp.length(slot.end - slot.start), attributes: [.font: font, .foregroundColor: Ink.faint])
            let lengthSize = length.size()
            length.draw(at: CGPoint(x: card.maxX - 8 - lengthSize.width, y: baseline - font.ascender))
            let free = block.free.offsetBy(dx: origin.x, dy: origin.y)
            if slot.free > 0, free.height >= font.pointSize + 6 {
                let text = NSAttributedString(string: "\(TimeStamp.length(slot.free)) free",
                                              attributes: [.font: UIFont.systemFont(ofSize: slot.measures.labelSize), .foregroundColor: Ink.faint])
                let size = text.size()
                text.draw(at: CGPoint(x: card.minX + 10, y: free.midY - size.height / 2))
            }
            if let nowMinutes {
                var y: CGFloat?
                if isNow {
                    y = card.minY + card.height * CGFloat(nowMinutes - slot.start) / CGFloat(max(1, slot.end - slot.start))
                } else if slot.free > 0, nowMinutes >= slot.end, nowMinutes < slot.end + slot.free {
                    y = free.minY + free.height * CGFloat(nowMinutes - slot.end) / CGFloat(slot.free)
                }
                if let y {
                    UIColor.systemRed.setFill()
                    UIRectFill(CGRect(x: card.minX - 4, y: y.rounded() - 0.75, width: card.maxX - card.minX + 4, height: 1.5))
                    UIBezierPath(ovalIn: CGRect(x: card.minX - 8, y: y - 4, width: 8, height: 8)).fill()
                }
            }
        }
    }

    /// The time block at a point in the container, and whether the point
    /// is on its foot — to make it longer or shorter — or on it, away from
    /// its words — to move it.
    func timeBlockHit(at point: CGPoint) -> (block: PhoneTimeBlock, resizing: Bool)? {
        guard let storage = textStorage, PhoneTimeSlot.any(in: storage) else { return nil }
        for block in timeBlocks() {
            let foot = CGRect(x: block.card.minX, y: block.card.maxY - 10, width: block.card.width, height: 20)
            if foot.contains(point) { return (block, true) }
            if block.gutter.contains(point) { return (block, false) }
            if block.card.contains(point), point.y > block.contentBottom + 2 { return (block, false) }
        }
        return nil
    }
}

extension OutlineEditor {
    /// A time block held by its times, its empty part or its foot, then
    /// dragged: moved, or made longer or shorter, five minutes at a time —
    /// the blocks after it with it.
    @objc func heldTimeBlock(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        switch gesture.state {
        case .began:
            guard let hit = outlineLayout.timeBlockHit(at: inContainer) else { return }
            let all = rows
            let index = rowIndex(at: hit.block.head.location)
            guard let timeline = Timeline.find(all).first(where: { $0.blocks.contains { $0.row == index } }),
                  let block = timeline.blocks.firstIndex(where: { $0.row == index }) else { return }
            timeDrag = TimeDrag(timeline: timeline, index: block, resizing: hit.resizing, startY: point.y, original: all,
                                perMinute: hit.block.slot.measures.perMinute, applied: 0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard var drag = timeDrag else { return }
            let minutes = Int(((point.y - drag.startY) / drag.perMinute / 5).rounded()) * 5
            guard minutes != drag.applied else { return }
            let changed = drag.timeline.moved(drag.index, by: minutes, resizing: drag.resizing, alone: false, texts: drag.original.map(\.text))
            var after = rows
            for (row, text) in changed where row < after.count { after[row].text = text }
            replace(after, caret: isFirstResponder ? caret : nil, undoName: drag.resizing ? "Change Block's Length" : "Move Block")
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
