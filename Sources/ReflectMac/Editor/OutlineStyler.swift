import AppKit
import ReflectCore

/// The type and measures of the outline, from the Typography settings.
struct OutlineMetrics {
    var typography: Typography

    init(typography: Typography = .current) {
        self.typography = typography
    }

    init(fontSize: CGFloat) {
        var typography = Typography.current
        typography.size = fontSize
        self.typography = typography
    }

    var fontSize: CGFloat { typography.size }
    /// How far each level of the outline is indented.
    var indent: CGFloat { round(fontSize * 1.6) }
    var body: NSFont { Typography.font(typography.bodyFamily, face: typography.bodyFace, size: fontSize) }
    var code: NSFont {
        Typography.font(typography.monospaceFamily, face: typography.monospaceFace, size: round(fontSize * 0.88), monospaced: true)
    }
    var lineHeightMultiple: CGFloat { typography.lineHeight }
    /// The space after each row.
    var rowSpacing: CGFloat { round(fontSize * typography.rowSpacing) }
    var columnWidth: CGFloat { typography.lineLength }

    func heading(_ level: Int) -> NSFont {
        // The first level at the scale set; the rest step down to body size.
        let scale = typography.headingScale
        let (factor, weight): (CGFloat, NSFont.Weight) = switch level {
        case 1: (scale, .bold)
        case 2: (1 + (scale - 1) / 2, .bold)
        case 3: (1 + (scale - 1) / 5, .semibold)
        default: (1, .semibold)
        }
        return Typography.font(typography.headingFamily, face: typography.headingFace, size: round(fontSize * factor), weight: weight)
    }

    func font(for row: Row) -> NSFont {
        switch row.kind {
        case .heading(let level): heading(level)
        case .code: code
        default: body
        }
    }

    /// Where a row's text starts: one step in for each level, whether or
    /// not it has a bullet — a list item's marker hangs in the space before
    /// it — so taking a bullet off leaves the text where it was.
    func textIndent(for row: Row) -> CGFloat {
        indent * CGFloat(row.depth + 1)
    }
}

/// Styles the outline as it changes: every paragraph from its row, and the
/// inline Markdown in it.
///
/// Only attributes are touched, never characters, so what is on screen is
/// what is written to disk. It also keeps each paragraph to one row: when an
/// edit joins two, the row that was there first wins.
final class OutlineStyler: NSObject, NSTextStorageDelegate {
    var metrics: OutlineMetrics
    /// Rows that were folded inside a row an edit swallowed, with where they
    /// belong; the editor puts them back once the edit is done.
    var orphans: [(location: Int, rows: [Row])] = []
    /// Told of every change to the characters, before anything else hears
    /// of it.
    var onCharactersEdited: (() -> Void)?
    /// Where pictures come from; without it, images stay as Markdown.
    var images: ImageStore?
    /// Where the caret is: a shortened web address it is in is shown whole.
    var caret: Int?

    init(metrics: OutlineMetrics) {
        self.metrics = metrics
    }

    // Styling happens once an edit is processed: changing attributes before
    // then widens the edit, and the layout manager moves a caret inside an
    // edit to its end.
    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorageEditActions,
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
        style(storage, in: range)
    }

    /// Styles the paragraph a character is in again.
    func restyle(_ storage: NSTextStorage, paragraphAt location: Int) {
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        storage.beginEditing()
        style(storage, in: paragraph)
        storage.endEditing()
    }

    func styleAll(_ storage: NSTextStorage) {
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
            storage.setAttributes(attributes(for: row, after: previous), range: paragraph)
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            if case .code = row.kind {
                CodeBlock.dimFences(storage, in: paragraph)
            } else if case .rule = row.kind {} else {
                // In a heading, links are only coloured: a pill would crowd its large type.
                var inHeading = false
                if case .heading = row.kind { inHeading = true }
                InlineMarkdown.style(storage, in: paragraph, base: metrics.font(for: row), done: row.task?.isDone == true,
                                     images: images, caret: caret, pills: !inHeading)
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
    func attributes(for row: Row, after previous: Row?) -> [NSAttributedString.Key: Any] {
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
            .foregroundColor: NSColor.textColor,
        ]
        switch row.kind {
        case .quote:
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
        case .rule:
            // The rule is drawn; its dashes are only there to be edited.
            attributes[.foregroundColor] = NSColor.clear
        case .code:
            attributes[.foregroundColor] = NSColor.labelColor
        default:
            break
        }
        if row.task?.isDone == true {
            attributes[.foregroundColor] = NSColor.secondaryLabelColor
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = NSColor.tertiaryLabelColor
        }
        return attributes
    }
}

extension NSAttributedString.Key {
    /// Markup not shown: its characters are kept, but draw nothing.
    static let outlineHidden = NSAttributedString.Key("ReflectOutlineHidden")
}

/// A code block's fences: the lines that open and close it, there to be
/// edited but not to be read.
enum CodeBlock {
    static func dimFences(_ storage: NSTextStorage, in paragraph: NSRange) {
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
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: line)
        }
    }

    /// The language a block's opening fence names, if any.
    static func language(of text: String) -> String? {
        guard let first = text.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}")).first,
              OutlineTextView.isFence(first) else { return nil }
        let name = first.trimmingCharacters(in: .whitespaces).drop(while: { $0 == "`" || $0 == "~" })
        return name.isEmpty ? nil : String(name)
    }
}

/// Inline Markdown, shown as what it means, its markup hidden.
enum InlineMarkdown {
    static func style(_ storage: NSTextStorage, in range: NSRange, base: NSFont, done: Bool, images: ImageStore?, caret: Int? = nil,
                      pills: Bool = true) {
        let text = storage.string as NSString
        let body = NSRange(location: range.location, length: max(0, range.length - 1))
        func font(at location: Int) -> NSFont {
            storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? base
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
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: content)
            case .code:
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: round(base.pointSize * 0.9), weight: .regular),
                    // Its background is drawn line by line, in the row's own column.
                    .outlineCode: true,
                ], range: content)
            case .link(let target):
                if let url = URL(string: target) {
                    storage.addAttributes([.link: url, .foregroundColor: LinkPill.tint], range: content)
                }
                if pills, images?.filePill(target) == nil { LinkPill.mark(storage, span.range, kind: .web) }
                // A file in the graph: a pill, its icon and size in the room
                // its hidden brackets are given.
                if let pill = images?.filePill(target), let open = span.markup.first, let close = span.markup.last,
                   open.location < close.location {
                    storage.addAttribute(.outlineFile, value: pill, range: span.range)
                    storage.addAttribute(.outlineFileLead, value: pill, range: NSRange(location: open.location, length: 1))
                    storage.addAttribute(.outlineFileTail, value: pill, range: NSRange(location: close.location, length: 1))
                    storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: content)
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
                if Tweet.id(from: target) != nil || Video.id(from: target) != nil, let size = images?.naturalSize(target) {
                    storage.addAttribute(.outlineImage, value: ImageBox(source: target, size: size),
                                         range: NSRange(location: span.range.location, length: 1))
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
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
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
        if done {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
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
final class HiddenMarkupGlyphs: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>, font: NSFont,
                       forGlyphRange range: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var hidden = false
        for index in 0..<range.length where storage.attribute(.outlineHidden, at: characterIndexes[index], effectiveRange: nil) != nil {
            hidden = true
            break
        }
        guard hidden else { return 0 }
        var changed = [NSLayoutManager.GlyphProperty](UnsafeBufferPointer(start: properties, count: range.length))
        // A control character laid out with no width, rather than a null
        // glyph: a line that starts with null glyphs is measured from the
        // line before it.
        for index in 0..<range.length
        where storage.attribute(.outlineHidden, at: characterIndexes[index], effectiveRange: nil) != nil {
            changed[index] = .controlCharacter
        }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        return range.length
    }

    /// A line holding pictures grows to hold them: below its text, or, on a
    /// line with nothing else shown, in place of it.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let pictures = ImageLine.pictures(in: storage, characters: characters, container: textContainer)
        guard !pictures.isEmpty else { return false }
        let picturesHeight = pictures.reduce(0) { $0 + $1.size.height + 2 * ImageBox.margin }
        let lineHeight = lineFragmentRect.pointee.height
        let height = ImageLine.hasText(storage, characters) ? lineHeight + picturesHeight : max(lineHeight, picturesHeight)
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        return true
    }

    /// Laid out: the PDFs' views go where their room now is.
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        guard let view = (layoutManager as? OutlineLayoutManager)?.outlineView else { return }
        MainActor.assumeIsolated { view.schedulePDFPlacement() }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
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
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
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

extension NSFont {
    /// This font, bolder or slanted: the family's own face for it, found
    /// by name and weight — some families mark neither — else what the
    /// system makes of the traits.
    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
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
enum ImageLine {
    /// The pictures on a line, in order, at the size they are drawn.
    static func pictures(in storage: NSTextStorage, characters: NSRange, container: NSTextContainer) -> [(box: ImageBox, size: CGSize, location: Int)] {
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
    static func hasText(_ storage: NSTextStorage, _ characters: NSRange) -> Bool {
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
    static func frames(in storage: NSTextStorage, characters: NSRange, container: NSTextContainer, fragment: NSRect,
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
