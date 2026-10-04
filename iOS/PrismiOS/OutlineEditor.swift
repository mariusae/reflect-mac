import UIKit
import UIKit.UIGestureRecognizerSubclass
import UniformTypeIdentifiers
import ReflectCore
import PrismCore

extension NSAttributedString.Key {
    /// Markup not shown: a span's marks, while the caret is away from it.
    static let prismHidden = NSAttributedString.Key("PrismHidden")
    /// On the first character of a picture's Markdown: the picture, drawn in its place.
    static let prismImage = NSAttributedString.Key("PrismImage")
    /// On a link's last hidden opening character: the symbol drawn there —
    /// a page, a day, the web — in room of its own, inside the pill.
    static let prismIcon = NSAttributedString.Key("PrismIcon")
    /// On a paragraph: the room above its first line.
    static let prismSpaceBefore = NSAttributedString.Key("PrismSpaceBefore")
    /// On the first hidden character of a shortened address's middle: an
    /// ellipsis drawn in its place.
    static let prismEllipsis = NSAttributedString.Key("PrismEllipsis")
    /// On a picture's `!`: after text, the rest of that text's line; else nothing.
    static let prismBreak = NSAttributedString.Key("PrismBreak")
    /// A link drawn as a pill.
    static let prismPill = NSAttributedString.Key("PrismPill")
    /// Where a link goes, as tapped: a note's title, or an address.
    static let prismLink = NSAttributedString.Key("PrismLink")
    /// On a row not shown at all, its line no height: a note's title row,
    /// in a card whose header says it already.
    static let prismCollapsed = NSAttributedString.Key("PrismCollapsed")
}

/// The type and measures of the outline: a face at a size.
struct PhoneMetrics: Equatable {
    var face: Typeface = .current
    var size: CGFloat = 17

    var body: UIFont { face.body(face.size(size)) }
    var code: UIFont { face.mono(round(face.size(size) * 0.88)) }
    var indent: CGFloat { round(size * 1.35) }

    func heading(_ level: Int) -> UIFont {
        let scale: CGFloat = [1.55, 1.3, 1.12, 1.0, 1.0, 1.0][min(max(level, 1), 6) - 1]
        return face.heading(round(face.size(size) * scale), weight: level <= 2 ? .bold : .semibold)
    }

    func font(for row: Row) -> UIFont {
        switch row.kind {
        case .heading(let level): heading(level)
        case .code: code
        default: body
        }
    }

    /// Where a row's text starts: one step in for each level, its marker
    /// hung in the step before it.
    /// Deep rows stop going right at eight: a line must keep room for its text.
    func textIndent(for row: Row) -> CGFloat { indent * CGFloat(min(row.depth, 8) + 1) }
}

// MARK: - Styling

/// Styles the outline as it changes: each paragraph from its row, the
/// inline Markdown drawn rather than shown. Only attributes are touched, so
/// what is on screen is what is written. It keeps each paragraph to one
/// row: when an edit joins two, the one that was there first wins.
final class PhoneStyler: NSObject, NSTextStorageDelegate {
    var metrics: PhoneMetrics
    /// Whether a first row that is a top heading — the note's title — is
    /// not shown: in a card, its header says it.
    var hidesTitle = false
    /// Where the caret is: the span it is in shows its marks.
    var caret: Int?
    /// Rows folded inside a row an edit swallowed, with where they belong.
    var orphans: [(location: Int, rows: [Row])] = []

    init(metrics: PhoneMetrics) {
        self.metrics = metrics
    }

    /// While set, edits are taken as already styled: text styled elsewhere
    /// being put in whole.
    var paused = false

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorage.EditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard storage.length > 0, !paused else { return }
        let text = storage.string as NSString
        var range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: min(edited.length, text.length - min(edited.location, text.length))))
        if NSMaxRange(range) < text.length {
            range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        if mask.contains(.editedCharacters) { unify(storage, in: range, inserted: edited) }
        style(storage, in: range)
    }

    func styleAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        style(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    func restyle(_ storage: NSTextStorage, around location: Int) {
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        storage.beginEditing()
        style(storage, in: paragraph)
        storage.endEditing()
    }

    private func unify(_ storage: NSTextStorage, in range: NSRange, inserted: NSRange) {
        let text = storage.string as NSString
        for paragraph in OutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: paragraph.location + range.location, length: paragraph.length)
            var styles: [RowStyle] = []
            var winner: RowStyle?
            storage.enumerateAttribute(.outlineRow, in: paragraph) { value, run, _ in
                guard let style = value as? RowStyle else { return }
                if !styles.contains(where: { $0 === style }) { styles.append(style) }
                let typed = NSIntersectionRange(run, inserted).length == run.length && inserted.length > 0
                if winner == nil && !typed { winner = style }
            }
            let style = winner ?? styles.last ?? RowStyle(.blank)
            guard styles.count > 1 || styles.first !== style else { continue }
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            for lost in styles where lost !== style && lost.row.isFolded {
                orphans.append((paragraph.location, lost.row.folded.map { child in
                    var child = child
                    child.depth += lost.row.depth
                    return child
                }))
            }
        }
    }

    private func style(_ storage: NSTextStorage, in range: NSRange) {
        let text = storage.string as NSString
        for paragraph in OutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: paragraph.location + range.location, length: paragraph.length)
            let style = OutlineText.style(storage, at: paragraph.location)
            let row = style.row
            let previous = paragraph.location > 0 ? OutlineText.style(storage, at: paragraph.location - 1).row : nil
            storage.setAttributes(attributes(for: row, after: previous), range: paragraph)
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            switch row.kind {
            case .code, .rule: break
            default: styleInline(storage, in: paragraph, row: row)
            }
            if hidesTitle, paragraph.location == 0, case .heading(1) = row.kind, NSMaxRange(paragraph) < text.length {
                collapse(storage, paragraph)
            }
            storage.fixAttributes(in: paragraph)
        }
    }

    /// A row not shown: its characters nothing, its line no height.
    private func collapse(_ storage: NSTextStorage, _ paragraph: NSRange) {
        for key: NSAttributedString.Key in [.prismImage, .prismIcon, .prismEllipsis, .prismBreak, .prismPill, .prismSpaceBefore] {
            storage.removeAttribute(key, range: paragraph)
        }
        // The line break kept: a row's end, though not seen.
        if paragraph.length > 1 { storage.addAttribute(.prismHidden, value: true, range: NSRange(location: paragraph.location, length: paragraph.length - 1)) }
        storage.addAttribute(.prismCollapsed, value: true, range: paragraph)
    }

    func attributes(for row: Row, after previous: Row?) -> [NSAttributedString.Key: Any] {
        let font = metrics.font(for: row)
        let paragraph = NSMutableParagraphStyle()
        let indent = metrics.textIndent(for: row)
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.lineHeightMultiple = row.kind == .code ? 1.2 : metrics.face.lineHeight * metrics.size / max(font.lineHeight, 1)
        paragraph.paragraphSpacing = round(metrics.size * 0.32)
        var before: CGFloat = 0
        if case .heading(let level) = row.kind {
            // A heading's lines as tall as its own type wants, not the body's;
            // and room above it, a section's start.
            paragraph.lineHeightMultiple = 1.12
            before = round(metrics.size * (level <= 2 ? 1.25 : 0.9))
        }
        // Given as the line is laid out — see `prismSpaceBefore`.
        paragraph.paragraphSpacingBefore = 0
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: Ink.text]
        if previous != nil, before > 0 { attributes[.prismSpaceBefore] = before }
        switch row.kind {
        case .quote: attributes[.foregroundColor] = Ink.secondary
        case .rule: attributes[.foregroundColor] = UIColor.clear
        default: break
        }
        if row.task?.isDone == true {
            attributes[.foregroundColor] = Ink.secondary
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = Ink.faint
        }
        return attributes
    }

    /// The inline Markdown in a row, drawn: its marks hidden — but for the
    /// span the caret is in — links as pills, and the rest as it reads.
    private func styleInline(_ storage: NSTextStorage, in paragraph: NSRange, row: Row) {
        let text = storage.string as NSString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        let base = metrics.font(for: row)
        func font(at location: Int) -> UIFont { storage.attribute(.font, at: location, effectiveRange: nil) as? UIFont ?? base }
        let inHeading: Bool = { if case .heading = row.kind { true } else { false } }()
        for span in InlineMarkup.spans(in: text, range: body) {
            let content = span.content
            let revealed = caret.map { NSLocationInRange($0, span.range) || $0 == NSMaxRange(span.range) } ?? false
            switch span.kind {
            case .strong:
                storage.addAttribute(.font, value: Self.adding(.traitBold, to: font(at: content.location)), range: content)
            case .emphasis:
                storage.addAttribute(.font, value: Self.adding(.traitItalic, to: font(at: content.location)), range: content)
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Ink.secondary], range: content)
            case .code:
                storage.addAttributes([.font: metrics.face.mono(round(base.pointSize * 0.88)), .backgroundColor: Ink.codeBack], range: content)
            case .highlight:
                storage.addAttribute(.backgroundColor, value: Ink.marked, range: content)
            case .link(let target), .url(let target):
                storage.addAttributes([.foregroundColor: Ink.accent, .prismLink: target], range: content)
                if !inHeading { storage.addAttribute(.prismPill, value: true, range: span.range) }
                // A bare address, as the Mac shows it: its site and the ends of
                // its path, the link icon before — whole while the caret is in it.
                if case .url = span.kind, !revealed, !inHeading, PhoneLayoutManager.drawsPills {
                    let parts = AddressShortening.shortened(text.substring(with: span.range))
                    if parts.prefix > 0 {
                        let at = span.range.location
                        if parts.prefix > 1 { storage.addAttribute(.prismHidden, value: true, range: NSRange(location: at, length: parts.prefix - 1)) }
                        storage.addAttribute(.prismIcon, value: "link", range: NSRange(location: at + parts.prefix - 1, length: 1))
                        if let middle = parts.middle, middle.length > 0 {
                            storage.addAttribute(.prismEllipsis, value: true, range: NSRange(location: at + middle.location, length: 1))
                            if middle.length > 1 {
                                storage.addAttribute(.prismHidden, value: true, range: NSRange(location: at + middle.location + 1, length: middle.length - 1))
                            }
                        }
                        if let rest = parts.rest, rest.length > 0 {
                            storage.addAttribute(.prismHidden, value: true, range: NSRange(location: at + rest.location, length: rest.length))
                        }
                    }
                }
            case .wikiLink(let title):
                storage.addAttributes([.foregroundColor: Ink.accent, .prismLink: "[[" + title + "]]"], range: content)
                if !inHeading { storage.addAttribute(.prismPill, value: true, range: span.range) }
            case .tag:
                storage.addAttribute(.foregroundColor, value: Ink.accent, range: span.range)
            case .comment:
                if !revealed { storage.addAttribute(.prismHidden, value: true, range: span.range) }
            case .image(let reference):
                // The picture, once it is in, in place of its Markdown — but
                // for while the caret is in it, to edit what it says.
                // (Text is styled on the main thread, where the pictures are kept.)
                let inside = caret.map { $0 > span.range.location && $0 < NSMaxRange(span.range) } ?? false
                if !inside, span.range.length > 2, let image = PhoneImages.lookup(reference.source) {
                    // The `!` takes the rest of a line it follows text on —
                    // a line may not break before `!`, but may after it —
                    // and the `[` is the picture, on a line of its own; the
                    // rest of the Markdown is not shown.
                    let box = PhoneImageBox(image: image, width: reference.width.map { CGFloat($0) })
                    let start = span.range.location
                    storage.addAttribute(.prismBreak, value: true, range: NSRange(location: start, length: 1))
                    storage.addAttribute(.prismImage, value: box, range: NSRange(location: start + 1, length: 1))
                    storage.addAttribute(.prismHidden, value: true, range: NSRange(location: start + 2, length: span.range.length - 2))
                    // A done row's line through its text does not go through the picture.
                    storage.removeAttribute(.strikethroughStyle, range: NSRange(location: start, length: 2))
                    if start > paragraph.location, text.character(at: start - 1) == 0x20 {
                        storage.removeAttribute(.strikethroughStyle, range: NSRange(location: start - 1, length: 1))
                    }
                } else {
                    storage.addAttributes([.foregroundColor: Ink.faint, .font: metrics.face.mono(round(base.pointSize * 0.75))], range: span.range)
                }
            case .imageText:
                storage.addAttributes([.foregroundColor: Ink.faint, .font: metrics.face.mono(round(base.pointSize * 0.75))], range: span.range)
            }
            guard span.kind != .comment, !span.isImage else { continue }
            for markup in span.markup {
                if revealed {
                    storage.addAttribute(.foregroundColor, value: Ink.faint, range: markup)
                } else {
                    storage.addAttribute(.prismHidden, value: true, range: markup)
                }
            }
            // The link's kind, as an icon in its pill, as the Mac shows it:
            // on the opening markup's last character, next to the words.
            if !revealed, !inHeading, PhoneLayoutManager.drawsPills, let opening = span.markup.first, opening.length > 0,
               opening.location == span.range.location {
                let symbol: String?
                switch span.kind {
                case .wikiLink(let title): symbol = Day(title.components(separatedBy: "|")[0].trimmingCharacters(in: .whitespaces)) != nil ? "calendar" : "doc.text"
                case .link: symbol = "link"
                default: symbol = nil
                }
                if let symbol {
                    let lead = NSRange(location: NSMaxRange(opening) - 1, length: 1)
                    storage.removeAttribute(.prismHidden, range: lead)
                    storage.addAttribute(.prismIcon, value: symbol, range: lead)
                }
            }
        }
    }

    private static func adding(_ trait: UIFontDescriptor.SymbolicTraits, to font: UIFont) -> UIFont {
        if trait == .traitBold, let family = UIFont.fontNames(forFamilyName: font.familyName).first(where: { $0.lowercased().contains("bold") }),
           !font.fontName.lowercased().contains("bold"), !font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            return UIFont(name: family, size: font.pointSize) ?? font
        }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait)) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }
}

// MARK: - Drawing

/// Lays the outline out: hidden markup takes no room, and the margin's
/// markers — bullets, checkboxes, numbers, the bars of quotes — and the
/// pills behind links are drawn under the text.
final class PhoneLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var metrics = PhoneMetrics()
    /// For each row with children, whether all of them are done; and
    /// whether the row has any, for its bullet.

    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A link icon's side, and the room before a link's words it takes.
    static func iconSide(for font: UIFont) -> CGFloat { round(font.pointSize * 0.72) }
    static func iconLead(for font: UIFont) -> CGFloat { 2 + iconSide(for: font) + 4 }

    /// Each link's icon, in the room its lead was given; each shortened
    /// address's ellipsis, in its.
    private func drawIcons(in characters: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(.prismEllipsis, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? metrics.body
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let place = location(forGlyphAt: glyph)
            let text = NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: Ink.accent])
            text.draw(at: CGPoint(x: origin.x + fragment.minX + place.x, y: origin.y + fragment.minY + place.y - font.ascender))
        }
        storage.enumerateAttribute(.prismIcon, in: characters) { value, range, _ in
            guard let symbol = value as? String else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? metrics.body
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let place = location(forGlyphAt: glyph)
            let side = Self.iconSide(for: font)
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.9, weight: .medium)
            guard let image = UIImage(systemName: symbol, withConfiguration: configuration)?.withTintColor(Ink.accent, renderingMode: .alwaysOriginal) else { return }
            let size = image.size
            let baseline = fragment.minY + place.y
            let middle = baseline - font.xHeight / 2
            image.draw(in: CGRect(x: origin.x + fragment.minX + place.x + 2 + (side - size.width) / 2,
                                  y: origin.y + middle - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// Whether links have a pill behind them.
    static let drawsPills = true

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: UIFont, forGlyphRange range: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<range.length {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            // A picture's first character is a space as big as the picture;
            // the rest of its Markdown, like other hidden marks, nothing.
            let property: NSLayoutManager.GlyphProperty
            if storage.attribute(.prismImage, at: index, effectiveRange: nil) != nil
                || storage.attribute(.prismBreak, at: index, effectiveRange: nil) != nil
                || storage.attribute(.prismIcon, at: index, effectiveRange: nil) != nil
                || storage.attribute(.prismEllipsis, at: index, effectiveRange: nil) != nil {
                property = .controlCharacter
            } else if storage.attribute(.prismHidden, at: index, effectiveRange: nil) != nil {
                property = .null
            } else {
                continue
            }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: range.length)) }
            changed![i] = property
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        }
        return range.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length else { return action }
        guard storage.attribute(.prismImage, at: charIndex, effectiveRange: nil) != nil
              || storage.attribute(.prismBreak, at: charIndex, effectiveRange: nil) != nil
              || storage.attribute(.prismIcon, at: charIndex, effectiveRange: nil) != nil
              || storage.attribute(.prismEllipsis, at: charIndex, effectiveRange: nil) != nil else { return action }
        return .whitespace
    }

    /// How wide a line of a row is, from its text's left edge: the room a
    /// picture in it has.
    private func lineWidth(at charIndex: Int, in container: NSTextContainer) -> CGFloat {
        let indent = (textStorage?.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
        return max(40, container.size.width - indent - 2 * container.lineFragmentPadding - 1)
    }

    /// A picture's character takes a whole line across, so it is on a line
    /// of its own — text before it ends its line, text after it starts the next.
    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int, for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: CGRect, glyphPosition: CGPoint, characterIndex charIndex: Int) -> CGRect {
        guard let storage = textStorage, charIndex < storage.length else { return .zero }
        if storage.attribute(.prismIcon, at: charIndex, effectiveRange: nil) != nil {
            let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? UIFont ?? metrics.body
            return CGRect(x: 0, y: 0, width: Self.iconLead(for: font), height: 1)
        }
        if storage.attribute(.prismEllipsis, at: charIndex, effectiveRange: nil) != nil {
            let font = storage.attribute(.font, at: charIndex, effectiveRange: nil) as? UIFont ?? metrics.body
            return CGRect(x: 0, y: 0, width: ceil(("…" as NSString).size(withAttributes: [.font: font]).width), height: 1)
        }
        // A picture's `!` fills the rest of a line it follows text on: the
        // text stays there, and the picture, too wide for what is left,
        // goes to the next. At a line's start it is nothing.
        if storage.attribute(.prismBreak, at: charIndex, effectiveRange: nil) != nil {
            let indent = (storage.attribute(.paragraphStyle, at: charIndex, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            guard glyphPosition.x > indent + textContainer.lineFragmentPadding + 1 else { return .zero }
            let left = proposedRect.maxX - glyphPosition.x - 2 * textContainer.lineFragmentPadding - 4
            return CGRect(x: 0, y: 0, width: max(0, left), height: 1)
        }
        guard storage.attribute(.prismImage, at: charIndex, effectiveRange: nil) is PhoneImageBox else { return .zero }
        return CGRect(x: 0, y: 0, width: lineWidth(at: charIndex, in: textContainer), height: 1)
    }

    /// A picture's line as tall as the picture; the row's other lines as they are.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if characters.location < storage.length, storage.attribute(.prismCollapsed, at: characters.location, effectiveRange: nil) != nil {
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            baselineOffset.pointee = 0
            return true
        }
        var height: CGFloat?
        storage.enumerateAttribute(.prismImage, in: characters) { value, range, stop in
            guard let box = value as? PhoneImageBox else { return }
            height = box.size(fitting: lineWidth(at: range.location, in: textContainer)).height + 2 * PhoneImageBox.margin
            stop.pointee = true
        }
        // Room above a heading, on its first line: added here, as TextKit
        // leaves a paragraph's own out when its first glyph is hidden markup
        // — a heading that is a link, `## [[Links]]`.
        var above: CGFloat = 0
        // Back over hidden markup: it is laid out on the line before.
        var start = characters.location
        while start > 0, start <= storage.length, storage.attribute(.prismHidden, at: start - 1, effectiveRange: nil) != nil { start -= 1 }
        if start < storage.length, start == 0 || (storage.string as NSString).character(at: start - 1) == 0x0A,
           let value = storage.attribute(.prismSpaceBefore, at: start, effectiveRange: nil) as? CGFloat {
            above = value
        }
        guard height != nil || above > 0 else { return false }
        if let height {
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = height - PhoneImageBox.margin
        }
        lineFragmentRect.pointee.size.height += above
        lineFragmentUsedRect.pointee.origin.y += above
        baselineOffset.pointee += above
        return true
    }

    /// The pictures among some characters: each with its Markdown's range
    /// and where it is drawn, in the text container.
    func images(in characters: NSRange) -> [(box: PhoneImageBox, span: NSRange, frame: CGRect)] {
        guard let storage = textStorage else { return [] }
        var found: [(PhoneImageBox, NSRange, CGRect)] = []
        storage.enumerateAttribute(.prismImage, in: characters) { value, range, _ in
            guard let box = value as? PhoneImageBox else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let x = fragment.minX + location(forGlyphAt: glyph).x
            guard let container = textContainers.first else { return }
            let size = box.size(fitting: lineWidth(at: range.location, in: container))
            var end = range.location + 1
            while end < storage.length, storage.attribute(.prismHidden, at: end, effectiveRange: nil) != nil,
                  storage.attribute(.prismImage, at: end, effectiveRange: nil) == nil { end += 1 }
            let start = range.location > 0 && storage.attribute(.prismBreak, at: range.location - 1, effectiveRange: nil) != nil
                ? range.location - 1 : range.location
            found.append((box, NSRange(location: start, length: end - start),
                          CGRect(x: x, y: fragment.minY + PhoneImageBox.margin, width: size.width, height: size.height)))
        }
        return found
    }

    /// Each picture, in the room its character was given.
    private func drawImages(in characters: NSRange, at origin: CGPoint) {
        for (box, _, frame) in images(in: characters) {
            let frame = frame.offsetBy(dx: origin.x, dy: origin.y)
            let path = UIBezierPath(roundedRect: frame, cornerRadius: 8)
            UIGraphicsGetCurrentContext()?.saveGState()
            path.addClip()
            box.image.draw(in: frame)
            UIGraphicsGetCurrentContext()?.restoreGState()
            Ink.rule.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = storage.string as NSString
        let covered = text.paragraphRange(for: characters)
        // Only the rows being drawn: the whole note's would be found anew
        // for every stroke drawn.
        var paragraphs: [NSRange] = []
        var at = covered.location
        while at < min(NSMaxRange(covered), text.length) {
            let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0))
            paragraphs.append(paragraph)
            at = NSMaxRange(paragraph)
        }
        drawImages(in: covered, at: origin)
        defer { drawIcons(in: covered, at: origin) }
        // Pills behind links, as Slack draws them.
        storage.enumerateAttribute(.prismPill, in: covered) { value, range, _ in
            guard value != nil, Self.drawsPills else { return }
            // Behind what shows of it, a pill a line: hidden brackets have no place.
            // A line's pieces of one pill — split by hidden characters — one shape.
            var lines: [CGFloat: CGRect] = [:]
            storage.enumerateAttribute(.prismHidden, in: range) { hidden, part, _ in
                guard hidden == nil, part.length > 0 else { return }
                // Its own glyphs only: a range by characters takes in the
                // hidden glyphs either side, which have no true place.
                let first = glyphIndexForCharacter(at: part.location)
                let last = glyphIndexForCharacter(at: NSMaxRange(part) - 1)
                guard last >= first else { return }
                let glyphs = NSRange(location: first, length: last - first + 1)
                enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, lineGlyphs, _ in
                    let shown = NSIntersectionRange(lineGlyphs, glyphs)
                    guard shown.length > 0 else { return }
                    // From where its first glyph is to where the next one is:
                    // a bounding rect after hidden glyphs comes out wrong.
                    let last = NSMaxRange(shown) - 1
                    let start = fragment.minX + self.location(forGlyphAt: shown.location).x
                    let end = last + 1 < NSMaxRange(lineGlyphs) ? fragment.minX + self.location(forGlyphAt: last + 1).x : used.maxX
                    guard end > start else { return }
                    // Even about the text: as far above its capitals as below
                    // its descenders — not the line's room, which is more above.
                    let font = storage.attribute(.font, at: self.characterIndexForGlyph(at: shown.location), effectiveRange: nil) as? UIFont ?? self.metrics.body
                    let baseline = fragment.minY + self.location(forGlyphAt: shown.location).y
                    let pad = round(font.pointSize * 0.18)
                    let top = baseline - font.capHeight - pad
                    let bottom = baseline - font.descender + pad - round(font.pointSize * 0.06)
                    let rect = CGRect(x: start, y: top, width: end - start, height: bottom - top)
                    let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 0)
                    lines[fragment.minY] = lines[fragment.minY].map { $0.union(pill) } ?? pill
                }
            }
            Ink.pill.setFill()
            for pill in lines.values { UIBezierPath(roundedRect: pill, cornerRadius: 5).fill() }
        }
        for paragraph in paragraphs {
            let row = OutlineText.style(storage, at: paragraph.location).row
            // The row's first glyph shown: hidden markup has no place of its own.
            var first = paragraph.location
            while first < NSMaxRange(paragraph) - 1, storage.attribute(.prismHidden, at: first, effectiveRange: nil) != nil
                    || storage.attribute(.prismBreak, at: first, effectiveRange: nil) != nil { first += 1 }
            let glyph = glyphIndexForCharacter(at: first)
            guard glyph < numberOfGlyphs else { continue }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont ?? metrics.body
            let markerX = metrics.indent * CGFloat(row.depth) + metrics.indent / 2 + origin.x
            let glyphLocation = location(forGlyphAt: glyph)
            // A row that starts with a picture has its marker by the top of it.
            let startsWithImage = storage.attribute(.prismImage, at: first, effectiveRange: nil) != nil
            let baseline = startsWithImage ? line.minY + PhoneImageBox.margin + ceil(font.ascender) : line.minY + glyphLocation.y
            let middle = baseline - font.xHeight / 2
            switch row.kind {
            case .quote:
                let last = glyphRange(forCharacterRange: NSRange(location: NSMaxRange(paragraph) - 1, length: 1), actualCharacterRange: nil)
                let bottom = lineFragmentRect(forGlyphAt: max(last.location, glyph), effectiveRange: nil).maxY + origin.y
                Ink.faint.setFill()
                UIBezierPath(roundedRect: CGRect(x: markerX - 1.5, y: line.minY + 2, width: 3, height: bottom - line.minY - 6), cornerRadius: 1.5).fill()
            case .code:
                let last = glyphRange(forCharacterRange: NSRange(location: NSMaxRange(paragraph) - 1, length: 1), actualCharacterRange: nil)
                let bottom = lineFragmentRect(forGlyphAt: max(last.location, glyph), effectiveRange: nil).maxY + origin.y
                let x = metrics.textIndent(for: row) - 8 + origin.x
                Ink.codeBack.setFill()
                UIBezierPath(roundedRect: CGRect(x: x, y: line.minY, width: container.size.width - x + origin.x - 4, height: bottom - line.minY),
                             cornerRadius: 6).fill()
            case .rule:
                Ink.rule.setFill()
                UIRectFill(CGRect(x: metrics.textIndent(for: row) + origin.x, y: used.midY, width: container.size.width - metrics.textIndent(for: row) - 8, height: 1))
            case .bullet, .ordered:
                if let task = row.task {
                    let side = round(font.pointSize * 0.82)
                    let box = CGRect(x: markerX - side / 2, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side)
                    let round = row.marker == "+"
                    let shape = round ? UIBezierPath(ovalIn: box) : UIBezierPath(roundedRect: box, cornerRadius: 3.5)
                    if task.isDone {
                        Ink.accent.setFill()
                        shape.fill()
                        let tick = UIBezierPath()
                        tick.move(to: CGPoint(x: box.minX + side * 0.27, y: box.midY))
                        tick.addLine(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.68))
                        tick.addLine(to: CGPoint(x: box.minX + side * 0.74, y: box.minY + side * 0.32))
                        tick.lineWidth = 1.8
                        tick.lineCapStyle = .round
                        tick.lineJoinStyle = .round
                        UIColor.white.setStroke()
                        tick.stroke()
                    } else {
                        shape.lineWidth = 1.4
                        Ink.secondary.setStroke()
                        shape.stroke()
                    }
                } else if row.kind == .ordered {
                    let label = NSAttributedString(string: "\(row.number)\(row.marker)", attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: round(font.pointSize * 0.85), weight: .regular),
                        .foregroundColor: Ink.secondary,
                    ])
                    let size = label.size()
                    label.draw(at: CGPoint(x: metrics.textIndent(for: row) + origin.x - size.width - 6, y: baseline - size.height + 3))
                } else {
                    if row.isFolded {
                        Ink.rule.setFill()
                        let ring = round(font.pointSize * 0.75)
                        UIBezierPath(ovalIn: CGRect(x: markerX - ring / 2, y: middle - ring / 2, width: ring, height: ring)).fill()
                    }
                    Ink.secondary.setFill()
                    let dot = max(4.5, round(font.pointSize * 0.3))
                    UIBezierPath(ovalIn: CGRect(x: markerX - dot / 2, y: middle - dot / 2, width: dot, height: dot)).fill()
                }
            default:
                if row.isFolded {
                    Ink.faint.setFill()
                    let dot: CGFloat = 5
                    UIBezierPath(ovalIn: CGRect(x: markerX - dot / 2, y: line.midY - dot / 2, width: dot, height: dot)).fill()
                }
            }
        }
    }
}

// MARK: - The editor

/// An outline, edited: a note's rows as text, one paragraph a row. Return,
/// Delete and the Markdown typed at a row's start do what the outline
/// does; the margin's checkboxes tick, its bullets fold; links open.
final class OutlineEditor: UITextView, UITextViewDelegate, UIGestureRecognizerDelegate {
    let styler: PhoneStyler
    let outlineLayout: PhoneLayoutManager
    /// Told when the rows changed, by typing or otherwise.
    var onChange: (() -> Void)?
    /// Told when a link is tapped: a note's `[[title]]`, or an address.
    var onOpenLink: ((String) -> Void)?
    /// Told when the editor wants another height.
    var onHeightChange: (() -> Void)?
    /// Told when the caret moves in or out: the keyboard's tools follow it.
    var onFocusChange: ((Bool) -> Void)?
    /// Told when the caret moved, or what is around it did: to keep it in sight.
    var onCaretMove: (() -> Void)?
    /// The notes and days a name typed after `@` or `[[` could be: set for
    /// every editor by whoever has the index.
    static var suggest: ((String) -> [LinkSuggestions.Candidate])?
    /// A link being finished: what started it, and where its name starts.
    private var completing: (trigger: LinkSuggestions.Trigger, start: Int)?
    /// Where an `@` or `[` was just typed, to see once it is in whether it starts a link.
    private var typedOpener: Int?
    private var suggestions: [LinkSuggestions.Candidate] = []
    private var toolbar: OutlineToolbar? { inputAccessoryView as? OutlineToolbar }
    private var madeToolbar: OutlineToolbar?

    /// The tools over the keys, made the first time the keys come up: a
    /// sheet has dozens of editors, few ever typed in.
    override var inputAccessoryView: UIView? {
        get {
            if madeToolbar == nil { madeToolbar = OutlineToolbar(editor: self) }
            return madeToolbar
        }
        set {}
    }
    private var adjusting = false
    private var lastHeight: CGFloat = 0
    /// Taps on what the margin draws, and on links.
    private let markerTap = UITapGestureRecognizer()

    var metrics: PhoneMetrics {
        get { styler.metrics }
        set {
            styler.metrics = newValue
            outlineLayout.metrics = newValue
            styler.styleAll(textStorage)
            onHeightChange?()
        }
    }

    /// The characters of the title row not shown, when one is not.
    private var collapsedTitle: NSRange? {
        guard hidesTitle, textStorage.length > 0 else { return nil }
        var title = NSRange()
        guard textStorage.attribute(.prismCollapsed, at: 0, longestEffectiveRange: &title,
                                    in: NSRange(location: 0, length: textStorage.length)) != nil else { return nil }
        return title
    }

    /// Whether its first row, a top heading — the note's title — is not
    /// shown: in a card whose header says it.
    var hidesTitle: Bool {
        get { styler.hidesTitle }
        set {
            guard newValue != styler.hidesTitle else { return }
            styler.hidesTitle = newValue
            guard textStorage.length > 0 else { return }
            adjusting = true
            styler.restyle(textStorage, around: 0)
            adjusting = false
            heightMayHaveChanged()
        }
    }

    init(metrics: PhoneMetrics) {
        styler = PhoneStyler(metrics: metrics)
        outlineLayout = PhoneLayoutManager()
        outlineLayout.metrics = metrics
        let storage = NSTextStorage()
        storage.delegate = styler
        storage.addLayoutManager(outlineLayout)
        let container = NSTextContainer(size: CGSize(width: 320, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        outlineLayout.addTextContainer(container)
        outlineLayout.allowsNonContiguousLayout = true
        if outlineLayout.responds(to: Selector(("setBackgroundLayoutEnabled:"))) {
            outlineLayout.setValue(false, forKey: "backgroundLayoutEnabled")
        }
        super.init(frame: .zero, textContainer: container)
        delegate = self
        // Scrolling on, but never by a finger — the sheet scrolls, and the
        // editor is always as tall as its text: a text view that does not
        // scroll lays its whole text out on each layout pass, to size
        // itself, and a long note lagged on every keystroke.
        isScrollEnabled = true
        // No spaces put in around what is pasted.
        smartInsertDeleteType = .no
        panGestureRecognizer.isEnabled = false
        bounces = false
        scrollsToTop = false
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        tintColor = Ink.accent
        autocorrectionType = .default
        smartDashesType = .no
        smartQuotesType = .no
        keyboardDismissMode = .interactive
        markerTap.addTarget(self, action: #selector(tapped(_:)))
        markerTap.delegate = self
        addGestureRecognizer(markerTap)
        // A picture held: copied, or shared. The text's own presses wait on
        // this one, which lets go at once anywhere but on a picture.
        pictureHold.isOnPicture = { [weak self] point in
            guard let self, case .image = self.target(at: point) else { return false }
            return true
        }
        pictureHold.addTarget(self, action: #selector(heldPicture(_:)))
        pictureHold.delegate = self
        addGestureRecognizer(pictureHold)
        addInteraction(pictureMenu)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
        // Each kept, to be let go with the editor: an observer outlives what
        // it watches, and a storage built later at the same address, off
        // this thread, was taken for this one's.
        observers.append(NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: textStorage, queue: nil) { [weak self] _ in
            guard Thread.isMainThread else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cachedRows = nil
                self.cachedRanges = nil
                guard self.localChanges == 0 else { return }
                self.measured = nil
            }
        })
        // A picture in: shown where this note shows it.
        observers.append(NotificationCenter.default.addObserver(forName: .prismImageLoaded, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let source = note.object as? String else { return }
                // Only the rows showing it, restyled.
                let text = self.textStorage.string as NSString
                var at = text.range(of: source)
                guard at.location != NSNotFound else { return }
                self.adjusting = true
                while at.location != NSNotFound {
                    self.styler.restyle(self.textStorage, around: at.location)
                    let next = NSMaxRange(at)
                    at = text.range(of: source, range: NSRange(location: next, length: text.length - next))
                }
                self.adjusting = false
                self.heightMayHaveChanged()
            }
        })
    }

    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rows

    func load(_ rows: [Row]) {
        adjusting = true
        let text = OutlineText.attributed(rows.isEmpty ? [.blank] : rows)
        // Styled as it goes in — the storage's edit is the styler's to style.
        textStorage.setAttributedString(text)
        adjusting = false
        undoManager?.removeAllActions()
        heightMayHaveChanged()
    }

    /// The rows, as the text now says: kept till the text changes, as many
    /// ask for them — saving, the scrubber, the title — and a long note's
    /// take a while to find.
    // MARK: Built ahead

    /// A note's text, styled and measured off the main thread, to be put in
    /// at once: what makes building a note cost a frame no longer.
    struct Prepared: @unchecked Sendable {
        let text: NSAttributedString
        let width: CGFloat
        let fit: CGFloat
        let rows: CGFloat
        var hidesTitle = false
    }

    /// Styles rows as the editor would, and lays them out at a width, all in
    /// text objects of its own: any thread.
    nonisolated static func prepare(_ rows: [Row], metrics: PhoneMetrics, width: CGFloat, hidesTitle: Bool = false) -> Prepared {
        let styler = PhoneStyler(metrics: metrics)
        styler.hidesTitle = hidesTitle
        let storage = NSTextStorage()
        storage.delegate = styler
        let layout = PhoneLayoutManager()
        layout.metrics = metrics
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.setAttributedString(OutlineText.attributed(rows.isEmpty ? [.blank] : rows))
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let extra = layout.extraLineFragmentRect.height
        // As `sizeThatFits` has it: the text's room and the insets about it.
        let fit = ceil(used + 4)
        let rows = max(0, fit - (extra > 0 ? extra : round(metrics.face.lineHeight * metrics.size)))
        storage.delegate = nil
        return Prepared(text: NSAttributedString(attributedString: storage), width: width, fit: fit, rows: rows, hidesTitle: hidesTitle)
    }

    /// Text built ahead put in, unstyled again, its height taken as found.
    func install(_ prepared: Prepared) {
        adjusting = true
        styler.paused = true
        styler.hidesTitle = prepared.hidesTitle
        textStorage.setAttributedString(prepared.text)
        styler.paused = false
        adjusting = false
        cachedRows = nil
        cachedRanges = nil
        undoManager?.removeAllActions()
        measured = (prepared.width, prepared.fit, prepared.rows)
        showPicturesLoadedMeanwhile()
        heightMayHaveChanged()
    }

    private static let pictureMarkdown = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(<?([^)\s>]+)"#)

    /// Text built off the main thread shows no picture not yet read then:
    /// those read since, shown now; the others asked for, to be shown —
    /// with this editor now here to hear — when they are in.
    private func showPicturesLoadedMeanwhile() {
        let text = textStorage.string as NSString
        guard text.range(of: "![").location != NSNotFound else { return }
        var restyled = Set<Int>()
        adjusting = true
        for match in Self.pictureMarkdown.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
            let at = match.range.location
            guard at + 1 < textStorage.length, textStorage.attribute(.prismImage, at: at + 1, effectiveRange: nil) == nil,
                  PhoneImages.lookup(text.substring(with: match.range(at: 1))) != nil else { continue }
            let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0)).location
            if restyled.insert(paragraph).inserted { styler.restyle(textStorage, around: at) }
        }
        adjusting = false
    }

    var rows: [Row] {
        if let cachedRows { return cachedRows }
        let rows = OutlineText.rows(textStorage)
        cachedRows = rows
        return rows
    }
    private var cachedRows: [Row]?

    /// The first row's style: whether a note opens with its title.
    var firstRow: Row? { textStorage.length > 0 ? OutlineText.style(textStorage, at: 0).row : nil }

    /// Each heading's place and words, from the rows' styles alone.
    var headings: [(location: Int, text: String)] {
        var found: [(Int, String)] = []
        let text = textStorage.string as NSString
        textStorage.enumerateAttribute(.outlineRow, in: NSRange(location: 0, length: textStorage.length)) { value, range, _ in
            guard let style = value as? RowStyle, case .heading = style.row.kind else { return }
            // A run may hold several headings' paragraphs with the same style.
            var at = range.location
            while at < NSMaxRange(range) {
                let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0))
                found.append((paragraph.location, text.substring(with: paragraph).trimmingCharacters(in: .newlines)))
                at = NSMaxRange(paragraph)
            }
        }
        return found
    }

    /// Each row's characters: kept till the text changes.
    var paragraphRanges: [NSRange] {
        if let cachedRanges { return cachedRanges }
        let ranges = OutlineText.paragraphs(textStorage.string as NSString)
        cachedRanges = ranges
        return ranges
    }
    private var cachedRanges: [NSRange]?

    func rowIndex(at location: Int) -> Int {
        let ranges = paragraphRanges
        guard !ranges.isEmpty else { return 0 }
        // The last row starting at or before the place.
        var low = 0, high = ranges.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if ranges[mid].location <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    var caret: OutlineKeys.Caret {
        let location = selectedRange.location
        let index = rowIndex(at: location)
        let ranges = paragraphRanges
        return OutlineKeys.Caret(row: index, offset: ranges.indices.contains(index) ? location - ranges[index].location : 0)
    }

    func setCaret(_ caret: OutlineKeys.Caret) {
        let ranges = paragraphRanges
        guard !ranges.isEmpty else { return }
        let index = min(max(caret.row, 0), ranges.count - 1)
        let range = ranges[index]
        selectedRange = NSRange(location: range.location + min(caret.offset, max(0, range.length - 1)), length: 0)
    }

    /// Replaces the rows on screen with others — only the paragraphs that
    /// differ — as one step to undo, the caret put where it goes.
    func replace(_ after: [Row], caret: OutlineKeys.Caret?, undoName: String? = nil) {
        let before = rows
        let beforeCaret = self.caret
        guard before != after else { return }
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let ranges = paragraphRanges
        let start = prefix < ranges.count ? ranges[prefix].location : textStorage.length
        let end = before.count - suffix > prefix ? NSMaxRange(ranges[before.count - suffix - 1]) : start
        adjusting = true
        textStorage.replaceCharacters(in: NSRange(location: start, length: end - start),
                                      with: OutlineText.attributed(Array(after[prefix..<(after.count - suffix)])))
        adjusting = false
        undoManager?.registerUndo(withTarget: self) { editor in editor.replace(before, caret: beforeCaret, undoName: undoName) }
        if let undoName { undoManager?.setActionName(undoName) }
        if let caret { setCaret(caret) }
        changed()
    }

    private func changed() {
        heightMayHaveChanged()
        onChange?()
        onCaretMove?()
    }

    private func heightMayHaveChanged() {
        // No width yet: nothing to measure at — laying a long note out at a
        // guess, then again at its width, doubled the cost of opening it.
        guard bounds.width > 0 else { return }
        let height = rowsHeight(width: bounds.width)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
    }

    // MARK: Typing

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !adjusting else { return true }
        // A title not shown is not edited — a delete at the next row's start
        // would join that row to it.
        if let title = collapsedTitle, range.location < NSMaxRange(title) { return false }
        plainEdit = false
        // An edit allowed that never came: measured whole again, to be safe.
        if typedRowBefore != nil {
            typedRowBefore = nil
            localChanges -= 1
            measured = nil
        }
        // Only the paragraph typed in, found directly: the rows of the whole
        // note are worked out only for what changes them — on a long note,
        // every keystroke would otherwise go through all of it.
        let storageText = textStorage.string as NSString
        guard storageText.length > 0 else { return true }
        let paragraph = storageText.paragraphRange(for: NSRange(location: min(range.location, storageText.length - 1), length: 0))
        var rows: [Row] { self.rows }
        var index: Int { rowIndex(at: range.location) }
        // Return, while a link is being finished: the first choice put in.
        if text == "\n", completing != nil, let first = suggestions.first {
            accept(first)
            return false
        }
        // Return: the row split, the outline's way.
        if text == "\n" {
            if range.length > 0 { textStorage.replaceCharacters(in: range, with: "") }
            let caret = OutlineKeys.Caret(row: rowIndex(at: range.location), offset: range.location - paragraphRanges[rowIndex(at: range.location)].location)
            if let split = OutlineKeys.split(self.rows, at: caret) {
                replace(split.rows, caret: split.caret, undoName: "New Row")
            } else if rows[index].kind == .code {
                // Within a code block, a line, not a row.
                insertText(OutlineText.lineSeparator)
            }
            return false
        }
        // Delete at a row's start: its type first, then joining the row
        // above. The character deleted is the row above's line break: the
        // row is the caret's.
        // Delete just after a picture: the picture, whole.
        if text.isEmpty, range.length == 1, selectedRange.length == 0,
           let picture = outlineLayout.images(in: paragraph).first(where: { NSMaxRange($0.span) == selectedRange.location }) {
            selectedRange = picture.span
            insertText("")
            return false
        }
        if text.isEmpty, range.length == 1, selectedRange.length == 0,
           selectedRange.location == storageText.paragraphRange(for: NSRange(location: min(selectedRange.location, storageText.length - 1), length: 0)).location {
            let row = rowIndex(at: selectedRange.location)
            do {
                if let plain = OutlineKeys.plain(rows, at: row) {
                    replace(plain, caret: OutlineKeys.Caret(row: row, offset: 0), undoName: "Change Row Type")
                    return false
                }
                if row == 0 { return false }
            }
        }
        // A space after Markdown typed at a row's start: the row's type.
        if text == " ", range.length == 0, range.location - paragraph.location <= 6 {
            let prefix = storageText.substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
            if !prefix.isEmpty, !prefix.contains(" "), let typed = OutlineKeys.smartType(rows, at: index, typed: prefix) {
                replace(typed, caret: OutlineKeys.Caret(row: index, offset: 0), undoName: "Change Row Type")
                return false
            }
        }
        // Pasted: without the spaces and line breaks around it — copied
        // links often carry one, and a row would open with an empty line —
        // and lines within it, lines of the row, not rows.
        if text.count > 1 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != text || trimmed.contains("\n") {
                if !trimmed.isEmpty { insertText(trimmed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: OutlineText.lineSeparator)) }
                return false
            }
        }
        // What is typed is of the row it is typed in: an empty row's style
        // is its line break's, not the one before it.
        // Only at a row's start, where the character before is another
        // row's: even reading them re-lays the whole text out, each key.
        // Within a row, what is typed takes the row's style from the text.
        if range.location == paragraph.location {
            let rowAttributes = textStorage.attributes(at: NSMaxRange(paragraph) - 1, effectiveRange: nil)
            if !NSDictionary(dictionary: typingAttributes).isEqual(to: rowAttributes) { typingAttributes = rowAttributes }
        }
        if text == "@" || text == "[" { typedOpener = range.location }
        // Typing within a row leaves the outline as it was: no tidying after,
        // and only that row measured again.
        plainEdit = !text.contains("\n") && !text.contains(OutlineText.lineSeparator)
            && NSMaxRange(range) < NSMaxRange(paragraph) && range.location >= paragraph.location
        if plainEdit, measured != nil {
            typedRowBefore = (paragraph.location, height(ofParagraphsIn: paragraph))
            localChanges += 1
        }
        return true
    }

    /// Whether the edit under way is typing within one row.
    private var plainEdit = false
    /// The row typed in, and its height before.
    private var typedRowBefore: (location: Int, height: CGFloat)?

    func textViewDidChange(_ textView: UITextView) {
        if let before = typedRowBefore {
            typedRowBefore = nil
            localChanges -= 1
            if var measured {
                let delta = height(ofParagraphsIn: NSRange(location: min(before.location, max(0, textStorage.length - 1)), length: 0)) - before.height
                measured.fit += delta
                measured.rows += delta
                self.measured = measured
            }
        }
        if !plainEdit || !styler.orphans.isEmpty { tidy() }
        plainEdit = false
        changed()
        if let opener = typedOpener {
            typedOpener = nil
            beginCompletion(typedAt: opener)
        }
        refreshCompletion()
    }

    // MARK: Finishing links

    /// `@` at a word's start, or `[[`, just typed outside code: a link to finish.
    private func beginCompletion(typedAt location: Int) {
        guard completing == nil, Self.suggest != nil, location < textStorage.length,
              let trigger = LinkSuggestions.trigger(in: textStorage.string as NSString, typedAt: location) else { return }
        if case .code = rows[rowIndex(at: location)].kind { return }
        if textStorage.attribute(.font, at: location, effectiveRange: nil).map({ ($0 as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true }) == true { return }
        completing = (trigger, location + 1)
    }

    /// The choices for what is typed now — or none, the link left.
    private func refreshCompletion() {
        guard let completing else { return }
        guard selectedRange.length == 0,
              let query = LinkSuggestions.query(in: textStorage.string as NSString, start: completing.start,
                                                caret: selectedRange.location, trigger: completing.trigger) else { return endCompletion() }
        var found = Self.suggest?(query) ?? []
        // After `[[`, a name nothing has yet: a note to make by following it.
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if completing.trigger == .brackets, !trimmed.isEmpty, !found.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            found.append(.init(title: "New “\(trimmed)”", name: trimmed, isDay: false))
        }
        suggestions = found
        toolbar?.show(found) { [weak self] candidate in self?.accept(candidate) }
    }

    private func endCompletion() {
        guard completing != nil else { return }
        completing = nil
        suggestions = []
        toolbar?.show([], choose: { _ in })
    }

    /// A choice put in, as `[[Name]]`, over what was typed for it.
    private func accept(_ candidate: LinkSuggestions.Candidate) {
        guard let completing else { return }
        let put = LinkSuggestions.accepting(candidate, in: textStorage.string as NSString, start: completing.start,
                                           caret: selectedRange.location, trigger: completing.trigger)
        endCompletion()
        selectedRange = put.range
        insertText(put.text)
    }

    /// Where the caret is, in the editor.
    var caretRect: CGRect? {
        guard isFirstResponder, let end = selectedTextRange?.end else { return nil }
        return caretRect(for: end)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        // Never in a row not shown: to the start of the next.
        if let title = collapsedTitle, selectedRange.location < NSMaxRange(title) {
            selectedRange = NSRange(location: NSMaxRange(title), length: 0)
            return
        }
        // A selection touching a picture takes all of it: its Markdown is
        // mostly hidden, and a cut or a paste would leave half of it.
        if selectedRange.length > 0, NSMaxRange(selectedRange) <= textStorage.length {
            let paragraphs = (textStorage.string as NSString).paragraphRange(for: selectedRange)
            var widened = selectedRange
            for picture in outlineLayout.images(in: paragraphs) where NSIntersectionRange(picture.span, widened).length > 0 {
                widened = NSUnionRange(widened, picture.span)
            }
            if widened != selectedRange {
                selectedRange = widened
                return
            }
        }
        onCaretMove?()
        if completing != nil, typedOpener == nil { refreshCompletion() }
        // The span the caret is in shows its marks; the one it left, not.
        let old = styler.caret
        styler.caret = selectedRange.length == 0 ? selectedRange.location : nil
        guard old != styler.caret else { return }
        let last = max(0, textStorage.length - 1)
        let around = [old, styler.caret].compactMap { $0.map { min($0, last) } }
        let text = textStorage.string as NSString
        // One row restyled once, though the caret moved within it.
        let rows = around.count == 2 && text.paragraphRange(for: NSRange(location: around[0], length: 0)).location
            == text.paragraphRange(for: NSRange(location: around[1], length: 0)).location ? [around[0]] : around
        locally(at: rows) {
            for location in rows { styler.restyle(textStorage, around: location) }
        }
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        StallWatch.mark("editing begun")
        onFocusChange?(true)
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        endCompletion()
        onFocusChange?(false)
    }

    /// What an edit can leave wrong put right: the text ends in a line
    /// break, rows an edit swallowed come back, and every row sits at a
    /// depth Markdown can write.
    private func tidy() {
        if textStorage.length == 0 || !textStorage.string.hasSuffix("\n") {
            let style = textStorage.length > 0 ? OutlineText.style(textStorage, at: textStorage.length - 1) : RowStyle(.blank)
            let selection = selectedRange
            adjusting = true
            textStorage.append(NSAttributedString(string: "\n", attributes: [.outlineRow: style]))
            adjusting = false
            selectedRange = selection
        }
        let orphans = styler.orphans
        styler.orphans = []
        var after = rows
        let before = after
        for orphan in orphans.reversed() {
            let index = rowIndex(at: min(orphan.location, max(0, textStorage.length - 1)))
            after.insert(contentsOf: orphan.rows, at: index + 1)
        }
        OutlineEditing.normalize(&after)
        if after != before { replace(after, caret: caret) }
    }

    // MARK: Outline commands

    /// The rows the selection covers.
    var selectedRowRange: Range<Int> {
        let first = rowIndex(at: selectedRange.location)
        let last = rowIndex(at: max(selectedRange.location, NSMaxRange(selectedRange) - (selectedRange.length > 0 ? 1 : 0)))
        return first..<(last + 1)
    }

    private func perform(_ name: String, _ change: (inout [Row], Range<Int>) -> Range<Int>?) {
        let caret = self.caret
        var all = rows
        let selection = selectedRowRange
        guard let moved = change(&all, selection) else { return }
        replace(all, caret: OutlineKeys.Caret(row: moved.lowerBound + (caret.row - selection.lowerBound), offset: caret.offset), undoName: name)
    }

    @objc func indent() { perform("Indent") { OutlineEditing.indent(&$0, $1) } }
    @objc func outdent() { perform("Outdent") { OutlineEditing.outdent(&$0, $1) } }
    @objc func moveUp() {
        // Not above a title not shown: it stays the note's first row.
        if collapsedTitle != nil, selectedRowRange.lowerBound <= 1 { return }
        perform("Move Up") { OutlineEditing.moveUp(&$0, $1) }
    }
    @objc func moveDown() { perform("Move Down") { OutlineEditing.moveDown(&$0, $1) } }

    @objc func cycleChecklist() {
        let caret = self.caret
        var all = rows
        OutlineEditing.cycle(.checklist, &all, selectedRowRange)
        replace(all, caret: caret, undoName: "Checklist Item")
    }

    @objc func toggleDone() {
        var all = rows
        OutlineEditing.toggleDone(&all, selectedRowRange)
        replace(all, caret: caret, undoName: "Toggle Done")
    }

    /// A task — Reflect's round `+ [ ]`, gathered in Tasks — then done,
    /// then a plain row again.
    @objc func cycleTask() {
        let caret = self.caret
        var all = rows
        OutlineEditing.cycle(.task, &all, selectedRowRange)
        replace(all, caret: caret, undoName: "Task")
    }

    func toggleFold(at index: Int) {
        var all = rows
        guard all.indices.contains(index) else { return }
        if all[index].isFolded {
            _ = OutlineEditing.unfold(&all, at: index)
        } else {
            guard OutlineEditing.hasChildren(all, index) else { return }
            _ = OutlineEditing.fold(&all, at: index)
        }
        let caret = self.caret.row > index && self.caret.row <= OutlineEditing.subtreeEnd(rows, index) - 1
            ? OutlineKeys.Caret(row: index, offset: 0) : self.caret
        replace(all, caret: caret, undoName: "Fold")
    }

    /// `[[`, to link a note: the brackets typed, the caret between them.
    @objc func insertLink() {
        insertText("[[]]")
        selectedRange = NSRange(location: selectedRange.location - 2, length: 0)
    }

    // MARK: Taps and swipes

    /// What a tap at a point is on: a row's marker, or a link.
    private enum Target {
        case marker(Int)
        case link(String)
        /// A picture: its Markdown's range.
        case image(NSRange)
    }

    private func target(at point: CGPoint) -> Target? {
        guard textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = outlineLayout.glyphIndex(for: inContainer, in: textContainer)
        let character = outlineLayout.characterIndexForGlyph(at: glyph)
        let index = rowIndex(at: character)
        let row = OutlineText.style(textStorage, at: paragraphRanges[index].location).row
        let line = outlineLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard inContainer.y >= line.minY - 4, inContainer.y <= line.maxY + 4 else { return nil }
        if let picture = outlineLayout.images(in: paragraphRanges[index]).first(where: { $0.frame.contains(inContainer) }) {
            return .image(picture.span)
        }
        if inContainer.x < metrics.textIndent(for: row) - 2, inContainer.x > metrics.indent * CGFloat(row.depth) - 6 {
            return .marker(index)
        }
        let glyphRect = outlineLayout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard glyphRect.insetBy(dx: -4, dy: -4).contains(inContainer), character < textStorage.length,
              let link = textStorage.attribute(.prismLink, at: character, effectiveRange: nil) as? String else { return nil }
        // A link being written — the caret in it — is text, not a way out.
        if isFirstResponder, let caret = styler.caret, abs(caret - character) <= 1 { return nil }
        return .link(link)
    }

    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if gesture === markerTap { return target(at: gesture.location(in: self)) != nil }
        // A row swiped in or out only while typing in it: otherwise a
        // swipe goes between the columns.
        if gesture is UISwipeGestureRecognizer { return isFirstResponder }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gesture === pictureHold && other.view === self && other !== markerTap
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture is UISwipeGestureRecognizer
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        switch target(at: gesture.location(in: self)) {
        case .marker(let index):
            let row = rows[index]
            if row.task != nil {
                if let toggled = OutlineKeys.toggle(rows, at: index) {
                    replace(toggled, caret: isFirstResponder ? caret : nil, undoName: "Toggle Done")
                }
            } else {
                toggleFold(at: index)
            }
            UISelectionFeedbackGenerator().selectionChanged()
        case .link(let link):
            onOpenLink?(link)
        case .image(let span):
            // The caret after it, the picture still shown: its Markdown is
            // for the caret to go into, not for a tap.
            if !isFirstResponder { becomeFirstResponder() }
            selectedRange = NSRange(location: NSMaxRange(span), length: 0)
        case nil:
            break
        }
    }

    // MARK: Pictures in and out

    /// Paste offered for pictures too: a text view takes only text.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    /// Pictures pasted — when there is no text with them — kept in the
    /// graph's `assets/`, as the Mac keeps them, and put where the caret is.
    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        guard board.hasImages, !board.hasStrings, let root = PhoneImages.root else { return super.paste(sender) }
        var markdown: [String] = []
        for picture in Self.pictures(on: board) {
            do {
                let path = try Assets.add(picture.data, named: Assets.pastedName(extension: picture.ext), to: root)
                markdown.append("![](\(path))")
            } catch {
                continue
            }
        }
        guard !markdown.isEmpty else { return super.paste(sender) }
        insertText(markdown.joined(separator: " "))
    }

    /// Each picture on the pasteboard, as its own bytes when they are a
    /// type a note keeps — PNG, JPEG, GIF — else made a JPEG (a photo's HEIC).
    private static func pictures(on board: UIPasteboard) -> [(data: Data, ext: String)] {
        let kept: [(UTType, String)] = [(.png, "png"), (.jpeg, "jpg"), (.gif, "gif")]
        return (0..<board.numberOfItems).compactMap { index -> (Data, String)? in
            let item = IndexSet(integer: index)
            // The bytes as they are, not as UIKit hands pictures back.
            for (type, ext) in kept {
                if let data = board.data(forPasteboardType: type.identifier, inItemSet: item)?.first { return (data, ext) }
            }
            let types = board.types(forItemSet: item)?.first ?? []
            for type in types where UTType(type)?.conforms(to: .image) == true {
                if let data = board.data(forPasteboardType: type, inItemSet: item)?.first,
                   let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                    return (jpeg, "jpg")
                }
            }
            return nil
        }
    }

    private let pictureHold = PictureHold()
    private lazy var pictureMenu = UIEditMenuInteraction(delegate: self)

    @objc private func heldPicture(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, case .image(let span) = target(at: gesture.location(in: self)),
              let frame = pictureFrame(span) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let configuration = UIEditMenuConfiguration(identifier: NSStringFromRange(span) as NSString,
                                                    sourcePoint: CGPoint(x: frame.midX, y: frame.minY))
        pictureMenu.presentEditMenu(with: configuration)
    }

    /// The file a picture's Markdown shows, in the graph.
    private func pictureFile(_ span: NSRange) -> URL? {
        guard NSMaxRange(span) <= textStorage.length else { return nil }
        let markdown = (textStorage.string as NSString).substring(with: span)
        guard let open = markdown.range(of: "]("), let close = markdown.range(of: ")", options: .backwards),
              open.upperBound <= close.lowerBound else { return nil }
        var source = String(markdown[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        // `![](path "title")` and `![](<path>)` alike.
        if let space = source.firstIndex(of: " ") { source = String(source[..<space]) }
        source = source.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return PhoneImages.url(for: source).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    private func copyPicture(_ file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        let type = UTType(filenameExtension: file.pathExtension) ?? .image
        UIPasteboard.general.setItems([[type.identifier: data]])
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func sharePicture(_ file: URL, from rect: CGRect) {
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = self
        share.popoverPresentationController?.sourceRect = rect
        presenter?.present(share, animated: true)
    }

    /// Where a picture is drawn, in the editor, by its Markdown's range.
    private func pictureFrame(_ span: NSRange) -> CGRect? {
        let paragraph = (textStorage.string as NSString).paragraphRange(for: NSRange(location: span.location, length: 0))
        guard let frame = outlineLayout.images(in: paragraph).first(where: { $0.span == span })?.frame else { return nil }
        return frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    /// A row swiped right goes in a level; left, out.
    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let point = gesture.location(in: self)
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = outlineLayout.glyphIndex(for: inContainer, in: textContainer)
        let index = rowIndex(at: outlineLayout.characterIndexForGlyph(at: glyph))
        var all = rows
        let caret = self.caret
        let moved = gesture.direction == .right ? OutlineEditing.indent(&all, index..<(index + 1)) : OutlineEditing.outdent(&all, index..<(index + 1))
        guard moved != nil else { return }
        replace(all, caret: isFirstResponder ? caret : nil, undoName: gesture.direction == .right ? "Indent" : "Outdent")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// As tall as its rows are at a width: not the empty line after the
    /// last one's break, which the caret never goes to.
    func rowsHeight(width: CGFloat) -> CGFloat { measure(width).rows }

    /// How tall it is at a width — the empty line after the last row
    /// included — as its frame wants.
    func fittingHeight(width: CGFloat) -> CGFloat { measure(width).fit }

    /// The last measurement, kept till the text or its look changes: laying
    /// a note out is the dearest thing done, and a sheet asks every note
    /// its height each time any one changes.
    private var measured: (width: CGFloat, fit: CGFloat, rows: CGFloat)?

    /// Changes under way known to stay within some rows: the measurement
    /// is moved by what they do to those rows, not taken again.
    private var localChanges = 0

    /// How tall some rows are laid out: their lines alone, laid out alone.
    private func height(ofParagraphsIn range: NSRange) -> CGFloat {
        let text = textStorage.string as NSString
        guard text.length > 0 else { return 0 }
        let paragraphs = text.paragraphRange(for: NSRange(location: min(range.location, text.length - 1),
                                                          length: max(0, min(range.length, text.length - min(range.location, text.length - 1)))))
        let glyphs = outlineLayout.glyphRange(forCharacterRange: paragraphs, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return 0 }
        var height: CGFloat = 0
        outlineLayout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in height += rect.height }
        return height
    }

    /// A change that stays within the rows about `locations` — typing in a
    /// row, a row restyled for the caret — made, and the measurement moved
    /// by the difference in those rows: laying a long note out again whole,
    /// for each keystroke, is what made typing in one lag.
    private func locally(at locations: [Int], _ change: () -> Void) {
        guard measured != nil else { return change() }
        let before = locations.map { height(ofParagraphsIn: NSRange(location: $0, length: 0)) }.reduce(0, +)
        localChanges += 1
        change()
        localChanges -= 1
        guard var measured = self.measured else { return }
        let length = textStorage.length
        let after = locations.map { height(ofParagraphsIn: NSRange(location: min($0, max(0, length - 1)), length: 0)) }.reduce(0, +)
        measured.fit += after - before
        measured.rows += after - before
        self.measured = measured
    }

    private func measure(_ width: CGFloat) -> (fit: CGFloat, rows: CGFloat) {
        if let measured, abs(measured.width - width) < 0.5 { return (measured.fit, measured.rows) }
        // At the width it is measured for, first: the container follows the
        // frame, and a frame set after would lay the whole text out again.
        if abs(bounds.width - width) >= 0.5 { frame.size.width = width }
        outlineLayout.ensureLayout(for: textContainer)
        // As `sizeThatFits` has it: the text's room and the insets about it.
        let fit = ceil(outlineLayout.usedRect(for: textContainer).height + textContainerInset.top + textContainerInset.bottom)
        let extra = outlineLayout.extraLineFragmentRect.height
        let rows = max(0, fit - (extra > 0 ? extra : round(metrics.face.lineHeight * metrics.size)))
        measured = (width, fit, rows)
        return (fit, rows)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: lastHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        heightMayHaveChanged()
    }
}

/// Over the keyboard: what an outline wants that the keys do not have.
final class OutlineToolbar: UIInputView {
    init(editor: OutlineEditor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 46), inputViewStyle: .keyboard)
        let items: [(String, Selector, String)] = [
            ("decrease.indent", #selector(OutlineEditor.outdent), "Outdent"),
            ("increase.indent", #selector(OutlineEditor.indent), "Indent"),
            ("arrow.up", #selector(OutlineEditor.moveUp), "Move Up"),
            ("arrow.down", #selector(OutlineEditor.moveDown), "Move Down"),
            ("checkmark.square", #selector(OutlineEditor.cycleChecklist), "Checklist"),
            ("checkmark.circle", #selector(OutlineEditor.cycleTask), "Task"),
            ("link", #selector(OutlineEditor.insertLink), "Link"),
            ("keyboard.chevron.compact.down", #selector(UIResponder.resignFirstResponder), "Done"),
        ]
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (symbol, action, label) in items {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
            button.tintColor = Ink.text
            button.accessibilityLabel = label
            button.addTarget(editor, action: action, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        backgroundColor = Ink.paper
        let rule = UIView()
        rule.backgroundColor = Ink.rule
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        addSubview(stack)
        NSLayoutConstraint.activate([
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        autoresizingMask = .flexibleHeight
        tools = stack
        chips.showsHorizontalScrollIndicator = false
        chips.isHidden = true
        chips.translatesAutoresizingMaskIntoConstraints = false
        chipRow.axis = .horizontal
        chipRow.spacing = 8
        chipRow.translatesAutoresizingMaskIntoConstraints = false
        chips.addSubview(chipRow)
        addSubview(chips)
        NSLayoutConstraint.activate([
            chips.leadingAnchor.constraint(equalTo: leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: trailingAnchor),
            chips.topAnchor.constraint(equalTo: topAnchor),
            chips.bottomAnchor.constraint(equalTo: bottomAnchor),
            chipRow.leadingAnchor.constraint(equalTo: chips.contentLayoutGuide.leadingAnchor, constant: 10),
            chipRow.trailingAnchor.constraint(equalTo: chips.contentLayoutGuide.trailingAnchor, constant: -10),
            chipRow.centerYAnchor.constraint(equalTo: chips.frameLayoutGuide.centerYAnchor),
            chipRow.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private var tools: UIView?
    private let chips = UIScrollView()
    private let chipRow = UIStackView()

    /// Links to choose from, in place of the tools — the first, which
    /// Return puts in, marked — or, with none, the tools again.
    func show(_ candidates: [LinkSuggestions.Candidate], choose: @escaping (LinkSuggestions.Candidate) -> Void) {
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, candidate) in candidates.enumerated() {
            var configuration = UIButton.Configuration.filled()
            configuration.title = candidate.title
            configuration.image = UIImage(systemName: candidate.isDay ? "calendar" : candidate.title.hasPrefix("New “") ? "plus" : "doc.text",
                                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            configuration.imagePadding = 5
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = i == 0 ? Ink.accent : Ink.pill
            configuration.baseForegroundColor = i == 0 ? .white : Ink.text
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = UIFont.systemFont(ofSize: 15, weight: i == 0 ? .semibold : .regular)
                return attributes
            }
            let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in choose(candidate) })
            button.accessibilityLabel = "Link to " + candidate.title
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            chipRow.addArrangedSubview(button)
        }
        chips.isHidden = candidates.isEmpty
        tools?.isHidden = !candidates.isEmpty
        chips.contentOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

extension OutlineEditor: UIEditMenuInteractionDelegate {
    /// Copy and Share, for the picture held.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let id = configuration.identifier as? NSString else { return nil }
        let span = NSRangeFromString(id as String)
        guard let file = pictureFile(span) else { return nil }
        let rect = pictureFrame(span) ?? .zero
        return UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyPicture(file) },
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.sharePicture(file, from: rect) },
        ])
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let id = configuration.identifier as? NSString else { return .null }
        return pictureFrame(NSRangeFromString(id as String)) ?? .null
    }
}

/// A long press that is only ever on a picture: anywhere else it fails as
/// the finger comes down, and what waits on it goes on as if it were not there.
final class PictureHold: UILongPressGestureRecognizer {
    var isOnPicture: ((CGPoint) -> Bool)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        if let touch = touches.first, isOnPicture?(touch.location(in: view)) != true { state = .failed }
    }
}
