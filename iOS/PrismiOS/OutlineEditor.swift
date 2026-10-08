import UIKit
import UIKit.UIGestureRecognizerSubclass
import UniformTypeIdentifiers
import ReflectCore
import PrismCore

extension NSAttributedString.Key {
    /// Markup not shown: a span's marks, while the caret is away from it.
    static let prismHidden = NSAttributedString.Key("PrismHidden")
    /// A typed arrow's last character: drawn as the arrow it makes.
    static let prismArrow = NSAttributedString.Key("PrismArrow")
    /// Words drawn in capitals — a heading, set so — whatever case they are written in.
    static let prismUppercase = NSAttributedString.Key("PrismUppercase")
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
    /// On a link to a post or a video, once its card is in: the link, its
    /// card drawn under the row it is in.
    static let prismCard = NSAttributedString.Key("PrismCard")
    /// On a row not shown at all, its line no height: a note's title row,
    /// in a card whose header says it already.
    static let prismCollapsed = NSAttributedString.Key("PrismCollapsed")
}

/// The type and measures of the outline: a face at a size.
struct PhoneMetrics: Equatable {
    var face: Typeface = .current
    var size: CGFloat = 17
    /// How the face is set: its own defaults, as changed in Settings.
    var spacing: PhoneSpacing

    init(face: Typeface = .current, size: CGFloat = 17, spacing: PhoneSpacing? = nil) {
        self.face = face
        self.size = size
        self.spacing = spacing ?? PhoneSpacing.of(face)
    }

    var body: UIFont { face.body(face.size(size)) }
    var code: UIFont { face.mono(round(face.size(size) * 0.88)) }
    var indent: CGFloat { round(size * CGFloat(spacing.indent)) }
    /// Each line's height, in ems.
    var lineHeight: CGFloat { CGFloat(spacing.lineHeight) }
    /// The space after each row, in points.
    var rowGap: CGFloat { round(size * CGFloat(spacing.rowSpacing)) }

    /// Whether headings are drawn in capitals the text does not have: all
    /// caps, or small caps made so for a face without its own.
    var headingsInCapitals: Bool {
        spacing.headingCase == .caps || (spacing.headingCase == .smallCaps && !headingHasSmallCaps)
    }

    var headingHasSmallCaps: Bool {
        let font = face.heading(12, weight: .bold)
        guard let table = CTFontCopyTable(font as CTFont, CTFontTableTag(kCTFontTableGSUB), []) as Data? else { return false }
        return table.range(of: Data("smcp".utf8)) != nil
    }

    func heading(_ level: Int) -> UIFont {
        let text = face.size(size)
        switch spacing.headingCase ?? .family {
        case .family:
            break
        case .bold:
            // At the text's size: bold says it is a heading.
            return face.heading(text, weight: .bold)
        case .smallCaps where headingHasSmallCaps:
            // The face's own small capitals, its capitals small too.
            let font = face.heading(round(text * (level == 1 ? 1.08 : 1)), weight: .bold)
            let features: [[UIFontDescriptor.FeatureKey: Int]] = [
                [.type: kLowerCaseType, .selector: kLowerCaseSmallCapsSelector],
                [.type: kUpperCaseType, .selector: kUpperCaseSmallCapsSelector],
            ]
            return UIFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: features]), size: font.pointSize)
        case .smallCaps, .caps:
            // Capitals, set small: as tall as the text's small letters, near enough.
            return face.heading(round(text * CGFloat(HeadingCase.capitalsScale(level: level))), weight: .bold)
        }
        // A first-level heading as large as set; the others stepping down to the text's size.
        let top = CGFloat(spacing.headingScale)
        let scale: CGFloat = [top, 1 + (top - 1) * 0.55, 1 + (top - 1) * 0.22, 1.0, 1.0, 1.0][min(max(level, 1), 6) - 1]
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
    /// The time blocks' slots, by where their paragraphs start: worked out
    /// before each styling.
    private var slots: [Int: PhoneTimeSlot] = [:]

    init(metrics: PhoneMetrics) {
        self.metrics = metrics
    }

    /// While set, edits are taken as already styled: text styled elsewhere
    /// being put in whole.
    var paused = false

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorage.EditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard storage.length > 0, !paused else { return }
        let text = storage.mutableString
        var range = text.paragraphRange(for: NSRange(location: min(edited.location, text.length), length: min(edited.length, text.length - min(edited.location, text.length))))
        if NSMaxRange(range) < text.length {
            range = NSUnionRange(range, text.paragraphRange(for: NSRange(location: NSMaxRange(range), length: 0)))
        }
        if mask.contains(.editedCharacters) { unify(storage, in: range, inserted: edited) }
        slots = PhoneTimeSlot.slots(storage, metrics: metrics, caret: caret)
        style(storage, in: range)
        // A row edited can make or unmake its list a timeline, or move the
        // blocks after it: those whose slots changed are styled again.
        if mask.contains(.editedCharacters) { restyleChangedSlots(storage, besides: range) }
    }

    private func restyleChangedSlots(_ storage: NSTextStorage, besides done: NSRange) {
        let text = storage.mutableString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            if NSIntersectionRange(paragraph, done).length > 0 { continue }
            let current = storage.attribute(.prismTimeSlot, at: paragraph.location, effectiveRange: nil) as? PhoneTimeSlot
            let wanted = slots[paragraph.location]
            if current == nil && wanted == nil { continue }
            if let current, let wanted, current.isEqual(wanted) { continue }
            style(storage, in: paragraph)
        }
    }

    func styleAll(_ storage: NSTextStorage) {
        slots = PhoneTimeSlot.slots(storage, metrics: metrics, caret: caret)
        storage.beginEditing()
        style(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    func restyle(_ storage: NSTextStorage, around location: Int) {
        guard storage.length > 0 else { return }
        let text = storage.mutableString
        let paragraph = text.paragraphRange(for: NSRange(location: min(location, text.length - 1), length: 0))
        slots = PhoneTimeSlot.slots(storage, metrics: metrics, caret: caret)
        storage.beginEditing()
        style(storage, in: paragraph)
        storage.endEditing()
    }

    /// The style of the row an edit under way began in: what the row stays,
    /// when all of it is what was typed — an accepted suggestion, a picture
    /// pasted — and the typed text came styled as some other row.
    var editingRow: (location: Int, style: RowStyle)?

    private func unify(_ storage: NSTextStorage, in range: NSRange, inserted: NSRange) {
        let text = storage.mutableString
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
            let began = editingRow.flatMap { NSLocationInRange($0.location, paragraph) || $0.location == paragraph.location ? $0.style : nil }
            let style = winner ?? began ?? styles.last ?? RowStyle(.blank)
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
        let text = storage.mutableString
        for paragraph in OutlineText.paragraphs(text.substring(with: range) as NSString) {
            let paragraph = NSRange(location: paragraph.location + range.location, length: paragraph.length)
            let style = Self.rowStyle(storage, paragraph)
            let row = style.row
            let previous = paragraph.location > 0 ? OutlineText.style(storage, at: paragraph.location - 1).row : nil
            let slot = slots[paragraph.location]
            var attributes = attributes(for: row, after: previous)
            if let slot, slot.mark.head != nil {
                // Room over a block's words for its time and length.
                attributes[.prismSpaceBefore] = (attributes[.prismSpaceBefore] as? CGFloat ?? 0) + slot.measures.header
            }
            storage.setAttributes(attributes, range: paragraph)
            storage.addAttribute(.outlineRow, value: style, range: paragraph)
            if let slot { storage.addAttribute(.prismTimeSlot, value: slot, range: paragraph) }
            switch row.kind {
            case .code, .rule: break
            default: styleInline(storage, in: paragraph, row: row)
            }
            // Headings in capitals the text does not have: drawn so, a little apart.
            if case .heading = row.kind, metrics.headingsInCapitals, paragraph.length > 1 {
                let words = NSRange(location: paragraph.location, length: paragraph.length - 1)
                storage.addAttribute(.prismUppercase, value: true, range: words)
                storage.addAttribute(.kern, value: round(metrics.size * CGFloat(HeadingCase.capitalsTracking) * 10) / 10, range: words)
            }
            // A block's time is told at its left; written out only where the caret is.
            if let slot, let stamp = slot.mark.head?.stamp, !slot.revealed, stamp.fullRange.length < paragraph.length {
                let hidden = NSRange(location: paragraph.location, length: stamp.fullRange.length)
                storage.addAttribute(.prismHidden, value: true, range: hidden)
                // A done block's line through its words only: hidden, the time
                // is laid out at the line's start, and a line through it would
                // reach across the times.
                storage.removeAttribute(.strikethroughStyle, range: hidden)
            }
            // Nor through the line break, which a block's foot pushes far down.
            if slot != nil, paragraph.length > 0 {
                storage.removeAttribute(.strikethroughStyle, range: NSRange(location: NSMaxRange(paragraph) - 1, length: 1))
            }
            if hidesTitle, paragraph.location == 0, case .heading(1) = row.kind, NSMaxRange(paragraph) < text.length {
                collapse(storage, paragraph)
            }
            storage.fixAttributes(in: paragraph)
        }
    }

    /// A paragraph's row, from whichever of its characters still says it.
    /// Autocorrect styles the word it puts in afresh, the row's style
    /// dropped from it: read from the row's first character alone, that
    /// row became a plain one at the top — the first word corrected, the
    /// row outdented.
    static func rowStyle(_ storage: NSTextStorage, _ paragraph: NSRange) -> RowStyle {
        var found: RowStyle?
        storage.enumerateAttribute(.outlineRow, in: paragraph) { value, _, stop in
            if let style = value as? RowStyle {
                found = style
                stop.pointee = true
            }
        }
        return found ?? RowStyle(.blank)
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
        paragraph.lineHeightMultiple = row.kind == .code ? 1.2 : metrics.lineHeight * metrics.size / max(font.lineHeight, 1)
        paragraph.paragraphSpacing = metrics.rowGap
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

    /// A picture's part in a carousel: its first, with all its pictures; or
    /// a later one, hidden from where the one before it ends.
    private enum CarouselPart {
        case first([(source: String, image: UIImage)])
        case member(from: Int)
    }

    /// The carousels among a row's spans — pictures written side by side,
    /// nothing but space between, two or more — by where each picture is.
    /// A picture the caret is in is its Markdown, and parts them.
    private func carousels(in spans: [InlineSpan], text: NSString) -> [Int: CarouselPart] {
        var result: [Int: CarouselPart] = [:]
        var run: [(range: NSRange, source: String, image: UIImage)] = []
        func finish() {
            defer { run.removeAll() }
            guard run.count >= 2 else { return }
            result[run[0].range.location] = .first(run.map { ($0.source, $0.image) })
            for (previous, member) in zip(run, run.dropFirst()) {
                result[member.range.location] = .member(from: NSMaxRange(previous.range))
            }
        }
        for span in spans {
            guard case .image(let reference) = span.kind, span.range.length > 2,
                  Tweet.key(from: reference.source) == nil, Video.id(from: reference.source) == nil,
                  !(caret.map { $0 > span.range.location && $0 < NSMaxRange(span.range) } ?? false),
                  let image = PhoneImages.lookup(reference.source) else {
                // Anything shown between two pictures parts them.
                if span.kind != .comment { finish() }
                continue
            }
            if let last = run.last {
                let gap = NSRange(location: NSMaxRange(last.range), length: span.range.location - NSMaxRange(last.range))
                if gap.length < 0 || !text.substring(with: gap).trimmingCharacters(in: .whitespaces).isEmpty { finish() }
            }
            run.append((span.range, reference.source, image))
        }
        finish()
        return result
    }

    /// The inline Markdown in a row, drawn: its marks hidden — but for the
    /// span the caret is in — links as pills, and the rest as it reads.
    private func styleInline(_ storage: NSTextStorage, in paragraph: NSRange, row: Row) {
        let text = storage.mutableString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        let base = metrics.font(for: row)
        func font(at location: Int) -> UIFont { storage.attribute(.font, at: location, effectiveRange: nil) as? UIFont ?? base }
        let inHeading: Bool = { if case .heading = row.kind { true } else { false } }()
        let spans = InlineMarkup.spans(in: text, range: body)
        let carousels = carousels(in: spans, text: text)
        for span in spans {
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
                // A post's or a video's: its card under the row, once it is in.
                if !inHeading, PhoneCards.lookup(target) != nil {
                    storage.addAttribute(.prismCard, value: target, range: NSRange(location: span.range.location, length: 1))
                } else if !inHeading, !PhoneCards.isCardLink(target),
                          // Any other link alone in its row: a page's, a podcast's card.
                          text.substring(with: span.range) == text.substring(with: body).trimmingCharacters(in: .whitespaces),
                          PhoneCards.rich(target, text: { if case .link = span.kind { text.substring(with: content) } else { nil } }()) != nil {
                    storage.addAttribute(.prismCard, value: target, range: NSRange(location: span.range.location, length: 1))
                }
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
                // A carousel's later pictures, and the space before each, drawn in its first.
                if case .member(let from)? = carousels[span.range.location] {
                    let hidden = NSRange(location: from, length: NSMaxRange(span.range) - from)
                    storage.addAttribute(.prismHidden, value: true, range: hidden)
                    storage.removeAttribute(.strikethroughStyle, range: hidden)
                    continue
                }
                if !inside, span.range.length > 2, let image = PhoneImages.lookup(reference.source) {
                    // The `!` takes the rest of a line it follows text on —
                    // a line may not break before `!`, but may after it —
                    // and the `[` is the picture, on a line of its own; the
                    // rest of the Markdown is not shown.
                    var box = PhoneImageBox(image: image, width: reference.width.map { CGFloat($0) })
                    if case .first(let pictures)? = carousels[span.range.location] {
                        box = PhoneImageBox(carousel: pictures.map(\.image), sources: pictures.map(\.source), width: box.width)
                    }
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
        // `->` and `<-` shown as arrows — not in code or links, and typed as
        // they are while the caret is at them; after the words' own styles,
        // the arrow drawn in the face its word is in, or the system's.
        do {
            let literal = InlineMarkup.spans(in: text, range: body).filter {
                switch $0.kind { case .code, .link, .url, .image, .comment: true; default: false }
            }.map(\.range)
            for (range, arrow) in TypedArrows.find(in: text, range: body, skipping: literal) {
                if let caret, caret >= range.location, caret <= NSMaxRange(range) { continue }
                storage.addAttribute(.prismHidden, value: true, range: NSRange(location: range.location, length: range.length - 1))
                let last = NSRange(location: NSMaxRange(range) - 1, length: 1)
                storage.addAttribute(.prismArrow, value: arrow, range: last)
                let face = font(at: last.location)
                var unichars = Array(arrow.utf16)
                var glyph = [CGGlyph](repeating: 0, count: unichars.count)
                if !CTFontGetGlyphsForCharacters(face, &unichars, &glyph, unichars.count) || glyph[0] == 0 {
                    storage.addAttribute(.font, value: UIFont.systemFont(ofSize: face.pointSize), range: last)
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
    /// Whether the note is today's: its time blocks show the time now.
    var today = false
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
        var arrowGlyphs: [CGGlyph]?
        for i in 0..<range.length {
            let index = characterIndexes[i]
            guard index < storage.length else { continue }
            // A typed arrow's last character, as the arrow.
            if let arrow = storage.attribute(.prismArrow, at: index, effectiveRange: nil) as? String {
                var unichars = Array(arrow.utf16)
                var glyph = [CGGlyph](repeating: 0, count: unichars.count)
                if CTFontGetGlyphsForCharacters(font, &unichars, &glyph, unichars.count), glyph[0] != 0 {
                    if arrowGlyphs == nil { arrowGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length)) }
                    arrowGlyphs![i] = glyph[0]
                    if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: range.length)) }
                }
            }
            // Words set in capitals: each letter's capital, where it is one
            // character and the face has it — the text itself as written.
            if storage.attribute(.prismUppercase, at: index, effectiveRange: nil) != nil {
                let unit = plainText.character(at: index)
                if !UTF16.isLeadSurrogate(unit), !UTF16.isTrailSurrogate(unit), let scalar = Unicode.Scalar(unit),
                   CharacterSet.lowercaseLetters.contains(scalar) {
                    var upper = Array(String(Character(scalar)).uppercased().utf16)
                    var glyph: CGGlyph = 0
                    if upper.count == 1, CTFontGetGlyphsForCharacters(font, &upper, &glyph, 1), glyph != 0 {
                        if arrowGlyphs == nil { arrowGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: range.length)) }
                        arrowGlyphs![i] = glyph
                        if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: range.length)) }
                    }
                }
            }
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
        let glyphList = arrowGlyphs ?? Array(UnsafeBufferPointer(start: glyphs, count: range.length))
        changed.withUnsafeBufferPointer { buffer in
            glyphList.withUnsafeBufferPointer { glyphBuffer in
                setGlyphs(glyphBuffer.baseAddress!, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
            }
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
        // A row's last line: room under it for the cards of its links.
        let cards = cardsEnding(at: characters, in: textContainer)
        let cardRoom = cards.isEmpty ? 0 : cards.reduce(0) { $0 + $1.size.height + Self.cardGap } + 2
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
        if start < storage.length, start == 0 || plainText.character(at: start - 1) == 0x0A,
           let value = storage.attribute(.prismSpaceBefore, at: start, effectiveRange: nil) as? CGFloat {
            above = value
        }
        let timeFoot = timeBlockFoot(characters: characters, fragment: lineFragmentRect.pointee, line: glyphRange)
        guard height != nil || above > 0 || cardRoom > 0 || timeFoot != nil else { return false }
        if let height {
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = height - PhoneImageBox.margin
        }
        lineFragmentRect.pointee.size.height += cardRoom
        lineFragmentRect.pointee.size.height += above
        lineFragmentUsedRect.pointee.origin.y += above
        baselineOffset.pointee += above
        // A time block's foot: down as far as it lasts, and its free time after.
        if timeFoot != nil, let foot = timeBlockFoot(characters: characters, fragment: lineFragmentRect.pointee, line: glyphRange) {
            lineFragmentRect.pointee.size.height += foot
        }
        return true
    }

    static let cardGap: CGFloat = 8

    /// Where a folded row's pill is, in the container: after the words of
    /// its last line, on the middle of their capitals.
    func foldPill(for paragraph: NSRange) -> CGRect? {
        guard let storage = textStorage, paragraph.length > 0 else { return nil }
        let last = glyphIndexForCharacter(at: NSMaxRange(paragraph) - 1)
        guard last < numberOfGlyphs else { return nil }
        let line = lineFragmentRect(forGlyphAt: last, effectiveRange: nil)
        let used = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont ?? metrics.body
        let baseline = line.minY + location(forGlyphAt: last).y
        let height = round(font.capHeight + 9)
        let middle = baseline - font.capHeight / 2
        return CGRect(x: used.maxX + 6, y: round(middle - height / 2), width: round(height * 1.7), height: height)
    }

    /// A pill with three dots in it, on their middle.
    static func drawFoldPill(in rect: CGRect) {
        Ink.text.withAlphaComponent(0.07).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
        Ink.secondary.setFill()
        let dot = max(2.5, round(rect.height * 0.16))
        let gap = dot * 1.1
        let total = 3 * dot + 2 * gap
        for i in 0..<3 {
            let x = rect.midX - total / 2 + CGFloat(i) * (dot + gap)
            UIBezierPath(ovalIn: CGRect(x: x, y: rect.midY - dot / 2, width: dot, height: dot)).fill()
        }
    }

    /// The cards of a row's links, when these characters end its last line.
    private func cardsEnding(at characters: NSRange, in container: NSTextContainer) -> [(source: String, card: PhoneCard, size: CGSize)] {
        guard let storage = textStorage, storage.length > 0, characters.length > 0 else { return [] }
        let text = plainText
        let end = min(NSMaxRange(characters), text.length)
        // The rows that end in these characters — at a line break in them,
        // or at the text's end: their cards go under this line. Each row
        // found from its own line break, not searched through for each of
        // its lines — a row thousands of characters long made laying a note
        // out take seconds that way.
        var ends: [Int] = []
        var at = characters.location
        while at < end {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: at, length: end - at))
            guard found.location != NSNotFound else { break }
            ends.append(found.location)
            at = NSMaxRange(found)
        }
        if end == text.length, ends.last != end - 1 { ends.append(end - 1) }
        var found: [(String, PhoneCard, CGSize)] = []
        for last in ends {
            let paragraph = text.paragraphRange(for: NSRange(location: last, length: 0))
            storage.enumerateAttribute(.prismCard, in: paragraph) { value, range, _ in
                guard let source = value as? String, let card = PhoneCards.lookup(source) else { return }
                found.append((source, card, PhoneCardView.size(card, room: lineWidth(at: range.location, in: container))))
            }
        }
        return found
    }

    /// Where each card of some rows is drawn, in the text container.
    func cards(in characters: NSRange) -> [(source: String, card: PhoneCard, frame: CGRect)] {
        guard let storage = textStorage, let container = textContainers.first, storage.length > 0 else { return [] }
        let text = plainText
        var found: [(String, PhoneCard, CGRect)] = []
        var seenLines = Set<Int>()
        var at = characters.location
        while at < min(NSMaxRange(characters), text.length) {
            let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(paragraph)
            let last = glyphIndexForCharacter(at: NSMaxRange(paragraph) - 1)
            guard last < numberOfGlyphs else { continue }
            var lineGlyphs = NSRange()
            _ = lineFragmentRect(forGlyphAt: last, effectiveRange: &lineGlyphs)
            // A line ending two rows — an empty one after — its cards once.
            guard seenLines.insert(lineGlyphs.location).inserted else { continue }
            let lineCharacters = characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
            let cards = cardsEnding(at: lineCharacters, in: container)
            guard !cards.isEmpty else { continue }
            let used = lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
            let indent = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
            var y = used.maxY + Self.cardGap
            for card in cards {
                found.append((card.source, card.card, CGRect(x: indent, y: y, width: card.size.width, height: card.size.height)))
                y += card.size.height + Self.cardGap
            }
        }
        return found
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
            if box.isCarousel {
                drawCarousel(box, in: frame)
                continue
            }
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

    /// The picture a carousel is at, fitted and centred over a quiet
    /// ground, which it is of how many over it; a dot for each under it.
    private func drawCarousel(_ box: PhoneImageBox, in frame: CGRect) {
        let index = PhoneCarousel.index(box)
        var pictures = frame
        pictures.size.height -= PhoneImageBox.dotsRoom
        let path = UIBezierPath(roundedRect: pictures, cornerRadius: 8)
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        path.addClip()
        Ink.codeBack.setFill()
        UIRectFill(pictures)
        let image = box.images[index]
        if image.size.width > 0, image.size.height > 0 {
            let scale = min(pictures.width / image.size.width, pictures.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: pictures.midX - size.width / 2, y: pictures.midY - size.height / 2, width: size.width, height: size.height))
        }
        // Which, of how many, at the top right.
        let label = NSAttributedString(string: "\(index + 1)/\(box.images.count)", attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.white,
        ])
        let size = label.size()
        let badge = CGRect(x: pictures.maxX - size.width - 22, y: pictures.minY + 10, width: size.width + 12, height: size.height + 4)
        UIColor.black.withAlphaComponent(0.45).setFill()
        UIBezierPath(roundedRect: badge, cornerRadius: badge.height / 2).fill()
        label.draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 2))
        context?.restoreGState()
        Ink.rule.setStroke()
        path.lineWidth = 1
        path.stroke()
        // The dots, under it.
        let count = box.images.count
        let spacing: CGFloat = 12, side: CGFloat = 6
        let start = pictures.midX - spacing * CGFloat(count - 1) / 2
        for i in 0..<count {
            (i == index ? Ink.text : Ink.faint).setFill()
            UIBezierPath(ovalIn: CGRect(x: start + spacing * CGFloat(i) - side / 2, y: frame.maxY - PhoneImageBox.dotsRoom / 2 + 1 - side / 2,
                                        width: side, height: side)).fill()
        }
    }

    /// The tasks and checklist items under each row, by its paragraph's
    /// start: found once for each change to the text, not each drawing.
    private var progressUnder: [Int: Checkboxes.Progress]?
    /// Set while typing within a row: the checkboxes under each row are as
    /// they were, not found again through the whole note for each key.
    var keepsProgress = false

    /// The text, as a plain string, for the layout's questions: the
    /// storage's own string reads each character through the storage, and
    /// a paragraph found in it, for each line laid out, made laying out a
    /// long note take seconds. Copied once for each change.
    private var plainCopy: NSString?
    override var textStorage: NSTextStorage? {
        didSet {
            plainCopy = nil
            progressUnder = nil
        }
    }
    var plainText: NSString {
        if let plainCopy { return plainCopy }
        let copy = (textStorage?.mutableString.copy() as? NSString) ?? ""
        plainCopy = copy
        return copy
    }

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorage.EditActions, range newCharRange: NSRange,
                                 changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        if editMask.contains(.editedCharacters) { plainCopy = nil }
        if keepsProgress {
            // The rows' places after the typing moved by what it added.
            if delta != 0, let found = progressUnder {
                progressUnder = Dictionary(uniqueKeysWithValues: found.map { ($0.key > newCharRange.location ? $0.key + delta : $0.key, $0.value) })
            }
        } else {
            progressUnder = nil
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    private func progress(at location: Int) -> Checkboxes.Progress? {
        guard let storage = textStorage else { return nil }
        if progressUnder == nil {
            let paragraphs = OutlineText.paragraphs(plainText)
            let under = Checkboxes.underEach(paragraphs.map { OutlineText.style(storage, at: $0.location).row })
            var found: [Int: Checkboxes.Progress] = [:]
            for (paragraph, progress) in zip(paragraphs, under) where !progress.isEmpty { found[paragraph.location] = progress }
            progressUnder = found
        }
        return progressUnder?[location]
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = plainText
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
        if PhoneTimeSlot.any(in: storage) {
            drawTimeBlocks(timeBlocks(in: covered), at: origin, today: today)
        }
        drawImages(in: covered, at: origin)
        for card in cards(in: covered) {
            PhoneCardView.draw(card.card, in: card.frame.offsetBy(dx: origin.x, dy: origin.y), source: card.source)
        }
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
            // A time block's bullet is its node on the timeline's line.
            let isTimeBlock = PhoneTimeSlot.head(storage, at: paragraph.location) != nil
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
                } else if !isTimeBlock {
                    Ink.secondary.setFill()
                    let dot = max(4.5, round(font.pointSize * 0.3))
                    UIBezierPath(ovalIn: CGRect(x: markerX - dot / 2, y: middle - dot / 2, width: dot, height: dot)).fill()
                    // To-dos under it: how far along they are, round the bullet.
                    if let progress = progress(at: paragraph.location) {
                        let side = round(font.pointSize * 0.95)
                        ProgressRing.draw(progress, in: CGRect(x: markerX - side / 2, y: middle - side / 2, width: side, height: side),
                                          lineWidth: 1.6, tick: false)
                    }
                }
            default:
                break
            }
            // Folded, whatever it is: a pill after its words says so.
            if row.isFolded, let pill = foldPill(for: paragraph) { Self.drawFoldPill(in: pill.offsetBy(dx: origin.x, dy: origin.y)) }
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
        guard hidesTitle, textStorage.length > 0,
              textStorage.attribute(.prismCollapsed, at: 0, effectiveRange: nil) != nil else { return nil }
        // Its own row only: looked for in the first paragraph, not the whole
        // note — which, for a note with none, would be read through each key.
        let first = textStorage.mutableString.paragraphRange(for: NSRange(location: 0, length: 0))
        var title = NSRange()
        _ = textStorage.attribute(.prismCollapsed, at: 0, longestEffectiveRange: &title, in: first)
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
        // A row held — anywhere on it when reading, by its bullet when
        // typing, where holding the words moves the caret — is picked up.
        rowHold.minimumPressDuration = 0.4
        rowHold.isOnPicture = { [weak self] point in
            guard let self, self.isEditable, self.rowUnder(point) != nil, !self.blockHold.isOnPicture!(point) else { return false }
            switch self.target(at: point) {
            case .image: return false
            case .marker: return true
            default: return !self.isFirstResponder
            }
        }
        rowHold.addTarget(self, action: #selector(heldRow(_:)))
        // A time block held by its times, its foot or its empty part: moved,
        // or made longer — not its row picked up.
        blockHold.minimumPressDuration = 0.25
        blockHold.isOnPicture = { [weak self] point in
            guard let self, self.isEditable else { return false }
            return self.outlineLayout.timeBlockHit(at: CGPoint(x: point.x - self.textContainerInset.left,
                                                               y: point.y - self.textContainerInset.top)) != nil
        }
        blockHold.addTarget(self, action: #selector(heldTimeBlock(_:)))
        blockHold.delegate = self
        addGestureRecognizer(blockHold)
        rowHold.delegate = self
        addGestureRecognizer(rowHold)
        pictureHold.delegate = self
        addGestureRecognizer(pictureHold)
        addInteraction(pictureMenu)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
            let turn = UISwipeGestureRecognizer(target: self, action: #selector(swipedCarousel(_:)))
            turn.direction = direction
            turn.delegate = self
            addGestureRecognizer(turn)
            carouselSwipes.append(turn)
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
                let text = self.textStorage.mutableString
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
        let rows = max(0, fit - (extra > 0 ? extra : round(metrics.lineHeight * metrics.size)))
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
        let text = textStorage.mutableString
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
        let text = textStorage.mutableString
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
        let ranges = OutlineText.paragraphs(textStorage.mutableString)
        cachedRanges = ranges
        return ranges
    }
    private var cachedRanges: [NSRange]?

    /// A row just added, not typed — dictated — marked a moment: its words
    /// under the accent's tint, fading, so the eye finds what came in.
    func flashRow(_ index: Int) {
        let ranges = paragraphRanges
        guard ranges.indices.contains(index), ranges[index].length > 1 else { return }
        layoutIfNeeded()
        let words = NSRange(location: ranges[index].location, length: ranges[index].length - 1)
        let glyphs = outlineLayout.glyphRange(forCharacterRange: words, actualCharacterRange: nil)
        var rect = CGRect.null
        outlineLayout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: textContainer) { line, _ in rect = rect.union(line) }
        guard !rect.isNull else { return }
        let mark = UIView(frame: rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top).insetBy(dx: -4, dy: -2))
        mark.backgroundColor = Ink.accent.withAlphaComponent(0.22)
        mark.layer.cornerRadius = 6
        mark.isUserInteractionEnabled = false
        mark.alpha = 0
        insertSubview(mark, at: 0)
        UIView.animate(withDuration: 0.2) { mark.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 1.0, delay: 0.6, options: [.curveEaseOut]) { mark.alpha = 0 } completion: { _ in
                mark.removeFromSuperview()
            }
        }
    }

    /// The caret as tall as its type: a time block's last line stands as
    /// tall as the block lasts, and the caret would reach down through it.
    override func caretRect(for position: UITextPosition) -> CGRect {
        var rect = super.caretRect(for: position)
        let offset = self.offset(from: beginningOfDocument, to: position)
        guard textStorage.length > 0, PhoneTimeSlot.any(in: textStorage) else { return rect }
        let at = min(max(0, offset - 1), textStorage.length - 1)
        let font = textStorage.attribute(.font, at: at, effectiveRange: nil) as? UIFont ?? metrics.body
        let line = ceil(font.lineHeight * max(1, metrics.lineHeight * metrics.size / max(font.lineHeight, 1)))
        guard rect.height > line + 2 else { return rect }
        // On the words' baseline, as tall as they stand.
        let glyph = outlineLayout.glyphIndexForCharacter(at: min(offset, textStorage.length - 1))
        guard glyph < outlineLayout.numberOfGlyphs else { return rect }
        let fragment = outlineLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let baseline = fragment.minY + outlineLayout.location(forGlyphAt: glyph).y + textContainerInset.top
        rect.origin.y = (baseline - font.ascender - 1).rounded()
        rect.size.height = ceil(font.ascender - font.descender + 2)
        return rect
    }

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
        let storageText = textStorage.mutableString.copy() as! NSString
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
            let all = self.rows
            if caret.offset == paragraphRanges[caret.row].length - 1, let next = Timeline.nextBlock(after: caret.row, in: all) {
                // At a time block's end: the next, starting as it ends.
                var after = all
                after.insert(next, at: caret.row + 1)
                replace(after, caret: OutlineKeys.Caret(row: caret.row + 1, offset: (next.text as NSString).length), undoName: "New Row")
            } else if let split = OutlineKeys.split(all, at: caret) {
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
        // Past where a row's kind is written: its checkboxes, and those of
        // the rows around it, are as they were.
        outlineLayout.keepsProgress = plainEdit && range.location > paragraph.location + 5
        // Time blocks: a row's change moves the rooms of those about it — measured whole.
        if plainEdit, measured != nil, !PhoneTimeSlot.any(in: textStorage) {
            typedRowBefore = (paragraph.location, height(ofParagraphsIn: paragraph))
            localChanges += 1
        }
        // The row it begins in: kept as it is, whatever style the typing came in.
        styler.editingRow = (paragraph.location, OutlineText.style(textStorage, at: paragraph.location))
        return true
    }

    /// Whether the edit under way is typing within one row.
    private var plainEdit = false
    /// The row typed in, and its height before.
    private var typedRowBefore: (location: Int, height: CGFloat)?

    func textViewDidChange(_ textView: UITextView) {
        styler.editingRow = nil
        outlineLayout.keepsProgress = false
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
              let trigger = LinkSuggestions.trigger(in: textStorage.mutableString, typedAt: location) else { return }
        if case .code = rows[rowIndex(at: location)].kind { return }
        if textStorage.attribute(.font, at: location, effectiveRange: nil).map({ ($0 as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true }) == true { return }
        completing = (trigger, location + 1)
    }

    /// The choices for what is typed now — or none, the link left.
    private func refreshCompletion() {
        guard let completing else { return }
        guard selectedRange.length == 0,
              let query = LinkSuggestions.query(in: textStorage.mutableString, start: completing.start,
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
        let put = LinkSuggestions.accepting(candidate, in: textStorage.mutableString, start: completing.start,
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
            let paragraphs = textStorage.mutableString.paragraphRange(for: selectedRange)
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
        let text = textStorage.mutableString
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

    /// A time block from now, a quarter of an hour long, to name — and
    /// drag where it goes, or make longer.
    @objc func newTimeBlock() {
        let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let made = Timeline.newBlock(in: rows, at: caret.row, now: (time.hour ?? 0) * 60 + (time.minute ?? 0))
        // The keyboard told: its suggestions, and where it types, follow the caret.
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        replace(made.rows, caret: OutlineKeys.Caret(row: made.row, offset: made.offset), undoName: "New Time Block")
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    @objc func indent() { perform("Indent") { OutlineEditing.indent(&$0, $1) } }
    @objc func outdent() { perform("Outdent") { OutlineEditing.outdent(&$0, $1) } }
    @objc func moveUp() {
        // Not above a title not shown: it stays the note's first row.
        if collapsedTitle != nil, selectedRowRange.lowerBound <= 1 { return }
        perform("Move Up") { OutlineEditing.moveUp(&$0, $1) }
    }
    @objc func moveDown() { perform("Move Down") { OutlineEditing.moveDown(&$0, $1) } }

    // MARK: Formatting

    @objc func makeBold() { toggleMark("**") }
    @objc func makeItalic() { toggleMark("*") }
    @objc func makeStruck() { toggleMark("~~") }
    @objc func makeHighlighted() { toggleMark("==") }
    @objc func makeCode() { toggleMark("`") }

    /// Marks the words chosen — or, marked so already, unmarks them; with
    /// none chosen, the marks put in with the caret between them, to type in.
    private func toggleMark(_ mark: String) {
        let text = textStorage.mutableString.copy() as! NSString
        let range = selectedRange
        let length = (mark as NSString).length
        let paragraph = text.paragraphRange(for: NSRange(location: min(range.location, max(0, text.length - 1)), length: 0))
        styler.editingRow = (paragraph.location, OutlineText.style(textStorage, at: paragraph.location))
        defer { styler.editingRow = nil }
        let before = NSRange(location: range.location - length, length: length)
        let after = NSRange(location: NSMaxRange(range), length: length)
        let marked = before.location >= 0 && NSMaxRange(after) <= text.length
            && text.substring(with: before) == mark && text.substring(with: after) == mark
            // `*` is not half of `**`.
            && !(mark == "*" && (before.location > 0 && text.character(at: before.location - 1) == 0x2A))
        undoManager?.beginUndoGrouping()
        if marked {
            replaceText(after, with: "")
            replaceText(before, with: "")
            selectedRange = NSRange(location: range.location - length, length: range.length)
        } else {
            let words = text.substring(with: range)
            // Nothing chosen, just after a word: a space first, to start a word of its own.
            let lead = range.length == 0 && range.location > paragraph.location
                && !(CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: range.location - 1)) ?? " ")) ? " " : ""
            replaceText(range, with: lead + mark + words + mark)
            selectedRange = NSRange(location: range.location + (lead as NSString).length + length, length: range.length)
        }
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Format")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Text replaced as typing would replace it: undone the same way.
    private func replaceText(_ range: NSRange, with string: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: string)
    }

    /// The rows chosen a heading, one level smaller each time — then plain again.
    @objc func cycleHeading() {
        let caret = self.caret
        var all = rows
        let selection = selectedRowRange
        guard let first = selection.first, all.indices.contains(first) else { return }
        let next: Row.Kind = switch all[first].kind {
        case .heading(let level) where level < 3: .heading(level + 1)
        case .heading: .bullet
        default: .heading(1)
        }
        for i in selection where all.indices.contains(i) {
            all[i].kind = next
            if case .heading = next { all[i].task = nil }
        }
        replace(all, caret: caret, undoName: "Heading")
    }

    /// The rows chosen a quote, or a quote no longer.
    @objc func toggleQuote() {
        let caret = self.caret
        var all = rows
        let selection = selectedRowRange
        guard let first = selection.first, all.indices.contains(first) else { return }
        let quoting = all[first].kind != .quote
        for i in selection where all.indices.contains(i) {
            all[i].kind = quoting ? .quote : .bullet
            if quoting { all[i].task = nil }
        }
        replace(all, caret: caret, undoName: "Quote")
    }

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
        /// A folded row's pill.
        case fold(Int)
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
        if let card = outlineLayout.cards(in: paragraphRanges[index]).first(where: { $0.frame.contains(inContainer) }) {
            return .link(card.source)
        }
        if row.isFolded, let pill = outlineLayout.foldPill(for: paragraphRanges[index]), pill.insetBy(dx: -8, dy: -8).contains(inContainer) {
            return .fold(index)
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
        if gesture === dragScroll { return rowDrag != nil }
        // A carousel swiped to the picture before or after it.
        if let swipe = gesture as? UISwipeGestureRecognizer, carouselSwipes.contains(swipe) {
            return carousel(at: gesture.location(in: self)) != nil
        }
        // A row swiped in or out only while typing in it: otherwise a
        // swipe goes between the columns.
        if gesture is UISwipeGestureRecognizer { return isFirstResponder && carousel(at: gesture.location(in: self)) == nil }
        return super.gestureRecognizerShouldBegin(gesture)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // A swipe on a carousel turns it, not the sheet back to the one before.
        if let swipe = gesture as? UISwipeGestureRecognizer, carouselSwipes.contains(swipe) {
            return other is UIPanGestureRecognizer && other.view !== self && !(other.view is UIScrollView)
        }
        return (gesture === pictureHold || gesture === rowHold || gesture === blockHold) && other.view === self && other !== markerTap
            && other !== pictureHold && other !== rowHold && other !== blockHold
    }

    /// A carousel's swipes follow only a touch that starts on one: nothing
    /// else waits on them.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let swipe = gesture as? UISwipeGestureRecognizer, carouselSwipes.contains(swipe) else { return true }
        return carousel(at: touch.location(in: self)) != nil
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture is UISwipeGestureRecognizer || gesture === dragScroll || other === dragScroll
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
        case .fold(let index):
            toggleFold(at: index)
            UISelectionFeedbackGenerator().selectionChanged()
        case .image(let span):
            // A carousel's edges turn it.
            let point = gesture.location(in: self)
            if let carousel = carousel(at: point) {
                let edge = carousel.frame.width * 0.3
                if point.x < carousel.frame.minX + edge { return turn(carousel.box, span: carousel.span, by: -1) }
                if point.x > carousel.frame.maxX - edge { return turn(carousel.box, span: carousel.span, by: 1) }
            }
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
        // A link pasted on words: the words link to it, as on the Mac.
        if selectedRange.length > 0, let address = board.string.flatMap(LinkPaste.address(in:)), linkSelection(to: address) { return }
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

    /// The words chosen made a link to an address — or, a link's words
    /// already, that link pointed there. Says whether it did.
    private func linkSelection(to address: String) -> Bool {
        let selection = selectedRange
        let index = rowIndex(at: selection.location)
        let ranges = paragraphRanges
        guard ranges.indices.contains(index) else { return false }
        let start = ranges[index].location
        var all = rows
        guard NSMaxRange(selection) <= start + (all[index].text as NSString).length,
              let linked = LinkPaste.link(all[index].text, selection: NSRange(location: selection.location - start, length: selection.length),
                                          to: address) else { return false }
        all[index].text = linked.text
        // The keyboard told: what it suggests, and where it types, follow.
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        replace(all, caret: OutlineKeys.Caret(row: index, offset: linked.caret), undoName: "Link")
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
        return true
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
    private let rowHold = PictureHold()
    private let blockHold = PictureHold()
    /// A time block being dragged.
    var timeDrag: TimeDrag?
    /// The day the note is, if one: on today's, time blocks show the time now.
    var day: Day? {
        didSet { outlineLayout.today = day == .today }
    }
    var rowDrag: RowDragState?
    /// While a row is carried: another finger scrolling the sheet under it.
    let dragScroll = UIPanGestureRecognizer()
    private lazy var pictureMenu = UIEditMenuInteraction(delegate: self)

    // MARK: Done to the bottom

    /// Whether a row is a bullet with checkboxes among its children: the
    /// ring round its bullet.
    func hasChecklist(under index: Int) -> Bool {
        guard rows.indices.contains(index), rows[index].kind == .bullet, rows[index].task == nil else { return false }
        let end = OutlineEditing.subtreeEnd(rows, index)
        return rows[(index + 1)..<end].contains { $0.task != nil }
    }

    /// Where the list menu was asked for, in the editor.
    private var listMenuPoint: CGPoint = .zero

    func showListMenu(forRow index: Int, at point: CGPoint) {
        listMenuPoint = point
        // After the finger is up: shown as it lifts, the menu goes with it.
        DispatchQueue.main.async { [self] in
            pictureMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: "list:\(index)" as NSString, sourcePoint: point))
        }
    }

    /// The done items among a row's children below the rest.
    func moveDoneToBottom(under index: Int) {
        var all = rows
        guard OutlineEditing.moveDoneToBottom(&all, under: index) else { return }
        replace(all, caret: isFirstResponder ? caret : nil, undoName: "Move Done to Bottom")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Every list's done items below the rest. Says whether any moved.
    @discardableResult
    func moveAllDoneToBottom() -> Bool {
        var all = rows
        guard OutlineEditing.moveAllDoneToBottom(&all) else { return false }
        replace(all, caret: isFirstResponder ? caret : nil, undoName: "Move Done to Bottom")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    @objc private func heldPicture(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, case .image(let span) = target(at: gesture.location(in: self)),
              let frame = pictureFrame(span) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let configuration = UIEditMenuConfiguration(identifier: NSStringFromRange(span) as NSString,
                                                    sourcePoint: CGPoint(x: frame.midX, y: frame.minY))
        pictureMenu.presentEditMenu(with: configuration)
    }

    /// The source a picture's Markdown gives — a carousel's, its first's.
    private func pictureSource(_ span: NSRange) -> String? {
        guard NSMaxRange(span) <= textStorage.length else { return nil }
        let markdown = textStorage.mutableString.substring(with: span)
        guard let open = markdown.range(of: "]("),
              let close = markdown.range(of: ")", range: open.upperBound..<markdown.endIndex) else { return nil }
        var source = String(markdown[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
        // `![](path "title")` and `![](<path>)` alike.
        if let space = source.firstIndex(of: " ") { source = String(source[..<space]) }
        return source.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
    }

    /// The file a picture's Markdown shows, in the graph.
    private func pictureFile(_ span: NSRange) -> URL? {
        pictureSource(span).flatMap(PhoneImages.url(for:)).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Told when a picture in the note is chosen as its cover.
    var onMakeCover: ((String) -> Void)?

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
        let paragraph = textStorage.mutableString.paragraphRange(for: NSRange(location: span.location, length: 0))
        guard let frame = outlineLayout.images(in: paragraph).first(where: { $0.span == span })?.frame else { return nil }
        return frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    // MARK: Carousels

    private var carouselSwipes: [UISwipeGestureRecognizer] = []

    /// The carousel at a point in the editor: it, its Markdown's range,
    /// and where it is drawn, in the editor.
    private func carousel(at point: CGPoint) -> (box: PhoneImageBox, span: NSRange, frame: CGRect)? {
        guard textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = outlineLayout.glyphIndex(for: inContainer, in: textContainer)
        let index = rowIndex(at: outlineLayout.characterIndexForGlyph(at: glyph))
        guard let found = outlineLayout.images(in: paragraphRanges[index]).first(where: { $0.box.isCarousel && $0.frame.contains(inContainer) })
        else { return nil }
        return (found.box, found.span, found.frame.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top))
    }

    @objc private func swipedCarousel(_ gesture: UISwipeGestureRecognizer) {
        guard let carousel = carousel(at: gesture.location(in: self)) else { return }
        turn(carousel.box, span: carousel.span, by: gesture.direction == .left ? 1 : -1)
    }

    /// A carousel to the picture so many after the one it shows — before,
    /// for fewer than none — faded across.
    private func turn(_ box: PhoneImageBox, span: NSRange, by step: Int) {
        let current = PhoneCarousel.index(box)
        let next = min(max(current + step, 0), box.images.count - 1)
        guard next != current else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
            return
        }
        PhoneCarousel.set(next, for: box)
        UISelectionFeedbackGenerator().selectionChanged()
        outlineLayout.invalidateDisplay(forCharacterRange: span)
        // The text is drawn in views within this one, which do not hear of
        // it otherwise: each told, the carousel's picture faded across.
        func redraw(_ view: UIView) {
            view.setNeedsDisplay()
            view.subviews.forEach(redraw)
        }
        UIView.transition(with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            redraw(self)
        }
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
        let text = textStorage.mutableString
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
        // Time blocks: a row's change moves the rooms of those about it — measured whole.
        if PhoneTimeSlot.any(in: textStorage) {
            change()
            measured = nil
            heightMayHaveChanged()
            return
        }
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
        let rows = max(0, fit - (extra > 0 ? extra : round(metrics.lineHeight * metrics.size)))
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
        // The outline's tools; behind Aa, the words'.
        let outline: [(String, Selector?, String)] = [
            ("textformat", nil, "Formatting"),
            ("decrease.indent", #selector(OutlineEditor.outdent), "Outdent"),
            ("increase.indent", #selector(OutlineEditor.indent), "Indent"),
            ("arrow.up", #selector(OutlineEditor.moveUp), "Move Up"),
            ("arrow.down", #selector(OutlineEditor.moveDown), "Move Down"),
            ("checkmark.square", #selector(OutlineEditor.cycleChecklist), "Checklist"),
            ("checkmark.circle", #selector(OutlineEditor.cycleTask), "Task"),
            ("link", #selector(OutlineEditor.insertLink), "Link"),
            ("clock", #selector(OutlineEditor.newTimeBlock), "New Time Block"),
            ("keyboard.chevron.compact.down", #selector(UIResponder.resignFirstResponder), "Done"),
        ]
        let words: [(String, Selector?, String)] = [
            ("chevron.left", nil, "Back"),
            ("bold", #selector(OutlineEditor.makeBold), "Bold"),
            ("italic", #selector(OutlineEditor.makeItalic), "Italic"),
            ("strikethrough", #selector(OutlineEditor.makeStruck), "Strikethrough"),
            ("highlighter", #selector(OutlineEditor.makeHighlighted), "Highlight"),
            ("chevron.left.forwardslash.chevron.right", #selector(OutlineEditor.makeCode), "Code"),
            ("number", #selector(OutlineEditor.cycleHeading), "Heading"),
            ("text.quote", #selector(OutlineEditor.toggleQuote), "Quote"),
            ("keyboard.chevron.compact.down", #selector(UIResponder.resignFirstResponder), "Done"),
        ]
        let stack = UIStackView()
        let formatting = UIStackView()
        for (row, items) in [(stack, outline), (formatting, words)] {
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.translatesAutoresizingMaskIntoConstraints = false
            for (symbol, action, label) in items {
                let button = UIButton(type: .system)
                button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
                button.tintColor = Ink.text
                button.accessibilityLabel = label
                if let action {
                    button.addTarget(editor, action: action, for: .touchUpInside)
                } else {
                    // Aa, and back: one row of tools for the other.
                    let toWords = row === stack
                    button.addAction(UIAction { [weak stack, weak formatting] _ in
                        stack?.isHidden = toWords
                        formatting?.isHidden = !toWords
                    }, for: .touchUpInside)
                }
                row.addArrangedSubview(button)
            }
        }
        formatting.isHidden = true
        backgroundColor = Ink.paper
        let rule = UIView()
        rule.backgroundColor = Ink.rule
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        addSubview(stack)
        addSubview(formatting)
        NSLayoutConstraint.activate([
            formatting.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            formatting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            formatting.topAnchor.constraint(equalTo: topAnchor),
            formatting.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    /// Copy and Share, for the picture held; for a checklist's ring, its
    /// done items to the bottom.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let id = configuration.identifier as? NSString else { return nil }
        // A checklist's ring: its done items to the bottom.
        if id.hasPrefix("list:"), let index = Int(id.substring(from: 5)) {
            var all = rows
            let movable = OutlineEditing.moveDoneToBottom(&all, under: index)
            return UIMenu(children: [
                UIAction(title: "Move Done to Bottom", image: UIImage(systemName: "arrow.down.to.line"),
                         attributes: movable ? [] : .disabled) { [weak self] _ in self?.moveDoneToBottom(under: index) },
            ])
        }
        let span = NSRangeFromString(id as String)
        guard let file = pictureFile(span) else { return nil }
        let rect = pictureFrame(span) ?? .zero
        var actions = [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyPicture(file) },
            UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.sharePicture(file, from: rect) },
        ]
        if let onMakeCover, let source = pictureSource(span) {
            actions.append(UIAction(title: "Make Cover", image: UIImage(systemName: "photo.artframe")) { _ in onMakeCover(source) })
        }
        return UIMenu(children: actions)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        guard let id = configuration.identifier as? NSString else { return .null }
        if id.hasPrefix("list:") { return CGRect(x: listMenuPoint.x - 12, y: listMenuPoint.y - 12, width: 24, height: 24) }
        return pictureFrame(NSRangeFromString(id as String)) ?? .null
    }
}

/// A long press that is only ever on a picture: anywhere else it fails as
/// the finger comes down, and what waits on it goes on as if it were not there.
final class PictureHold: UILongPressGestureRecognizer {
    var isOnPicture: ((CGPoint) -> Bool)?
    /// Where the finger went down, in the view.
    private(set) var downPoint: CGPoint?

    /// The finger it follows: others that come down while it is held —
    /// another, scrolling — are not its.
    private weak var finger: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let finger, finger.phase != .ended, finger.phase != .cancelled {
            for touch in touches where touch !== finger { ignore(touch, for: event) }
            let own = touches.filter { $0 === finger }
            if !own.isEmpty { super.touchesBegan(own, with: event) }
            return
        }
        super.touchesBegan(touches, with: event)
        finger = touches.first
        downPoint = touches.first?.location(in: view)
        if let touch = touches.first, isOnPicture?(touch.location(in: view)) != true { state = .failed }
    }

    override func reset() {
        super.reset()
        finger = nil
    }
}

/// A ring whose rim fills, clockwise from the top, with the share of some
/// checkboxes done — all done, whole, with a tick when there is room.
enum ProgressRing {
    static func draw(_ progress: Checkboxes.Progress, in rect: CGRect, lineWidth width: CGFloat, tick: Bool = true) {
        let ring = rect.insetBy(dx: width / 2, dy: width / 2)
        let center = CGPoint(x: ring.midX, y: ring.midY)
        let radius = ring.width / 2
        let rim = UIBezierPath(ovalIn: ring)
        rim.lineWidth = width
        Ink.rule.setStroke()
        rim.stroke()
        guard progress.total > 0 else { return }
        Ink.accent.setStroke()
        if progress.done >= progress.total {
            rim.stroke()
            guard tick else { return }
            let scale = radius / 6.4
            let mark = UIBezierPath()
            mark.move(to: CGPoint(x: center.x - 3 * scale, y: center.y))
            mark.addLine(to: CGPoint(x: center.x - 0.8 * scale, y: center.y + 2.3 * scale))
            mark.addLine(to: CGPoint(x: center.x + 3.2 * scale, y: center.y - 2.4 * scale))
            mark.lineWidth = 1.6
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.stroke()
        } else if progress.done > 0 {
            let start = -CGFloat.pi / 2
            let arc = UIBezierPath(arcCenter: center, radius: radius, startAngle: start,
                                   endAngle: start + 2 * .pi * CGFloat(progress.share), clockwise: true)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            arc.stroke()
        }
    }

    /// The ring as a picture, to put among words.
    static func image(_ progress: Checkboxes.Progress, side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(progress, in: CGRect(x: 0, y: 0, width: side, height: side), lineWidth: 1.8)
        }
    }
}
