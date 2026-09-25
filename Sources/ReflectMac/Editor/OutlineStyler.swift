import AppKit
import ReflectCore

/// The type and measures of the outline, from one size.
struct OutlineMetrics {
    var fontSize: CGFloat

    /// How far each level of the outline is indented.
    var indent: CGFloat { round(fontSize * 1.6) }
    var body: NSFont { .systemFont(ofSize: fontSize) }
    var code: NSFont { .monospacedSystemFont(ofSize: round(fontSize * 0.88), weight: .regular) }
    var lineHeightMultiple: CGFloat { 1.18 }

    func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: .systemFont(ofSize: round(fontSize * 1.5), weight: .bold)
        case 2: .systemFont(ofSize: round(fontSize * 1.25), weight: .bold)
        case 3: .systemFont(ofSize: round(fontSize * 1.1), weight: .semibold)
        default: .systemFont(ofSize: fontSize, weight: .semibold)
        }
    }

    func font(for row: Row) -> NSFont {
        switch row.kind {
        case .heading(let level): heading(level)
        case .code: code
        default: body
        }
    }

    /// Where a row's text starts. A list item's marker hangs in the space
    /// before it; anything else lines up with the text of the item it is in.
    func textIndent(for row: Row) -> CGFloat {
        indent * CGFloat(row.kind.isListItem ? row.depth + 1 : max(row.depth, 1))
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
        let range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: edited.length))
        if mask.contains(.editedCharacters) { unify(storage, in: range, inserted: edited) }
        style(storage, in: range)
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
            let style = storage.attribute(.outlineRow, at: paragraph.location, effectiveRange: nil) as Any
            storage.setAttributes(attributes(for: row, first: paragraph.location == 0), range: paragraph)
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            if case .code = row.kind {} else if case .rule = row.kind {} else {
                InlineMarkdown.style(storage, in: paragraph, base: metrics.font(for: row), done: row.task?.isDone == true, images: images)
            }
            // A character the font set here lacks still needs a font that has it.
            storage.fixAttributes(in: paragraph)
        }
    }

    func attributes(for row: Row, first: Bool) -> [NSAttributedString.Key: Any] {
        let font = metrics.font(for: row)
        let paragraph = NSMutableParagraphStyle()
        let indent = metrics.textIndent(for: row)
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineHeightMultiple = metrics.lineHeightMultiple
        paragraph.paragraphSpacing = round(metrics.fontSize * 0.2)
        var before: CGFloat = row.gap.isEmpty ? 0 : round(metrics.fontSize * 0.45)
        if case .heading = row.kind { before += round(metrics.fontSize * 0.5) }
        paragraph.paragraphSpacingBefore = first ? 0 : before
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

/// Inline Markdown, shown as what it means, its markup hidden.
enum InlineMarkdown {
    static func style(_ storage: NSTextStorage, in range: NSRange, base: NSFont, done: Bool, images: ImageStore?) {
        let text = storage.string as NSString
        let body = NSRange(location: range.location, length: max(0, range.length - 1))
        func font(at location: Int) -> NSFont {
            storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont ?? base
        }
        let found = InlineMarkup.spans(in: text, range: body)
        for span in images?.resolve(found) ?? found.map(unshown) {
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
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15),
                ], range: content)
            case .link(let target), .url(let target):
                if let url = URL(string: target) { storage.addAttribute(.link, value: url, range: content) }
            case .wikiLink(let title):
                if let url = URL.wiki(title) { storage.addAttribute(.link, value: url, range: content) }
            case .image(let reference):
                if let size = images?.size(of: reference) {
                    storage.addAttribute(.outlineImage, value: ImageBox(source: reference.source, size: size),
                                         range: NSRange(location: span.range.location, length: 1))
                }
            case .imageText:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .tag:
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: span.range)
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

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt index: Int) -> NSLayoutManager.ControlCharacterAction {
        if layoutManager.textStorage?.attribute(.outlineHidden, at: index, effectiveRange: nil) != nil {
            return .zeroAdvancement
        }
        return action
    }
}

extension NSFont {
    func adding(_ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
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
