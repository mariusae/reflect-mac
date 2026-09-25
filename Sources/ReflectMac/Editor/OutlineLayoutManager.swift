import AppKit
import ReflectCore

/// Draws what the outline shows but does not type: bullets, checkboxes,
/// numbers, the bar beside a quote, rules, the ground under code, and rows
/// selected as rows.
final class OutlineLayoutManager: NSLayoutManager {
    weak var outlineView: OutlineTextView?

    /// What sits in the space before a row's text, and where.
    enum Handle {
        case bullet(folded: Bool)
        case task(done: Bool, round: Bool)
        case number(String)
        /// A faint bullet, for a row that shows none, under the pointer.
        case ghost
        case none
    }

    static func handle(for row: Row) -> Handle {
        if let task = row.task { return .task(done: task.isDone, round: row.marker == "+") }
        switch row.kind {
        case .bullet: return .bullet(folded: row.isFolded)
        case .ordered: return .number("\(row.number)\(row.marker)")
        default: return row.isFolded ? .bullet(folded: true) : .none
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let view = outlineView, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = storage.string as NSString
        let covered = text.paragraphRange(for: characters)
        let paragraphs = view.paragraphRanges
        let metrics = view.metrics
        let width = view.textContainer?.size.width ?? view.bounds.width

        if let selected = view.selectedRows {
            // Selected rows are one block, from the leftmost handle across.
            var block = NSRect.null
            var left = CGFloat.greatestFiniteMagnitude
            for index in selected where index < paragraphs.count {
                let row = OutlineText.style(storage, at: paragraphs[index].location).row
                left = min(left, origin.x + max(0, metrics.textIndent(for: row) - metrics.indent))
                if let frame = fullFrame(of: paragraphs[index], origin: origin) { block = block.union(frame) }
            }
            if !block.isNull {
                let rect = NSRect(x: left - 4, y: block.minY, width: origin.x + width - left + 4, height: block.height)
                let active = view.window?.isKeyWindow == true && view.window?.firstResponder === view
                (active ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28)
                        : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
        }

        for (index, paragraph) in paragraphs.enumerated()
        where NSIntersectionRange(paragraph, covered).length > 0 || paragraph.location == covered.location {
            let row = OutlineText.style(storage, at: paragraph.location).row
            guard let frame = frame(of: paragraph, origin: origin) else { continue }
            let indent = origin.x + metrics.textIndent(for: row)

            switch row.kind {
            case .code:
                NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
                let rect = NSRect(x: indent - 6, y: frame.minY - 2, width: origin.x + width - indent + 6, height: frame.height + 4)
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            case .quote:
                NSColor.tertiaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: indent - metrics.indent / 2 - 1.5, y: frame.minY, width: 3, height: frame.height),
                             xRadius: 1.5, yRadius: 1.5).fill()
            case .rule:
                NSColor.separatorColor.setFill()
                NSRect(x: indent, y: frame.midY.rounded(), width: origin.x + width - indent, height: 1).fill()
            default:
                break
            }

            var handle = Self.handle(for: row)
            // A row that shows no bullet is still a row: under the pointer,
            // it shows a ghost of one.
            if case .none = handle, index == view.hoveredRow, row.kind != .rule { handle = .ghost }
            drawHandle(handle, row: row, paragraph: paragraph, origin: origin, indent: indent)
            drawPictures(in: paragraph, origin: origin)
            drawFilePills(in: paragraph, origin: origin)
        }
    }

    /// Draws the pictures in a paragraph, each on the line its Markdown is on.
    private func drawPictures(in paragraph: NSRange, origin: NSPoint) {
        guard let storage = textStorage, let container = textContainers.first, let store = outlineView?.images else { return }
        var drawn = Set<Int>()
        storage.enumerateAttribute(.outlineImage, in: paragraph) { value, range, _ in
            guard value is ImageBox else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            var lineGlyphs = NSRange()
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
            guard !drawn.contains(lineGlyphs.location) else { return }
            drawn.insert(lineGlyphs.location)
            let characters = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            let indent = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            for (box, frame) in ImageLine.frames(in: storage, characters: characters, container: container,
                                                   fragment: fragment, indent: indent) {
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if let tweet = store.tweet(box.source) {
                    TweetCard.draw(tweet, in: rect, images: store)
                    continue
                }
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
                if let image = store.image(box.source) {
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSImageInterpolation.high.rawValue])
                } else {
                    NSColor.quaternaryLabelColor.withAlphaComponent(0.15).setFill()
                    rect.fill()
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

    /// The rectangle a paragraph's lines take, the space around them
    /// included, so that neighbours meet.
    private func fullFrame(of paragraph: NSRange, origin: NSPoint) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        return rect.isNull ? nil : rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The rectangle a paragraph's lines take.
    private func frame(of paragraph: NSRange, origin: NSPoint) -> NSRect? {
        let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var rect = NSRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            rect = rect.union(used)
        }
        guard !rect.isNull else { return nil }
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    private func drawHandle(_ handle: Handle, row: Row, paragraph: NSRange, origin: NSPoint, indent: CGFloat) {
        guard let view = outlineView else { return }
        let glyph = glyphIndexForCharacter(at: paragraph.location)
        guard glyph < numberOfGlyphs else { return }
        let baseline = origin.y + self.baseline(ofLineAt: glyph, font: view.metrics.font(for: row))
        let font = view.metrics.font(for: row)
        let center = NSPoint(x: indent - view.metrics.indent / 2, y: baseline - font.xHeight / 2)

        switch handle {
        case .none:
            break
        case .ghost:
            // Hollow and faint: a hint of the row, not a bullet.
            let dot = max(5, (view.metrics.fontSize * 0.38).rounded())
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
            ring.lineWidth = 1
            NSColor.tertiaryLabelColor.setStroke()
            ring.stroke()
        case .bullet(let folded):
            if folded {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
                let ring = font.pointSize * 0.95
                NSBezierPath(ovalIn: NSRect(x: center.x - ring / 2, y: center.y - ring / 2, width: ring, height: ring)).fill()
            }
            NSColor.secondaryLabelColor.setFill()
            let dot = max(4, (font.pointSize * 0.34).rounded())
            NSBezierPath(ovalIn: NSRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot)).fill()
        case .task(let done, let round):
            let name = round ? (done ? "checkmark.circle.fill" : "circle") : (done ? "checkmark.square.fill" : "square")
            let configuration = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.95, weight: .regular)
                .applying(.init(paletteColors: [done ? .controlAccentColor : .secondaryLabelColor]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: done ? "Done" : "To do")?
                .withSymbolConfiguration(configuration) else { return }
            let size = image.size
            image.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        case .number(let label):
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let text = NSAttributedString(string: label, attributes: attributes)
            let size = text.size()
            let ascent = (attributes[.font] as! NSFont).ascender
            text.draw(at: NSPoint(x: indent - 6 - size.width, y: baseline - ascent))
        }
    }

    /// The baseline of the line a glyph is on, in the text container.
    ///
    /// From a glyph shown on the line when there is one. A line with none —
    /// a row with nothing typed yet, or only hidden markup and pictures —
    /// has its baseline worked out from the type: as far above the foot of
    /// its text as the font descends, where the line's height multiple puts
    /// its extra space above.
    func baseline(ofLineAt glyph: Int, font: NSFont) -> CGFloat {
        guard numberOfGlyphs > 0 else { return font.ascender }
        let glyph = min(glyph, numberOfGlyphs - 1)
        var lineGlyphs = NSRange()
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        if let storage = textStorage {
            let text = storage.string as NSString
            for index in lineGlyphs.location..<NSMaxRange(lineGlyphs) where propertyForGlyph(at: index).isEmpty {
                let character = characterIndexForGlyph(at: index)
                guard character < text.length else { continue }
                let unit = text.character(at: character)
                if unit == 0x0a || unit == 0x2028 { continue }
                return fragment.minY + location(forGlyphAt: index).y
            }
        }
        let descent = defaultLineHeight(for: font) - defaultBaselineOffset(for: font)
        let character = characterIndexForGlyph(at: glyph)
        if let storage = textStorage, let container = textContainers.first,
           !ImageLine.pictures(in: storage, characters: characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil),
                               container: container).isEmpty {
            // Pictures hang below the line's text, which is at its top.
            let multiple = (storage.attribute(.paragraphStyle, at: min(character, storage.length - 1), effectiveRange: nil)
                as? NSParagraphStyle)?.lineHeightMultiple ?? 1
            return used.minY + defaultLineHeight(for: font) * max(multiple, 1) - descent
        }
        return used.maxY - descent
    }

    /// The picture at a point in the text view, if any.
    func pictureHit(at point: NSPoint, origin: NSPoint) -> ImageBox? {
        pictureFrame(at: point, origin: origin)?.box
    }

    /// The picture at a point in the text view, and where it is drawn there.
    func pictureFrame(at point: NSPoint, origin: NSPoint) -> (box: ImageBox, frame: NSRect)? {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = glyphIndex(for: inContainer, in: container)
        guard glyph < numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        guard fragment.contains(inContainer) else { return nil }
        let characters = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let indent = (storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
        return ImageLine.frames(in: storage, characters: characters, container: container, fragment: fragment, indent: indent)
            .first { $0.frame.contains(inContainer) }
            .map { ($0.box, $0.frame.offsetBy(dx: origin.x, dy: origin.y)) }
    }

    /// The row whose handle is at a point in the text view, if any.
    func handleHit(at point: NSPoint, origin: NSPoint) -> Int? {
        guard let view = outlineView, let storage = textStorage else { return nil }
        for (index, paragraph) in view.paragraphRanges.enumerated() {
            let row = OutlineText.style(storage, at: paragraph.location).row
            if case .none = Self.handle(for: row), index != view.hoveredRow { continue }
            let glyph = glyphIndexForCharacter(at: paragraph.location)
            guard glyph < numberOfGlyphs else { break }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let indent = origin.x + view.metrics.textIndent(for: row)
            let hit = NSRect(x: indent - view.metrics.indent, y: line.minY, width: view.metrics.indent, height: line.height)
            if hit.contains(point) { return index }
            if line.minY > point.y { break }
        }
        return nil
    }
}
