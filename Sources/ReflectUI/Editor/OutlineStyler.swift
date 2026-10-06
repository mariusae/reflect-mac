import AppKit
import ReflectCore

/// The type and measures of the outline, from the Typography settings.
package struct OutlineMetrics {
    package var typography: Typography

    package init(typography: Typography = .current) {
        self.typography = typography
    }

    package init(fontSize: CGFloat) {
        var typography = Typography.current
        typography.size = fontSize
        self.typography = typography
    }

    package var fontSize: CGFloat { typography.size }
    /// How far each level of the outline is indented.
    package var indent: CGFloat { round(fontSize * typography.indent) }
    package var body: NSFont { Typography.font(typography.bodyFamily, face: typography.bodyFace, size: fontSize) }
    package var code: NSFont {
        Typography.font(typography.monospaceFamily, face: typography.monospaceFace, size: round(fontSize * 0.88), monospaced: true)
    }
    package var lineHeightMultiple: CGFloat { typography.lineHeight }
    /// The space after each row.
    package var rowSpacing: CGFloat { round(fontSize * typography.rowSpacing) }
    package var columnWidth: CGFloat { typography.lineLength }

    package func heading(_ level: Int) -> NSFont {
        // The first level at the scale set; the rest step down to body size.
        let scale = typography.headingScale
        let (factor, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (scale, .bold)
        case 2: (1 + (scale - 1) / 2, .bold)
        case 3: (1 + (scale - 1) / 5, .semibold)
        default: (1, .semibold)
        }
        return typography.headingFont(size: round(fontSize * factor), weight: weight)
    }

    package func font(for row: Row) -> NSFont {
        switch row.kind {
        case .heading(let level): heading(level)
        case .code: code
        default: body
        }
    }

    /// Where a row's text starts: one step in for each level, whether or
    /// not it has a bullet — a list item's marker hangs in the space before
    /// it — so taking a bullet off leaves the text where it was.
    package func textIndent(for row: Row) -> CGFloat {
        indent * CGFloat(row.depth + 1)
    }
}

/// Styles the outline as it changes: every paragraph from its row, and the
/// inline Markdown in it.
///
/// Only attributes are touched, never characters, so what is on screen is
/// what is written to disk. It also keeps each paragraph to one row: when an
/// edit joins two, the row that was there first wins.
package final class OutlineStyler: NSObject, NSTextStorageDelegate {
    package var metrics: OutlineMetrics
    /// Rows that were folded inside a row an edit swallowed, with where they
    /// belong; the editor puts them back once the edit is done.
    package var orphans: [(location: Int, rows: [Row])] = []
    /// Told of every change to the characters, before anything else hears
    /// of it.
    package var onCharactersEdited: (() -> Void)?
    /// Where pictures come from; without it, images stay as Markdown.
    package var images: ImageStore?
    /// Where the caret is: a shortened web address it is in is shown whole.
    package var caret: Int?
    /// The row the caret is in: a time block's time is written out there.
    package var caretRow: Int?
    /// The time blocks' slots, by where their paragraphs start: worked out
    /// before each styling.
    private var slots: [Int: TimeSlot] = [:]

    package init(metrics: OutlineMetrics) {
        self.metrics = metrics
    }

    // Styling happens once an edit is processed: changing attributes before
    // then widens the edit, and the layout manager moves a caret inside an
    // edit to its end.
    package func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        if mask.contains(.editedCharacters) { onCharactersEdited?() }
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        var range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: edited.length))
        // The row after is spaced by this one, so it is styled again too.
        if NSMaxRange(range) < text.length {
            range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        if mask.contains(.editedCharacters) { unify(storage, in: range, inserted: edited) }
        slots = timeSlots(storage)
        style(storage, in: range)
        // A row edited can make or unmake its list a timeline, or move
        // the blocks after it: those whose slots changed are styled again.
        restyleChangedSlots(storage, besides: range)
    }

    /// Styles again the rows of time blocks that changed — the caret moved
    /// into or out of one, or the type changed.
    package func restyleTimelines(_ storage: NSTextStorage) {
        guard storage.length > 0 else { return }
        slots = timeSlots(storage)
        storage.beginEditing()
        restyleChangedSlots(storage, besides: NSRange(location: 0, length: 0))
        storage.endEditing()
    }

    private func restyleChangedSlots(_ storage: NSTextStorage, besides done: NSRange) {
        let text = storage.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            if NSIntersectionRange(paragraph, done).length > 0 { continue }
            let current = storage.attribute(.outlineTimeSlot, at: paragraph.location, effectiveRange: nil) as? TimeSlot
            let wanted = slots[paragraph.location]
            if current == nil && wanted == nil { continue }
            if let current, let wanted, current.isEqual(wanted) { continue }
            style(storage, in: paragraph)
        }
    }

    /// The slot of each paragraph in a timeline, by where it starts.
    private func timeSlots(_ storage: NSTextStorage) -> [Int: TimeSlot] {
        let text = storage.string as NSString
        let paragraphs = OutlineText.paragraphs(text)
        guard paragraphs.count >= 2 else { return [:] }
        var depths: [Int] = [], texts: [String] = [], items: [Bool] = [], tasks: [Row.Task?] = []
        depths.reserveCapacity(paragraphs.count)
        for paragraph in paragraphs {
            let row = OutlineText.style(storage, at: paragraph.location).row
            depths.append(row.depth)
            items.append(row.kind.isListItem)
            tasks.append(row.task)
            texts.append(text.substring(with: NSRange(location: paragraph.location, length: min(paragraph.length, 48))))
        }
        let timelines = Timeline.find(depths: depths, texts: texts, isListItem: items)
        guard !timelines.isEmpty else { return [:] }
        let measures = TimeSlot.Measures(metrics)
        var found: [Int: TimeSlot] = [:]
        for timeline in timelines {
            for (n, block) in timeline.blocks.enumerated() {
                for row in block.rows {
                    let head = row == block.row
                    found[paragraphs[row].location] = TimeSlot(
                        index: n, back: row - block.row, isLast: row == block.rows.upperBound - 1,
                        stamp: head ? block.stamp : nil, revealed: head && caretRow == block.row,
                        start: block.start, end: block.end, free: block.free, isLastBlock: n == timeline.blocks.count - 1,
                        done: tasks[block.row]?.isDone == true, measures: measures)
                }
            }
        }
        return found
    }

    /// Styles the paragraph a character is in again.
    package func restyle(_ storage: NSTextStorage, paragraphAt location: Int) {
        guard storage.length > 0 else { return }
        slots = timeSlots(storage)
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        storage.beginEditing()
        style(storage, in: paragraph)
        storage.endEditing()
    }

    package func styleAll(_ storage: NSTextStorage) {
        slots = timeSlots(storage)
        storage.beginEditing()
        style(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    // MARK: One row a paragraph

    private func unify(_ storage: NSTextStorage, in range: NSRange, inserted: NSRange) {
        let text = storage.string as NSString
        for paragraph in OutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: paragraph.location + range.location, length: paragraph.length)
            var styles: [RowStyle] = []
            var winner: RowStyle?
            storage.enumerateAttribute(.outlineRow, in: paragraph) { value, run, _ in
                guard let style = value as? RowStyle else { return }
                if !styles.contains(where: { $0 === style }) { styles.append(style) }
                // What was typed takes the row it was typed into, not the
                // other way round.
                let typed = NSIntersectionRange(run, inserted).length == run.length && inserted.length > 0
                if winner == nil && !typed { winner = style }
            }
            let style = winner ?? styles.last ?? RowStyle(.blank)
            guard styles.count > 1 || styles.first !== style else { continue }
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            for lost in styles where lost !== style && lost.row.isFolded {
                let rows = lost.row.folded.map { child in
                    var child = child
                    child.depth += lost.row.depth
                    return child
                }
                orphans.append((paragraph.location, rows))
            }
        }
    }

    // MARK: Styling

    private func style(_ storage: NSTextStorage, in range: NSRange) {
        let text = storage.string as NSString
        for paragraph in OutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: paragraph.location + range.location, length: paragraph.length)
            let row = OutlineText.style(storage, at: paragraph.location).row
            let previous = paragraph.location > 0 ? OutlineText.style(storage, at: paragraph.location - 1).row : nil
            let style = storage.attribute(.outlineRow, at: paragraph.location, effectiveRange: nil) as Any
            let slot = slots[paragraph.location]
            var attributes = attributes(for: row, after: previous)
            if let slot, let paragraphStyle = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                // Clear of the times, at the left.
                paragraphStyle.firstLineHeadIndent += slot.measures.gutter
                paragraphStyle.headIndent += slot.measures.gutter
                // Room above the first block's card, and between blocks.
                if slot.back == 0 { paragraphStyle.paragraphSpacingBefore = slot.index == 0 ? slot.measures.pad * 2 : slot.measures.pad }
                attributes[.paragraphStyle] = paragraphStyle
            }
            storage.setAttributes(attributes, range: paragraph)
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            if let slot { storage.addAttribute(.outlineTimeSlot, value: slot, range: paragraph) }
            if case .code = row.kind {
                CodeBlock.dimFences(storage, in: paragraph, ink: metrics.typography.ink)
            } else if case .rule = row.kind {} else {
                // In a heading, links are only coloured: a pill would crowd its large type.
                var inHeading = false
                if case .heading = row.kind { inHeading = true }
                InlineMarkdown.style(storage, in: paragraph, base: metrics.font(for: row), done: row.task?.isDone == true,
                                     images: images, caret: caret, pills: !inHeading, typography: metrics.typography)
            }
            // A block's time is told at its left; written out only where the caret is.
            if let slot, let stamp = slot.stamp, !slot.revealed, stamp.fullRange.length < paragraph.length {
                storage.addAttribute(.outlineHidden, value: true,
                                     range: NSRange(location: paragraph.location, length: stamp.fullRange.length))
            }
            // A character the font set here lacks still needs a font that has it.
            storage.fixAttributes(in: paragraph)
        }
    }

    /// How a row looks, and how far it stands from the row before.
    ///
    /// Rows are spaced evenly, whatever blank lines the Markdown has between
    /// them: in an outline they mean nothing, and a list written loose here
    /// and tight there would read unevenly. A heading has room above it, and
    /// prose keeps the blank line between one paragraph and the next.
    package func attributes(for row: Row, after previous: Row?) -> [NSAttributedString.Key: Any] {
        let font = metrics.font(for: row)
        let paragraph = NSMutableParagraphStyle()
        let indent = metrics.textIndent(for: row)
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineHeightMultiple = metrics.lineHeightMultiple
        paragraph.paragraphSpacing = metrics.rowSpacing
        var before: CGFloat = 0
        if case .heading = row.kind {
            before = round(metrics.fontSize * 0.8)
        } else if row.kind == .paragraph, previous?.kind == .paragraph, !row.gap.isEmpty {
            before = round(metrics.fontSize * 0.45)
        }
        paragraph.paragraphSpacingBefore = previous == nil ? 0 : before
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
            .foregroundColor: metrics.typography.ink.text,
        ]
        let ink = metrics.typography.ink
        switch row.kind {
        case .quote:
            attributes[.foregroundColor] = ink.secondary
        case .rule:
            // The rule is drawn; its dashes are only there to be edited.
            attributes[.foregroundColor] = NSColor.clear
        case .code:
            attributes[.foregroundColor] = ink.text
        default:
            break
        }
        if row.task?.isDone == true {
            attributes[.foregroundColor] = ink.secondary
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = ink.tertiary
        }
        return attributes
    }
}

extension NSAttributedString.Key {
    /// Markup not shown: its characters are kept, but draw nothing.
    package static let outlineHidden = NSAttributedString.Key("ReflectOutlineHidden")
    /// A typed arrow's last character: drawn as the arrow it makes.
    package static let outlineArrow = NSAttributedString.Key("ReflectOutlineArrow")
    /// A row of a time block, as a `TimeSlot`.
    package static let outlineTimeSlot = NSAttributedString.Key("ReflectOutlineTimeSlot")
}

/// A row's place in a time block: how far it is set in, how tall its block
/// stands, and the free time after it.
package final class TimeSlot: NSObject {
    /// Of the type: how far the times push the rows in, and how tall a
    /// minute is.
    package struct Measures: Equatable {
        package var gutter: CGFloat
        package var perMinute: CGFloat
        package var row: CGFloat
        package var pad: CGFloat
        package var labelSize: CGFloat
        package var twelveHour: Bool

        package init(_ metrics: OutlineMetrics) {
            let body = metrics.body
            let line = ceil(NSLayoutManager().defaultLineHeight(for: body) * max(1, metrics.lineHeightMultiple))
            row = line + metrics.rowSpacing
            // An hour as tall as two and a half rows: a quarter of one, a row.
            perMinute = row * 2.5 / 60
            pad = round(metrics.fontSize * 0.3)
            labelSize = round(metrics.fontSize * 0.74)
            twelveHour = TimeStamp.localeIsTwelveHour
            let label = NSAttributedString(string: twelveHour ? "12:30 PM" : "23:30",
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: labelSize, weight: .medium)])
            gutter = ceil(label.size().width) + round(metrics.fontSize * 0.9)
        }
    }

    /// Which block of its timeline.
    package let index: Int
    /// How many rows back the block's first is: none for the first.
    package let back: Int
    /// Whether the block's last row: its foot reaches down to its end.
    package let isLast: Bool
    /// The first row's time, as written.
    package let stamp: TimeStamp?
    /// Whether the time is written out: the caret is in the row.
    package let revealed: Bool
    package let start: Int
    package let end: Int
    package let free: Int
    package let isLastBlock: Bool
    package let done: Bool
    package let measures: Measures

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

    /// How tall the block's card is, by how long it lasts.
    package var cardHeight: CGFloat { (CGFloat(max(end - start, 5)) * measures.perMinute).rounded() }
    /// How tall the free time after it is: as long as it is, up to an hour.
    package var freeHeight: CGFloat {
        // The last: clear of the row after.
        if isLastBlock { return measures.pad * 2 }
        return free == 0 ? 0 : (CGFloat(min(free, 60)) * measures.perMinute).rounded() + measures.pad
    }

    package override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TimeSlot else { return false }
        return index == other.index && back == other.back && isLast == other.isLast && stamp == other.stamp
            && revealed == other.revealed && start == other.start && end == other.end && free == other.free
            && isLastBlock == other.isLastBlock && done == other.done && measures == other.measures
    }

    package override var hash: Int { var h = Hasher(); h.combine(index); h.combine(back); h.combine(start); h.combine(end); return h.finalize() }
}

/// A code block's fences: the lines that open and close it, there to be
/// edited but not to be read.
package enum CodeBlock {
    package static func dimFences(_ storage: NSTextStorage, in paragraph: NSRange, ink: TextInk = .system) {
        let text = storage.string as NSString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        var lines: [NSRange] = []
        var start = body.location
        while start <= NSMaxRange(body) {
            let rest = NSRange(location: start, length: NSMaxRange(body) - start)
            let found = text.range(of: OutlineText.lineSeparator, options: .literal, range: rest)
            let end = found.location == NSNotFound ? NSMaxRange(body) : found.location
            lines.append(NSRange(location: start, length: end - start))
            if found.location == NSNotFound { break }
            start = found.location + found.length
        }
        for line in [lines.first, lines.count > 1 ? lines.last : nil].compactMap({ $0 })
        where OutlineTextView.isFence(text.substring(with: line)) {
            storage.addAttribute(.foregroundColor, value: ink.tertiary, range: line)
        }
    }

    /// The language a block's opening fence names, if any.
    package static func language(of text: String) -> String? {
        guard let first = text.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}")).first,
              OutlineTextView.isFence(first) else { return nil }
        let name = first.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "`" || $0 == "~" })
        return name.isEmpty ? nil : String(name)
    }
}

/// Inline Markdown, shown as what it means, its markup hidden.
package enum InlineMarkdown {
    package static func style(_ storage: NSTextStorage, in range: NSRange, base: NSFont, done: Bool, images: ImageStore?, caret: Int? = nil,
                      pills: Bool = true, typography: Typography = .defaults) {
        let text = storage.string as NSString
        let body = NSRange(location: range.location, length: max(0, range.length - 1))
        func font(at location: Int) -> NSFont {
            storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? base
        }
        // A link alone in its row — a page, a podcast, a paper, a repository,
        // a Google file — shows its card below it; among words, its pill.
        let rowText = text.substring(with: body).trimmingCharacters(in: .whitespaces)
        func markRichCard(_ target: String, text linkText: String?) {
            guard let images, let span = InlineMarkup.spans(in: text, range: body).first(where: {
                switch $0.kind { case .link(let t), .url(let t): t == target; default: false }
            }), text.substring(with: span.range) == rowText, let card = images.rich(target, text: linkText) else { return }
            let face = RichCardFace(card, linkText: linkText)
            storage.addAttribute(.outlineImage, value: ImageBox(source: target, size: RichCard.size(of: face), isCard: true),
                                 range: NSRange(location: span.range.location, length: 1))
        }
        let found = InlineMarkup.spans(in: text, range: body)
        let resolved = images?.resolve(found) ?? found.map(unshown)
        let carousels = images.map { Carousel.groups(in: resolved, text: text, images: $0) } ?? [:]
        for span in resolved {
            let content = span.content
            switch span.kind {
            case .strong:
                storage.addAttribute(.font, value: font(at: content.location).adding(.bold), range: content)
            case .emphasis:
                storage.addAttribute(.font, value: font(at: content.location).adding(.italic), range: content)
            case .strikethrough:
                storage.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: typography.ink.secondary,
                ], range: content)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: NSColor.highlighter, range: content)
            case .code:
                storage.addAttributes([
                    // In the code's own typeface, as code blocks are.
                    .font: Typography.font(typography.monospaceFamily, face: typography.monospaceFace,
                                           size: round(base.pointSize * 0.9), monospaced: true),
                    // Its background is drawn line by line, in the row's own column.
                    .outlineCode: true,
                ], range: content)
            case .link(let target):
                if let url = URL(string: target) {
                    storage.addAttributes([.link: url, .foregroundColor: LinkPill.tint], range: content)
                }
                if pills, images?.filePill(target) == nil {
                    // A link whose text is its own address — `<https://…>` —
                    // is shown as a bare address is: shortened, one icon.
                    if text.substring(with: content) == target, target.hasPrefix("http") {
                        LinkPill.markBare(storage, content, revealed: caret)
                    } else {
                        LinkPill.mark(storage, span.range, kind: .web)
                    }
                }
                // A post's or a video's link shows its card below it, as a bare one does.
                if Tweet.key(from: target) != nil || Video.id(from: target) != nil, let size = images?.naturalSize(target) {
                    storage.addAttribute(.outlineImage, value: ImageBox(source: target, size: size),
                                         range: NSRange(location: span.range.location, length: 1))
                } else {
                    markRichCard(target, text: text.substring(with: content))
                }
                // A file in the graph: a pill, its icon and size in the room
                // its hidden brackets are given.
                if let pill = images?.filePill(target), let open = span.markup.first, let close = span.markup.last,
                   open.location < close.location {
                    storage.addAttribute(.outlineFile, value: pill, range: span.range)
                    storage.addAttribute(.outlineFileLead, value: pill, range: NSRange(location: open.location, length: 1))
                    storage.addAttribute(.outlineFileTail, value: pill, range: NSRange(location: close.location, length: 1))
                    storage.addAttribute(.foregroundColor, value: typography.ink.text, range: content)
                    // A PDF shows itself too, below the link.
                    if let size = images?.pdfSize(target) {
                        storage.addAttribute(.outlineImage, value: ImageBox(source: target, size: size),
                                             range: NSRange(location: span.range.location, length: 1))
                    }
                }
            case .url(let target):
                if let url = URL(string: target) {
                    storage.addAttributes([.link: url, .foregroundColor: LinkPill.tint], range: content)
                }
                if pills { LinkPill.markBare(storage, span.range, revealed: caret) }
                // A post's or a video's bare link shows its card too, below the link.
                if Tweet.key(from: target) != nil || Video.id(from: target) != nil, let size = images?.naturalSize(target) {
                    storage.addAttribute(.outlineImage, value: ImageBox(source: target, size: size),
                                         range: NSRange(location: span.range.location, length: 1))
                } else {
                    markRichCard(target, text: nil)
                }
            case .wikiLink(let title):
                if let url = URL.wiki(title) {
                    storage.addAttributes([.link: url, .foregroundColor: LinkPill.tint], range: content)
                }
                let name = title.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespaces) ?? title
                if pills { LinkPill.mark(storage, span.range, kind: Day(name) != nil || Week(name) != nil ? .day : .page) }
            case .image(let reference):
                // Pictures side by side: one carousel, drawn at the first's place.
                if let group = carousels[span.range.location] {
                    if let group {
                        storage.addAttribute(.outlineImage, value: ImageBox(source: reference.source, size: group.size, carousel: group.sources),
                                             range: NSRange(location: span.range.location, length: 1))
                    }
                } else if let size = images?.size(of: reference) {
                    storage.addAttribute(.outlineImage, value: ImageBox(source: reference.source, size: size),
                                         range: NSRange(location: span.range.location, length: 1))
                }
            case .imageText:
                storage.addAttribute(.foregroundColor, value: typography.ink.secondary, range: span.range)
            case .tag:
                storage.addAttribute(.foregroundColor, value: LinkPill.tint, range: span.range)
                if pills { LinkPill.mark(storage, span.range, kind: .tag) }
            case .comment:
                break
            }
            for run in span.markup {
                storage.addAttribute(.outlineHidden, value: true, range: run)
            }
        }
        // After the words' own styles: the arrow's face is the last word on it.
        // `->` and `<-` shown as arrows — not in code or links, and typed
        // as they are while the caret is at them.
        let literal = resolved.filter {
            switch $0.kind { case .code, .link, .url, .image, .comment: true; default: false }
        }.map(\.range)
        for (range, arrow) in TypedArrows.find(in: text, range: body, skipping: literal) {
            if let caret, caret >= range.location, caret <= NSMaxRange(range) { continue }
            storage.addAttribute(.outlineHidden, value: true, range: NSRange(location: range.location, length: range.length - 1))
            let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
            storage.addAttribute(.outlineArrow, value: arrow, range: last)
            // A face without the arrow: the system's, for it alone.
            let face = font(at: last.location)
            var unichars = Array(arrow.utf16)
            var glyph = [CGGlyph](repeating: 0, count: unichars.count)
            if !CTFontGetGlyphsForCharacters(face, &unichars, &glyph, unichars.count) || glyph[0] == 0 {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: face.pointSize), range: last)
            }
        }
        if done {
            storage.addAttribute(.foregroundColor, value: typography.ink.secondary, range: range)
        }
    }

    /// With nowhere to find pictures, an image is its Markdown.
    private static func unshown(_ span: InlineSpan) -> InlineSpan {
        guard span.isImage else { return span }
        var text = span
        text.kind = .imageText
        text.content = span.range
        return text
    }
}

/// Lays out hidden markup as nothing at all: no ink, no width.
package final class HiddenMarkupGlyphs: NSObject, NSLayoutManagerDelegate {
    package func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>, font: NSFont,
                       forGlyphRange range: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var hidden = false
        var arrows = false
        for index in 0..<range.length {
            if storage.attribute(.outlineHidden, at: characterIndexes[index], effectiveRange: nil) != nil { hidden = true }
            if storage.attribute(.outlineArrow, at: characterIndexes[index], effectiveRange: nil) != nil { arrows = true }
            if hidden && arrows { break }
        }
        guard hidden || arrows else { return 0 }
        // A typed arrow's last character as the arrow, in its own font.
        var glyphList = [CGGlyph](UnsafeBufferPointer(start: glyphs, count: range.length))
        /// Arrows the face cannot draw: their characters left as typed.
        var unmade = Set<Int>()
        if arrows {
            for index in 0..<range.length {
                guard let arrow = storage.attribute(.outlineArrow, at: characterIndexes[index], effectiveRange: nil) as? String else { continue }
                var unichars = Array(arrow.utf16)
                var glyph = [CGGlyph](repeating: 0, count: unichars.count)
                if CTFontGetGlyphsForCharacters(font, &unichars, &glyph, unichars.count), glyph[0] != 0 {
                    glyphList[index] = glyph[0]
                } else {
                    for back in 1...2 where index - back >= 0 { unmade.insert(characterIndexes[index - back]) }
                }
            }
        }
        var changed = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: properties, count: range.length))
        // A control character laid out with no width, rather than a null
        // glyph: a line that starts with null glyphs is measured from the
        // line before it.
        let text = storage.string as NSString
        for index in 0..<range.length
        where storage.attribute(.outlineHidden, at: characterIndexes[index], effectiveRange: nil) != nil {
            // An arrow's first characters, the arrow not drawable: as typed.
            if unmade.contains(characterIndexes[index]), [0x2D, 0x3C].contains(text.character(at: characterIndexes[index])) { continue }
            changed[index] = .controlCharacter
        }
        layoutManager.setGlyphs(glyphList, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    /// A line holding pictures grows to hold them: below its text, or, on a
    /// line with nothing else shown, in place of it.
    package func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let pictures = ImageLine.pictures(in: storage, characters: characters, container: textContainer)
        var changed = false
        if !pictures.isEmpty {
            let picturesHeight = pictures.reduce(0) { $0 + $1.size.height + 2 * ImageBox.margin }
            let lineHeight = lineFragmentRect.pointee.height
            let height = ImageLine.hasText(storage, characters) ? lineHeight + picturesHeight : max(lineHeight, picturesHeight)
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            changed = true
        }
        // A time block's last line reaches down as far as the block lasts,
        // and the free time after it further.
        if characters.length > 0, let slot = storage.attribute(.outlineTimeSlot, at: NSMaxRange(characters) - 1, effectiveRange: nil) as? TimeSlot,
           slot.isLast, (storage.string as NSString).character(at: NSMaxRange(characters) - 1) == 0x0a {
            let top = TimeBlockGeometry.top(of: slot, endingAt: NSMaxRange(characters) - 1, in: layoutManager,
                                            line: glyphRange, fragment: lineFragmentRect.pointee)
            let rect = lineFragmentRect.pointee
            let cardBottom = max(rect.maxY, top + slot.cardHeight)
            lineFragmentRect.pointee.size.height = cardBottom + slot.freeHeight - rect.minY
            lineFragmentUsedRect.pointee.size.height = cardBottom - lineFragmentUsedRect.pointee.minY
            changed = true
        }
        return changed
    }

    /// Laid out: the PDFs' views go where their room now is.
    package func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        guard let view = (layoutManager as? OutlineLayoutManager)?.outlineView else { return }
        MainActor.assumeIsolated { view.schedulePDFPlacement() }
    }

    package func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage else { return action }
        // A file pill's icon and size take room where its brackets are hidden.
        if storage.attribute(.outlineFileLead, at: index, effectiveRange: nil) != nil
            || storage.attribute(.outlineFileTail, at: index, effectiveRange: nil) != nil
            || storage.attribute(.outlineLinkLead, at: index, effectiveRange: nil) != nil
            || storage.attribute(.outlineLinkTail, at: index, effectiveRange: nil) != nil
            || storage.attribute(.outlineLinkEllipsis, at: index, effectiveRange: nil) != nil {
            return .whitespace
        }
        if storage.attribute(.outlineHidden, at: index, effectiveRange: nil) != nil {
            return .zeroAdvancement
        }
        return action
    }

    /// How much room a file pill's icon, or its size, takes.
    package func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect, glyphPosition: NSPoint, characterIndex: Int) -> NSRect {
        guard let storage = layoutManager.textStorage else { return .zero }
        let font = storage.attribute(.font, at: characterIndex, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
        var width: CGFloat = 0
        if storage.attribute(.outlineFileLead, at: characterIndex, effectiveRange: nil) != nil {
            width = FilePill.leadWidth
        } else if let pill = storage.attribute(.outlineFileTail, at: characterIndex, effectiveRange: nil) as? FilePill {
            width = pill.tailWidth(for: font)
        } else if let pill = storage.attribute(.outlineLinkLead, at: characterIndex, effectiveRange: nil) as? LinkPill {
            width = pill.leadWidth(for: font)
        } else if storage.attribute(.outlineLinkTail, at: characterIndex, effectiveRange: nil) != nil {
            width = LinkPill.tailWidth
        } else if storage.attribute(.outlineLinkEllipsis, at: characterIndex, effectiveRange: nil) != nil {
            width = LinkPill.ellipsisWidth(for: font)
        }
        return NSRect(x: glyphPosition.x, y: glyphPosition.y, width: width, height: ceil(font.ascender - font.descender))
    }
}

extension NSColor {
    /// `==text==`'s ground: a highlighter's yellow, the text's own colour
    /// still reading through it, light or dark.
    package static let highlighter = NSColor(name: "highlighter") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow.withAlphaComponent(0.32)
            : NSColor(srgbRed: 1, green: 0.86, blue: 0.3, alpha: 0.55)
    }
}

extension NSFont {
    /// This font, bolder or slanted: the family's own face for it, found
    /// by name and weight — some families mark neither — else what the
    /// system makes of the traits.
    package func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        if let family = familyName {
            let faces = Typography.Face.all(in: family)
            if let current = faces.first(where: { $0.name == fontName }) {
                var candidates = faces
                if trait.contains(.italic) { candidates = candidates.filter { $0.italic } } else { candidates = candidates.filter { $0.italic == current.italic } }
                if trait.contains(.bold) {
                    // Heavier: Bold itself if it is heavier, else the nearest heavier.
                    let heavier = candidates.filter { $0.heaviness > current.heaviness }
                    candidates = heavier.filter { $0.style.lowercased().hasPrefix("bold") }.isEmpty
                        ? heavier.sorted { $0.heaviness < $1.heaviness }
                        : heavier.filter { $0.style.lowercased().hasPrefix("bold") }
                } else {
                    // The same weight, slanted.
                    candidates = candidates.sorted { abs($0.heaviness - current.heaviness) < abs($1.heaviness - current.heaviness) }
                }
                if let face = candidates.first, let font = NSFont(name: face.name, size: pointSize) { return font }
            }
        }
        let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

/// Where the pictures on a line go.
package enum ImageLine {
    /// The pictures on a line, in order, at the size they are drawn.
    package static func pictures(in storage: NSTextStorage, characters: NSRange, container: NSTextContainer) -> [(box: ImageBox, size: CGSize, location: Int)] {
        var found: [(ImageBox, CGSize, Int)] = []
        guard characters.length > 0 else { return [] }
        storage.enumerateAttribute(.outlineImage, in: characters) { value, range, _ in
            guard let box = value as? ImageBox else { return }
            let indent = (storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            found.append((box, box.fitted(to: container.size.width - indent - 2 * container.lineFragmentPadding), range.location))
        }
        return found
    }

    /// Whether a line shows anything but pictures and space.
    package static func hasText(_ storage: NSTextStorage, _ characters: NSRange) -> Bool {
        let text = storage.string as NSString
        var shown = false
        storage.enumerateAttribute(.outlineHidden, in: characters) { value, range, stop in
            guard value == nil else { return }
            let visible = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{2028}")))
            if !visible.isEmpty {
                shown = true
                stop.pointee = true
            }
        }
        return shown
    }

    /// The rectangles, in the line fragment, that its pictures are drawn in:
    /// stacked from the foot of the line.
    package static func frames(in storage: NSTextStorage, characters: NSRange, container: NSTextContainer, fragment: NSRect,
                       indent: CGFloat) -> [(box: ImageBox, frame: NSRect)] {
        let pictures = pictures(in: storage, characters: characters, container: container)
        var y = fragment.maxY - pictures.reduce(0) { $0 + $1.size.height + 2 * ImageBox.margin }
        return pictures.map { picture in
            let frame = NSRect(x: indent, y: y + ImageBox.margin, width: picture.size.width, height: picture.size.height)
            y += picture.size.height + 2 * ImageBox.margin
            return (picture.box, frame)
        }
    }
}
