import CoreText
import UIKit
import UIKit.UIGestureRecognizerSubclass
import UniformTypeIdentifiers
import QuickLook
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
    /// Inline code, and a highlight: their grounds drawn a line at a time
    /// round their words — a background colour is filled out to the edges.
    static let prismCode = NSAttributedString.Key("PrismCode")
    static let prismMarked = NSAttributedString.Key("PrismMarked")
    /// On a web link's last character, flat: a small ↗ after it, in room kerned for it.
    static let prismExternal = NSAttributedString.Key("PrismExternal")
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
            return Typeface.withFeatures(font, adding: features)
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
    /// A private note's: its links never looked up for cards.
    var isPrivateNote = false
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
            var row = style.row
            // Its words, for how long it is: a style keeps only its kind.
            row.text = text.substring(with: paragraph).trimmingCharacters(in: .newlines)
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
            // `- > words`: a quote — its words grey, its `> ` written out only where the caret is.
            if let marker = QuotedBullet.marker(in: text, paragraph: paragraph, row: row) {
                let body = NSRange(location: paragraph.location, length: paragraph.length - 1)
                storage.enumerateAttribute(.foregroundColor, in: body) { value, run, _ in
                    if (value as? UIColor) == Ink.text { storage.addAttribute(.foregroundColor, value: Ink.secondary, range: run) }
                }
                if caret.map({ $0 < paragraph.location || $0 > NSMaxRange(marker) }) ?? true {
                    storage.addAttribute(.prismHidden, value: true, range: marker)
                }
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
            // Nor through what is hidden — an emphasis's `*`, a link's address:
            // laid out at a wrapped line's ends, a line through it reaches
            // across the page.
            storage.enumerateAttribute(.prismHidden, in: paragraph) { value, run, _ in
                if value != nil { storage.removeAttribute(.strikethroughStyle, range: run) }
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
        } else if row.startsGroup(after: previous) {
            before = round(metrics.size * 0.6)
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
        }
        if row.isStruck {
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
        let flat = Card.flat
        for span in spans {
            let content = span.content
            let revealed = caret.map { NSLocationInRange($0, span.range) || $0 == NSMaxRange(span.range) } ?? false
            /// A link shown as its site alone: where, in the row's text.
            var site: NSRange?
            switch span.kind {
            case .strong:
                storage.addAttribute(.font, value: Self.adding(.traitBold, to: font(at: content.location)), range: content)
            case .emphasis:
                storage.addAttribute(.font, value: Self.adding(.traitItalic, to: font(at: content.location)), range: content)
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: Ink.secondary], range: content)
            case .code:
                storage.addAttributes([.font: metrics.face.mono(round(base.pointSize * 0.88)), .prismCode: true], range: content)
            case .highlight:
                storage.addAttribute(.prismMarked, value: true, range: content)
            case .link(let target), .url(let target):
                // Flat, a link is the text's own ink, a faint line under it;
                // else blue, on a pill.
                storage.addAttributes([.foregroundColor: flat ? Ink.text : Ink.accent, .prismLink: target], range: content)
                if flat {
                    storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Ink.faint], range: content)
                } else if !inHeading {
                    storage.addAttribute(.prismPill, value: true, range: span.range)
                }
                // A post's or a video's: its card under the row, once it is in —
                // none for a link written `"no card"`.
                let alone = text.substring(with: span.range) == text.substring(with: body).trimmingCharacters(in: .whitespaces)
                var carded = false
                // A private note's links are never looked up, as on the Mac.
                if inHeading || span.hidesCard || isPrivateNote {
                } else if PhoneCards.lookup(target) != nil {
                    storage.addAttribute(.prismCard, value: target, range: NSRange(location: span.range.location, length: 1))
                    carded = true
                } else if !PhoneCards.isCardLink(target), alone,
                          // Any other link alone in its row: a page's, a podcast's card.
                          PhoneCards.rich(target, text: { if case .link = span.kind { text.substring(with: content) } else { nil } }()) != nil {
                    storage.addAttribute(.prismCard, value: target, range: NSRange(location: span.range.location, length: 1))
                    carded = true
                }
                // Flat, a link alone in its row, its card under it: its site
                // alone, small and grey — the card says the rest.
                if flat, carded, alone, !revealed, var host = URL(string: target)?.host() {
                    if host.hasPrefix("www.") { host.removeFirst(4) }
                    let found = (text.substring(with: span.range) as NSString).range(of: host, options: .backwards)
                    if found.location != NSNotFound { site = NSRange(location: span.range.location + found.location, length: found.length) }
                }
                // Flat, a link out of the notes — to the web — a small ↗ after
                // it: room kerned after its last letter, the arrow drawn there.
                if flat, site == nil, !inHeading, content.length > 0, target.lowercased().hasPrefix("http") {
                    let last = NSMaxRange(content) - 1
                    let size = font(at: last).pointSize
                    // Its own underline drawn, short of the arrow's room.
                    storage.addAttributes([.prismExternal: true, .kern: round(size * 0.62)], range: NSRange(location: last, length: 1))
                    storage.removeAttribute(.underlineStyle, range: NSRange(location: last, length: 1))
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
                storage.addAttributes([.foregroundColor: flat ? Ink.text : Ink.accent, .prismLink: "[[" + title + "]]"], range: content)
                if flat {
                    storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Ink.faint], range: content)
                } else if !inHeading {
                    storage.addAttribute(.prismPill, value: true, range: span.range)
                }
            case .tag:
                storage.addAttribute(.foregroundColor, value: flat ? Ink.secondary : Ink.accent, range: span.range)
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
            // A link shown as its site: the rest of it hidden, the site small and grey.
            if let site, let target = storage.attribute(.prismLink, at: content.location, effectiveRange: nil) {
                for key: NSAttributedString.Key in [.prismIcon, .prismEllipsis, .underlineStyle] { storage.removeAttribute(key, range: span.range) }
                storage.addAttribute(.prismHidden, value: true, range: span.range)
                storage.removeAttribute(.prismHidden, range: site)
                storage.addAttributes([.foregroundColor: Ink.secondary, .font: metrics.face.body(round(base.pointSize * 0.82)), .prismLink: target],
                                      range: site)
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
        // From the family's own faces, by name: bold at the weight the face
        // sets bold in, italic at the weight it is in.
        let weight = ((CTFontCopyTraits(font as CTFont) as NSDictionary)[kCTFontWeightTrait] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        let italic = trait == .traitItalic || font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        let wanted = trait == .traitBold ? max(weight, Typeface.current.boldWeight.rawValue) : weight
        if font.familyName != UIFont.systemFont(ofSize: 12).familyName,
           let restyled = Typeface.font(family: font.familyName, weight: UIFont.Weight(wanted), italic: italic, size: font.pointSize) {
            return restyled
        }
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
        // A web link's ↗, in the room after its last letter, raised to its capitals.
        storage.enumerateAttribute(.prismExternal, in: characters) { value, range, _ in
            guard value != nil, storage.attribute(.prismHidden, at: range.location, effectiveRange: nil) == nil else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? metrics.body
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let box = boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainers[0])
            let baseline = fragment.minY + location(forGlyphAt: glyph).y
            let side = round(font.pointSize * 0.5)
            guard let arrow = UIImage(systemName: "arrow.up.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: side, weight: .semibold))?
                .withTintColor(Ink.secondary, renderingMode: .alwaysOriginal) else { return }
            let size = arrow.size
            let room = round(font.pointSize * 0.62)
            // The last letter's underline, as the rest of the link's: to its end, not the arrow's.
            Ink.faint.setFill()
            let ct = font as CTFont
            let line = max(1 / max(UIScreen.main.scale, 1), CTFontGetUnderlineThickness(ct))
            UIRectFill(CGRect(x: origin.x + box.minX, y: origin.y + baseline - CTFontGetUnderlinePosition(ct), width: max(0, box.width - room), height: line))
            arrow.draw(in: CGRect(x: origin.x + box.maxX - room + 2,
                                  y: origin.y + baseline - font.capHeight - 1, width: size.width, height: size.height))
        }
        storage.enumerateAttribute(.prismEllipsis, in: characters) { value, range, _ in
            guard value != nil else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont ?? metrics.body
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let place = location(forGlyphAt: glyph)
            let text = NSAttributedString(string: "…", attributes: [.font: font, .foregroundColor: Card.flat ? Ink.text : Ink.accent])
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
    /// Links on pills, an icon in each — not on the flat page, where they are underlined.
    static var drawsPills: Bool { !Card.flat }

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

    /// Each line's piece of a run of text, as far as what shows of it goes —
    /// hidden markup has no place — and as tall as `height` makes it about
    /// the line's baseline; a line's pieces, split by hidden characters, one.
    private func lineRects(of range: NSRange, at origin: CGPoint, outset: CGFloat,
                           height: @escaping (UIFont, CGFloat) -> (top: CGFloat, bottom: CGFloat)) -> [CGRect] {
        guard let storage = textStorage else { return [] }
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
                var end = last + 1 < NSMaxRange(lineGlyphs) ? fragment.minX + self.location(forGlyphAt: last + 1).x : used.maxX
                // Not the spaces a line breaks after, hanging past its words.
                if last + 1 >= NSMaxRange(lineGlyphs) || NSMaxRange(shown) == NSMaxRange(lineGlyphs) {
                    let text = storage.string as NSString
                    var word = last
                    while word > shown.location, text.character(at: self.characterIndexForGlyph(at: word)) == 0x20 { word -= 1 }
                    if word < last { end = fragment.minX + self.location(forGlyphAt: word + 1).x }
                }
                guard end > start else { return }
                let font = storage.attribute(.font, at: self.characterIndexForGlyph(at: shown.location), effectiveRange: nil) as? UIFont ?? self.metrics.body
                let baseline = fragment.minY + self.location(forGlyphAt: shown.location).y
                let (top, bottom) = height(font, baseline)
                let rect = CGRect(x: start, y: top, width: end - start, height: bottom - top).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -outset, dy: 0)
                lines[fragment.minY] = lines[fragment.minY].map { $0.union(rect) } ?? rect
            }
        }
        return Array(lines.values)
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
        // Pills behind links, as Slack draws them: even about the text, as
        // far above its capitals as below its descenders — not the line's
        // room, which is more above.
        storage.enumerateAttribute(.prismPill, in: covered) { value, range, _ in
            guard value != nil, Self.drawsPills else { return }
            Ink.pill.setFill()
            for pill in lineRects(of: range, at: origin, outset: 3, height: { font, baseline in
                let pad = round(font.pointSize * 0.18)
                return (baseline - font.capHeight - pad, baseline - font.descender + pad - round(font.pointSize * 0.06))
            }) { UIBezierPath(roundedRect: pill, cornerRadius: 5).fill() }
        }
        // Inline code's ground, and a highlight's: round their words on each line.
        storage.enumerateAttribute(.prismCode, in: covered) { value, range, _ in
            guard value != nil else { return }
            Ink.codeBack.setFill()
            for rect in lineRects(of: range, at: origin, outset: 2, height: { font, baseline in
                (baseline - font.ascender - 1, baseline - font.descender + 1)
            }) { UIBezierPath(roundedRect: rect, cornerRadius: 4).fill() }
        }
        storage.enumerateAttribute(.prismMarked, in: covered) { value, range, _ in
            guard value != nil else { return }
            Ink.marked.setFill()
            for rect in lineRects(of: range, at: origin, outset: 1, height: { font, baseline in
                (baseline - font.ascender, baseline - font.descender)
            }) { UIBezierPath(roundedRect: rect, cornerRadius: 3).fill() }
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
            // An empty row's only glyph, its line break, is placed at the
            // foot of the line, not on its baseline: its mark, where the
            // words' baseline would be — as the first letter typed puts it.
            let empty = paragraph.length <= 1 || first == NSMaxRange(paragraph) - 1
            let baseline = startsWithImage ? line.minY + PhoneImageBox.margin + ceil(font.ascender)
                : empty ? used.maxY + font.descender : line.minY + glyphLocation.y
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
            case .bullet where QuotedBullet.marker(in: storage.string as NSString, paragraph: paragraph, row: row) != nil:
                // `- > words`: a quote's bar for its bullet.
                let last = glyphRange(forCharacterRange: NSRange(location: NSMaxRange(paragraph) - 1, length: 1), actualCharacterRange: nil)
                let bottom = lineFragmentRect(forGlyphAt: max(last.location, glyph), effectiveRange: nil).maxY + origin.y
                Ink.faint.setFill()
                UIBezierPath(roundedRect: CGRect(x: markerX - 1.5, y: line.minY + 2, width: 3, height: bottom - line.minY - 6), cornerRadius: 1.5).fill()
            case .bullet, .ordered:
                if let task = row.task {
                    let side = round(font.pointSize * 0.82)
                    let box = CGRect(x: markerX - side / 2, y: baseline - font.capHeight / 2 - side / 2, width: side, height: side)
                    let round = row.marker == "+"
                    let shape = round ? UIBezierPath(ovalIn: box) : UIBezierPath(roundedRect: box, cornerRadius: 3.5)
                    if task.isDone {
                        // Ticked: black on the flat page, as all else is; else blue.
                        (Card.flat ? Ink.text : Ink.accent).setFill()
                        shape.fill()
                        let tick = UIBezierPath()
                        tick.move(to: CGPoint(x: box.minX + side * 0.27, y: box.midY))
                        tick.addLine(to: CGPoint(x: box.minX + side * 0.44, y: box.minY + side * 0.68))
                        tick.addLine(to: CGPoint(x: box.minX + side * 0.74, y: box.minY + side * 0.32))
                        tick.lineWidth = 1.8
                        tick.lineCapStyle = .round
                        tick.lineJoinStyle = .round
                        (Card.flat ? Ink.paper : UIColor.white).setStroke()
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
    /// A row and those under it moved straight to a note — a day's, for a
    /// task brought into today or put off: the app's to do.
    static var moveTo: ((OutlineEditor, Int, String) -> Void)?
    /// The words dictation should favour — the notes' names: the app's to say.
    static var dictationTerms: (() -> [String])?
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
            guard let self, self.isEditable, self.rowUnder(point) != nil,
                  self.webLink(at: point) == nil, self.noteLink(at: point) == nil else { return false }
            switch self.target(at: point) {
            case .image: return false
            case .marker: return true
            default: return !self.isFirstResponder
            }
        }
        rowHold.addTarget(self, action: #selector(heldRow(_:)))
        // A web link held — reading or typing — its menu, not the row picked up.
        linkHold.minimumPressDuration = 0.4
        linkHold.isOnPicture = { [weak self] point in self?.webLink(at: point) != nil || self?.noteLink(at: point) != nil }
        linkHold.addTarget(self, action: #selector(heldLink(_:)))
        linkHold.delegate = self
        addGestureRecognizer(linkHold)
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
        readingUndo.removeAllActions()
        endChoosingRows()
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
        readingUndo.removeAllActions()
        endChoosingRows()
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
    /// Where a row shown is, by its place among all the note's rows: a row
    /// folded away, the one it is folded in.
    func row(unfolded target: Int) -> Int? {
        var place = 0
        for (index, row) in rows.enumerated() {
            let inside = Row.unfold(row.folded).count
            if target >= place, target <= place + inside { return index }
            place += 1 + inside
        }
        return nil
    }

    /// Where a row is drawn, in the editor.
    func rowRect(_ index: Int) -> CGRect {
        let ranges = paragraphRanges
        guard ranges.indices.contains(index) else { return .zero }
        layoutIfNeeded()
        let glyphs = outlineLayout.glyphRange(forCharacterRange: ranges[index], actualCharacterRange: nil)
        return outlineLayout.boundingRect(forGlyphRange: glyphs, in: textContainer)
            .offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

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
        let undo = rowUndo
        undo.registerUndo(withTarget: self) { editor in editor.replace(before, caret: beforeCaret, undoName: undoName) }
        if let undoName { undo.setActionName(undoName) }
        if let caret { setCaret(caret) }
        changed()
        // Changed while read, not typed in: no keys to undo it with — said, with Undo.
        // Folding is only looking, not changing: not said.
        if !isFirstResponder, let undoName, !["Fold", "Unfold"].contains(undoName), !undo.isUndoing, !undo.isRedoing {
            NotificationCenter.default.post(name: .prismUndoable, object: self, userInfo: ["name": undoName, "undo": undo])
        }
    }

    /// Where a change to the rows is undone from: the text's own, typing;
    /// one of the editor's, else, which the text's is not while it is read.
    private var rowUndo: UndoManager { undoManager ?? readingUndo }
    private let readingUndo = UndoManager()

    func beginRowUndoGroup() { rowUndo.beginUndoGrouping() }
    func endRowUndoGroup() { rowUndo.endUndoGrouping() }

    // MARK: Dictating at the caret

    /// The keyboard bar's microphone: listening — what is heard written at
    /// the caret as it comes — or, listening, stopped.
    @objc func toggleDictation() {
        if let dictating = cursorDictation {
            cursorDictation = nil
            toolbar?.showDictating(nil)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            Task { @MainActor in await dictating.finish() }
            return
        }
        let dictating = CursorDictation(view: self)
        cursorDictation = dictating
        toolbar?.showDictating(.connecting)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task { @MainActor in
            guard await Dictation.allowed(), cursorDictation === dictating else {
                if cursorDictation === dictating { cursorDictation = nil }
                toolbar?.showDictating(nil)
                return
            }
            do {
                try dictating.start(keyterms: Self.dictationTerms?() ?? []) { [weak self] engine in
                    guard self?.cursorDictation === dictating else { return }
                    self?.toolbar?.showDictating(engine)
                }
            } catch {
                cursorDictation = nil
                toolbar?.showDictating(nil)
            }
        }
    }

    /// The keyboard bar's ↶ and ↷.
    @objc func undoChange() { rowUndo.undo(); showUndoState() }
    @objc func redoChange() { rowUndo.redo(); showUndoState() }

    func showUndoState() {
        toolbar?.showUndo(canUndo: rowUndo.canUndo, canRedo: rowUndo.canRedo)
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
        showFoldState()
        showUndoState()
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
        showFoldState()
    }
    func textViewDidEndEditing(_ textView: UITextView) {
        // Typing over: listening too — what was heard kept.
        if cursorDictation != nil { toggleDictation() }
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

    /// A keyboard's keys, as the Mac's: Tab in and out, the row moved,
    /// marked, folded, made a checkbox or a task.
    override var keyCommands: [UIKeyCommand]? {
        guard isFirstResponder else { return super.keyCommands }
        func key(_ title: String, _ input: String, _ flags: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(title: title, action: action, input: input, modifierFlags: flags)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return (super.keyCommands ?? []) + [
            key("Indent", "\t", [], #selector(indent)),
            key("Outdent", "\t", .shift, #selector(outdent)),
            key("Move Up", UIKeyCommand.inputUpArrow, [.command, .control], #selector(moveUp)),
            key("Move Down", UIKeyCommand.inputDownArrow, [.command, .control], #selector(moveDown)),
            key("Bold", "b", .command, #selector(makeBold)),
            key("Italic", "i", .command, #selector(makeItalic)),
            key("Highlight", "h", [.command, .shift], #selector(makeHighlighted)),
            key("Link…", "k", [.command, .alternate], #selector(insertLink)),
            key("Checklist Item", "\r", .command, #selector(cycleChecklist)),
            key("Task", "\r", [.command, .shift], #selector(cycleTask)),
            key("Fold", "9", .command, #selector(foldHere)),
            key("Unfold", "0", .command, #selector(unfoldHere)),
            key("New Time Block", "\r", [.command, .alternate], #selector(newTimeBlock)),
        ]
    }

    @objc func foldHere() {
        guard rows.indices.contains(caret.row), !rows[caret.row].isFolded, OutlineEditing.hasChildren(rows, caret.row) else { return }
        toggleFoldHere()
    }

    @objc func unfoldHere() {
        guard rows.indices.contains(caret.row), rows[caret.row].isFolded else { return }
        toggleFoldHere()
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

    /// The keyboard bar's fold button, for the row typed in: Fold, Unfold,
    /// or nothing to fold.
    func showFoldState() {
        guard let toolbar, isFirstResponder else { return }
        let all = rows, index = caret.row
        guard all.indices.contains(index) else { return }
        toolbar.showFold(folded: all[index].isFolded, foldable: all[index].isFolded || OutlineEditing.hasChildren(all, index))
    }

    /// The row typed in, folded or opened: the keyboard bar's.
    @objc func toggleFoldHere() {
        toggleFold(at: caret.row)
        showFoldState()
        UISelectionFeedbackGenerator().selectionChanged()
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
        // The notes to link offered at once, as typing `[[` offers them.
        beginCompletion(typedAt: selectedRange.location - 1)
        refreshCompletion()
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
        // Choosing rows: a tap anywhere on a row takes it in, or out.
        if gesture === markerTap, isChoosingRows { return rowUnder(gesture.location(in: self)) != nil }
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
        return (gesture === pictureHold || gesture === rowHold || gesture === linkHold) && other.view === self
            && other !== markerTap && other !== pictureHold && other !== rowHold && other !== linkHold
    }



    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture is UISwipeGestureRecognizer || gesture === dragScroll || other === dragScroll
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if isChoosingRows {
            if let index = rowUnder(gesture.location(in: self)) { toggleChosen(index) }
            return
        }
        switch target(at: gesture.location(in: self)) {
        case .marker(let index):
            let row = rows[index]
            if row.task != nil {
                guard let toggled = OutlineKeys.toggle(rows, at: index) else { return }
                replace(toggled, caret: isFirstResponder ? caret : nil, undoName: "Toggle Done")
            } else {
                // Nothing under it to fold: nothing done, nothing felt.
                guard row.isFolded || OutlineEditing.hasChildren(rows, index) else { return }
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
            // Anywhere else, the picture on its own — a carousel's all, at
            // the one it shows — to zoom into and share.
            if let carousel = carousel(at: point) {
                let files = carousel.box.sources.compactMap(PhoneImages.url(for:))
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
                viewPictures(files, at: PhoneCarousel.index(carousel.box), from: carousel.frame)
            } else if let file = pictureFile(span) {
                viewPictures([file], at: 0, from: pictureFrame(span) ?? CGRect(origin: point, size: .zero))
            } else {
                // Not a file here — one from the web — its Markdown, to edit.
                if !isFirstResponder { becomeFirstResponder() }
                selectedRange = NSRange(location: NSMaxRange(span), length: 0)
            }
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
    /// A web link held: its title, to add or change.
    private let linkHold = PictureHold()
    private let rowHold = PictureHold()
    /// The day the note is, if one: on today's, time blocks show the time now.
    var day: Day? {
        didSet { outlineLayout.today = day == .today }
    }
    var rowDrag: RowDragState?
    /// Listening, what is heard written at the caret: the keyboard bar's microphone.
    var cursorDictation: CursorDictation?
    /// Rows chosen together, while they are: no typing meanwhile.
    var rowChoice: RowChoice?
    override var canBecomeFirstResponder: Bool { rowChoice == nil && super.canBecomeFirstResponder }
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

    /// Where the row menu was asked for, in the editor.
    private var rowMenuPoint: CGPoint = .zero

    /// A row held and let go in place: its menu, if it has anything in it.
    func showRowMenu(forRow index: Int, at point: CGPoint) {
        guard !rowActions(index).isEmpty else { return }
        rowMenuPoint = point
        // After the finger is up: shown as it lifts, the menu goes with it.
        DispatchQueue.main.async { [self] in
            pictureMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: "row:\(index)" as NSString, sourcePoint: point))
        }
    }

    /// What can be done to a row held: folded or opened — a checkbox's,
    /// a number's, as a bullet's — all the way down too; a checklist's
    /// done items to the bottom.
    func rowActions(_ index: Int) -> [UIAction] {
        let all = rows
        guard all.indices.contains(index) else { return [] }
        let row = all[index]
        let end = OutlineEditing.subtreeEnd(all, index)
        let inside = all[(index + 1)..<end]
        var actions: [UIAction] = []
        if row.isFolded {
            actions.append(UIAction(title: "Unfold", image: UIImage(systemName: "rectangle.expand.vertical")) { [weak self] _ in
                self?.toggleFold(at: index)
            })
        } else if !inside.isEmpty {
            actions.append(UIAction(title: "Fold", image: UIImage(systemName: "rectangle.compress.vertical")) { [weak self] _ in
                self?.toggleFold(at: index)
            })
        }
        // Folded within, deeper down: all of it at once.
        if row.isFolded ? row.folded.contains(where: { $0.isFolded }) : inside.contains(where: { $0.isFolded }) {
            actions.append(UIAction(title: "Unfold Completely", image: UIImage(systemName: "arrow.up.and.down")) { [weak self] _ in
                self?.unfoldCompletely(at: index)
            })
        }
        if !row.isFolded, zip(inside.indices, inside).contains(where: { i, child in OutlineEditing.hasChildren(all, i) && !child.isFolded }) {
            actions.append(UIAction(title: "Fold Completely", image: UIImage(systemName: "arrow.down.and.line.horizontal.and.arrow.up")) { [weak self] _ in
                self?.foldCompletely(at: index)
            })
        }
        if let task = row.task {
            actions.append(UIAction(title: task == .open ? "Mark Done" : "Mark Not Done",
                                    image: UIImage(systemName: task == .open ? "checkmark.circle" : "circle")) { [weak self] _ in
                guard let self, let toggled = OutlineKeys.toggle(rows, at: index) else { return }
                replace(toggled, caret: isFirstResponder ? caret : nil, undoName: "Toggle Done")
            })
        }
        if hasChecklist(under: index) {
            var moved = all
            let movable = OutlineEditing.moveDoneToBottom(&moved, under: index)
            actions.append(UIAction(title: "Move Done to Bottom", image: UIImage(systemName: "arrow.down.to.line"),
                                    attributes: movable ? [] : .disabled) { [weak self] _ in self?.moveDoneToBottom(under: index) })
        }
        // A task: into today, or put off to a day — moved into that day's note.
        if isEditable, Tasks.isTask(row), row.task?.isDone != true, let move = Self.moveTo {
            let today = Day.today
            if day != today {
                actions.append(UIAction(title: "Do Today", image: UIImage(systemName: "sun.max")) { [weak self] _ in
                    guard let self else { return }
                    move(self, index, GraphPaths.dailyPath(for: today))
                })
            }
            let later = TaskLater.allCases.filter { $0.day(from: today) != day }.map { option in
                UIAction(title: option.title, image: UIImage(systemName: option.symbol)) { [weak self] _ in
                    guard let self else { return }
                    move(self, index, GraphPaths.dailyPath(for: option.day(from: today)))
                }
            }
            actions.append(UIAction(title: "Later…", image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
                self?.showLater(later, forRow: index)
            })
        }
        if isEditable, onMoveRows != nil {
            actions.append(UIAction(title: "Move to…", image: UIImage(systemName: "arrow.right.doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                onMoveRows?(self, index)
            })
        }
        if isEditable {
            actions.append(UIAction(title: "Select Rows", image: UIImage(systemName: "checklist")) { [weak self] _ in
                self?.beginChoosingRows(with: index)
            })
            actions.append(UIAction(title: "Turn Into…", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self] _ in
                self?.showTurnInto(forRow: index)
            })
            actions.append(UIAction(title: "Delete Row", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.deleteRow(at: index)
            })
        }
        return actions
    }

    // MARK: VoiceOver

    /// What can be done to the row the caret is in, as VoiceOver's actions:
    /// its box ticked, it folded — what the margin's marks do to a finger.
    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get {
            let index = caret.row
            guard rows.indices.contains(index) else { return nil }
            var actions: [UIAccessibilityCustomAction] = []
            if let task = rows[index].task {
                actions.append(UIAccessibilityCustomAction(name: task == .open ? "Mark Done" : "Mark Not Done") { [weak self] _ in
                    guard let self, let toggled = OutlineKeys.toggle(rows, at: index) else { return false }
                    replace(toggled, caret: isFirstResponder ? caret : nil, undoName: "Toggle Done")
                    UIAccessibility.post(notification: .announcement, argument: task == .open ? "Done" : "Not done")
                    return true
                })
            }
            for action in rowActions(index) where !action.title.hasPrefix("Mark ") && action.title != "Turn Into…" {
                actions.append(UIAccessibilityCustomAction(name: action.title) { [weak self] _ in
                    guard let self else { return false }
                    action.performWithSender(nil, target: nil)
                    UIAccessibility.post(notification: .layoutChanged, argument: self)
                    return true
                })
            }
            return actions
        }
        set {}
    }

    /// What the row the caret is in is — a box, ticked or not; folded —
    /// which its words alone do not say.
    override var accessibilityHint: String? {
        get {
            let index = caret.row
            guard rows.indices.contains(index) else { return nil }
            let row = rows[index]
            var said: [String] = []
            if let task = row.task { said.append(task == .open ? "Not done" : "Done") }
            if row.isFolded { said.append("Folded, \(Row.unfold(row.folded).count) rows inside") }
            // The ring round a list's bullet: how much of it is done.
            if hasChecklist(under: index), case let progress = Checkboxes.underEach(rows)[index], !progress.isEmpty {
                said.append("\(progress.done) of \(progress.total) done")
            }
            return said.isEmpty ? nil : said.joined(separator: ". ")
        }
        set {}
    }

    /// When to put a task off to, to choose from — or another day, by Move to….
    private func showLater(_ options: [UIAction], forRow index: Int) {
        let sheet = UIAlertController(title: "Later", message: nil, preferredStyle: .actionSheet)
        for option in options {
            sheet.addAction(UIAlertAction(title: option.title, style: .default) { _ in option.performWithSender(nil, target: nil) })
        }
        if onMoveRows != nil {
            sheet.addAction(UIAlertAction(title: "Another Day…", style: .default) { [weak self] _ in
                guard let self else { return }
                onMoveRows?(self, index)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = CGRect(origin: rowMenuPoint, size: .zero)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.present(sheet, animated: true)
    }

    /// The kinds a row can be, to choose from: as the Mac's Turn Into.
    private func showTurnInto(forRow index: Int) {
        guard rows.indices.contains(index) else { return }
        let row = rows[index]
        let kinds: [(String, String, Bool, (inout Row) -> Void)] = [
            ("Bullet", "list.bullet", row.kind == .bullet && row.task == nil, { $0.kind = .bullet; $0.task = nil; $0.marker = "-" }),
            ("Checkbox", "checkmark.square", row.kind == .bullet && row.task != nil && row.marker != "+",
             { $0.kind = .bullet; $0.marker = "-"; $0.task = $0.task ?? .open }),
            ("Task", "checkmark.circle", row.kind == .bullet && row.task != nil && row.marker == "+",
             { $0.kind = .bullet; $0.marker = "+"; $0.task = $0.task ?? .open }),
            ("Numbered", "list.number", row.kind == .ordered, { $0.kind = .ordered; $0.marker = "."; $0.task = nil }),
            ("Heading 1", "textformat.size.larger", row.kind == .heading(1), { $0.kind = .heading(1); $0.task = nil }),
            ("Heading 2", "textformat.size", row.kind == .heading(2), { $0.kind = .heading(2); $0.task = nil }),
            ("Heading 3", "textformat.size.smaller", row.kind == .heading(3), { $0.kind = .heading(3); $0.task = nil }),
            ("Quote", "text.quote", row.kind == .quote, { $0.kind = .quote; $0.task = nil }),
        ]
        let sheet = UIAlertController(title: "Turn Into", message: nil, preferredStyle: .actionSheet)
        for (title, _, current, change) in kinds {
            sheet.addAction(UIAlertAction(title: current ? "✓ " + title : title, style: .default) { [weak self] _ in
                guard let self, rows.indices.contains(index) else { return }
                var all = rows
                all[index].spacing = 1
                change(&all[index])
                OutlineEditing.normalize(&all)
                replace(all, caret: isFirstResponder ? caret : nil, undoName: "Change Row Type")
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = self
        sheet.popoverPresentationController?.sourceRect = CGRect(origin: rowMenuPoint, size: .zero)
        window?.rootViewController.map { root in
            var top = root
            while let presented = top.presentedViewController { top = presented }
            top.present(sheet, animated: true)
        }
    }

    /// A row and those under it moved to another note: put there by
    /// `put`, which registers how to take them out again; taken out here.
    /// One undo puts them back where they were.
    func moveRows(at index: Int, named name: String, put: ([Row], UndoManager) -> Void) {
        var all = rows
        guard all.indices.contains(index) else { return }
        // Choosing rows: all of them, each with those under it, in order.
        let blocks = isChoosingRows && !chosenBlocks.isEmpty ? chosenBlocks : [OutlineEditing.block(all, index..<(index + 1))]
        endChoosingRows()
        let taken = blocks.flatMap { RowMove.detached(Array(all[$0])) }
        let undo = rowUndo
        undo.beginUndoGrouping()
        put(taken, undo)
        for block in blocks.reversed() { _ = OutlineEditing.delete(&all, block) }
        replace(all, caret: nil, undoName: "Move to " + name)
        undo.endUndoGrouping()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A row, and the rows under it, taken away.
    private func deleteRow(at index: Int) {
        var all = rows
        guard all.indices.contains(index) else { return }
        _ = OutlineEditing.delete(&all, index..<(index + 1))
        replace(all, caret: nil, undoName: "Delete Row")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func unfoldCompletely(at index: Int) {
        var all = rows
        guard all.indices.contains(index), OutlineEditing.unfold(&all, at: index, completely: true) > 0 else { return }
        replace(all, caret: isFirstResponder ? caret : nil, undoName: "Unfold")
    }

    func foldCompletely(at index: Int) {
        var all = rows
        guard all.indices.contains(index), OutlineEditing.foldCompletely(&all, at: index) > 0 else { return }
        let caret = self.caret.row > index && self.caret.row < OutlineEditing.subtreeEnd(rows, index)
            ? OutlineKeys.Caret(row: index, offset: 0) : self.caret
        replace(all, caret: isFirstResponder ? caret : nil, undoName: "Fold")
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

    // MARK: A link's title

    /// The web link at a point: its row, where in the row's text, where it
    /// goes, the title it shows, and where it is drawn.
    private func webLink(at point: CGPoint) -> (row: Int, offset: Int, address: String, title: String, frame: CGRect)? {
        guard textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = outlineLayout.glyphIndex(for: inContainer, in: textContainer)
        guard glyph < outlineLayout.numberOfGlyphs else { return nil }
        let bounds = outlineLayout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard bounds.insetBy(dx: -4, dy: -4).contains(inContainer) else { return nil }
        let character = outlineLayout.characterIndexForGlyph(at: glyph)
        let row = rowIndex(at: character)
        let paragraph = paragraphRanges[row]
        let text = textStorage.mutableString
        let body = NSRange(location: paragraph.location, length: max(0, paragraph.length - 1))
        guard let span = InlineMarkup.spans(in: text, range: body).first(where: { NSLocationInRange(character, $0.range) }),
              let link = LinkTitle.link(span, in: text) else { return nil }
        let drawn = outlineLayout.boundingRect(forGlyphRange: outlineLayout.glyphRange(forCharacterRange: span.content, actualCharacterRange: nil),
                                               in: textContainer).offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        return (row, span.range.location - paragraph.location, link.address, link.title, drawn)
    }

    /// The link held, for its menu.
    private var heldLinkNow: (row: Int, offset: Int, address: String, title: String, frame: CGRect)?

    /// The link to a note at a point — `[[Title]]` — and where it is drawn.
    private func noteLink(at point: CGPoint) -> (link: String, frame: CGRect)? {
        guard textStorage.length > 0 else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
        let glyph = outlineLayout.glyphIndex(for: inContainer, in: textContainer)
        guard glyph < outlineLayout.numberOfGlyphs,
              outlineLayout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).insetBy(dx: -4, dy: -4).contains(inContainer)
        else { return nil }
        let character = outlineLayout.characterIndexForGlyph(at: glyph)
        var range = NSRange()
        guard character < textStorage.length,
              let link = textStorage.attribute(.prismLink, at: character, effectiveRange: &range) as? String, link.hasPrefix("[[") else { return nil }
        let drawn = outlineLayout.boundingRect(forGlyphRange: outlineLayout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: textContainer)
        return (link, drawn.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top))
    }

    /// The link to a note held, for its menu.
    private var heldNoteLink: (link: String, frame: CGRect)?

    @objc private func heldLink(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, webLink(at: gesture.location(in: self)) == nil, let link = noteLink(at: gesture.location(in: self)) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            heldNoteLink = link
            pictureMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: "notelink" as NSString,
                                                                       sourcePoint: CGPoint(x: link.frame.midX, y: link.frame.minY)))
            return
        }
        guard gesture.state == .began, let link = webLink(at: gesture.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        heldLinkNow = link
        pictureMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: "link" as NSString, sourcePoint: CGPoint(x: link.frame.midX, y: link.frame.minY)))
    }

    /// What can be done with the link held.
    fileprivate func linkMenu() -> UIMenu? {
        guard let link = heldLinkNow else { return nil }
        var actions: [UIMenuElement] = []
        if isEditable {
            actions.append(UIAction(title: link.title.isEmpty ? "Add Title…" : "Edit Title…", image: UIImage(systemName: "character.cursor.ibeam")) { [weak self] _ in
                self?.askTitle(for: link)
            })
            // Its card — a post, a video, a page — hidden or shown again.
            let hidden = rows.indices.contains(link.row) ? LinkTitle.hidesCard(rows[link.row].text, at: link.offset) ?? false : false
            if hidden || hasCard(link) {
                actions.append(UIAction(title: hidden ? "Show Card" : "Hide Card", image: UIImage(systemName: hidden ? "rectangle" : "rectangle.slash")) {
                    [weak self] _ in self?.setCard(link, hidden: !hidden)
                })
            }
        }
        actions.append(UIAction(title: "Open", image: UIImage(systemName: "doc.plaintext")) { [weak self] _ in self?.onOpenLink?(link.address) })
        if let url = URL(string: link.address) {
            actions.append(UIAction(title: "Open in Browser", image: UIImage(systemName: "safari")) { _ in UIApplication.shared.open(url) })
        }
        actions.append(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = link.address })
        return UIMenu(children: actions)
    }

    /// A link to a note held: opened, or copied.
    fileprivate func noteLinkMenu() -> UIMenu? {
        guard let held = heldNoteLink else { return nil }
        let link = held.link
        let title = String(link.dropFirst(2).dropLast(2)).components(separatedBy: "|")[0]
        return UIMenu(children: [
            UIAction(title: "Open", image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.onOpenLink?(link) },
            UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = "[[\(title)]]" },
        ])
    }

    fileprivate var heldLinkFrame: CGRect? { heldLinkNow?.frame }

    /// Asks for a link's title — the one it has, to change — and sets it;
    /// none, the address alone.
    private func askTitle(for link: (row: Int, offset: Int, address: String, title: String, frame: CGRect)) {
        let alert = UIAlertController(title: link.title.isEmpty ? "Add a Title" : "Edit the Title", message: link.address, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = link.title
            field.placeholder = "The words the link shows"
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if !link.title.isEmpty {
            alert.addAction(UIAlertAction(title: "Remove Title", style: .destructive) { [weak self] _ in self?.retitle(link, to: "") })
        }
        alert.addAction(UIAlertAction(title: link.title.isEmpty ? "Add" : "Change", style: .default) { [weak self, weak alert] _ in
            self?.retitle(link, to: alert?.textFields?.first?.text ?? "")
        })
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(alert, animated: true)
    }

    /// Whether the link shows a card under its row.
    private func hasCard(_ link: (row: Int, offset: Int, address: String, title: String, frame: CGRect)) -> Bool {
        guard paragraphRanges.indices.contains(link.row) else { return false }
        let at = paragraphRanges[link.row].location + link.offset
        return at < textStorage.length && textStorage.attribute(.prismCard, at: at, effectiveRange: nil) != nil
    }

    /// A link's card hidden — `"no card"` written after its address — or shown
    /// again, as a change to its row: undone as one.
    private func setCard(_ link: (row: Int, offset: Int, address: String, title: String, frame: CGRect), hidden: Bool) {
        var all = rows
        guard all.indices.contains(link.row), let changed = LinkTitle.settingCard(all[link.row].text, at: link.offset, hidden: hidden) else { return }
        all[link.row].text = changed.text
        replace(all, caret: isFirstResponder ? caret : nil, undoName: hidden ? "Hide Card" : "Show Card")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A link's title set, as a change to its row: undone as one.
    private func retitle(_ link: (row: Int, offset: Int, address: String, title: String, frame: CGRect), to title: String) {
        var all = rows
        guard all.indices.contains(link.row), let retitled = LinkTitle.retitling(all[link.row].text, at: link.offset, to: title) else { return }
        all[link.row].text = retitled.text
        replace(all, caret: isFirstResponder ? caret : nil, undoName: link.title.isEmpty ? "Add Link Title" : "Edit Link Title")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Pictures seen

    /// The viewer's pictures, kept while it shows them: it holds its source loosely.
    private var viewing: PictureViewer?

    /// Pictures in Quick Look over the app, from the one at `index`: to
    /// zoom into and share.
    private func viewPictures(_ files: [URL], at index: Int, from frame: CGRect) {
        guard !files.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let viewer = PictureViewer(files: files, from: frame, in: self)
        viewing = viewer
        let preview = QLPreviewController()
        preview.dataSource = viewer
        preview.delegate = viewer
        preview.currentPreviewItemIndex = min(max(index, 0), files.count - 1)
        var presenter = window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(preview, animated: true)
    }

    /// The file a picture's Markdown shows, in the graph.
    private func pictureFile(_ span: NSRange) -> URL? {
        pictureSource(span).flatMap(PhoneImages.url(for:)).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Told when a picture in the note is chosen as its cover.
    var onMakeCover: ((String) -> Void)?
    /// A row's Move to…: where to, asked for — then `moveRows(at:to:)`.
    var onMoveRows: ((OutlineEditor, Int) -> Void)?

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

    /// Whether a carousel is at a point in the editor.
    func hasCarousel(at point: CGPoint) -> Bool { carousel(at: point) != nil }

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

/// Over the keyboard: what an outline wants that the keys do not have —
/// floating glass, the note showing between: Aa and away at the ends of
/// the main capsule, and over it two small ones, to move the row typed in,
/// in and out, up and down. Aa turns the capsule to the words' tools.
final class OutlineToolbar: UIInputView {
    private static let small: CGFloat = 32
    private static let main: CGFloat = 46
    private static let gap: CGFloat = 8
    private static let height: CGFloat = small + gap + main + 6

    /// One glass, its pieces near enough to run together as they move.
    private let container = UIVisualEffectView(effect: {
        let effect = UIGlassContainerEffect()
        effect.spacing = 12
        return effect
    }())
    private let shift = OutlineToolbar.glass()
    private let move = OutlineToolbar.glass()
    private let history = OutlineToolbar.glass()
    private let words = OutlineToolbar.glass()
    private let capsule = OutlineToolbar.glass()
    private let away = OutlineToolbar.glass()
    private let wordsButton = UIButton(type: .system)
    private let tools = UIStackView()
    private let formatting = UIStackView()
    private weak var fold: UIButton?
    private weak var mic: UIButton?
    private weak var undo: UIButton?
    private weak var redo: UIButton?
    private let chips = UIScrollView()
    private let chipRow = UIStackView()

    private static func glass() -> UIVisualEffectView {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }

    init(editor: OutlineEditor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: Self.height), inputViewStyle: .default)
        backgroundColor = .clear
        let shifts = Self.stack([
            ("decrease.indent", #selector(OutlineEditor.outdent), "Outdent"),
            ("increase.indent", #selector(OutlineEditor.indent), "Indent"),
        ], editor: editor, size: 14)
        let moves = Self.stack([
            ("arrow.up", #selector(OutlineEditor.moveUp), "Move Up"),
            ("arrow.down", #selector(OutlineEditor.moveDown), "Move Down"),
        ], editor: editor, size: 14)
        let undos = Self.stack([
            ("arrow.uturn.backward", #selector(OutlineEditor.undoChange), "Undo"),
            ("arrow.uturn.forward", #selector(OutlineEditor.redoChange), "Redo"),
        ], editor: editor, size: 14)
        shift.contentView.addSubview(shifts)
        move.contentView.addSubview(moves)
        history.contentView.addSubview(undos)
        undo = undos.arrangedSubviews.first as? UIButton
        redo = undos.arrangedSubviews.last as? UIButton
        for (stack, items) in [(tools, [
            ("rectangle.compress.vertical", #selector(OutlineEditor.toggleFoldHere), "Fold"),
            ("checkmark.square", #selector(OutlineEditor.cycleChecklist), "Checklist"),
            ("checkmark.circle", #selector(OutlineEditor.cycleTask), "Task"),
            ("link", #selector(OutlineEditor.insertLink), "Link"),
            ("clock", #selector(OutlineEditor.newTimeBlock), "New Time Block"),
            ("mic", #selector(OutlineEditor.toggleDictation), "Dictate"),
        ]), (formatting, [
            ("bold", #selector(OutlineEditor.makeBold), "Bold"),
            ("italic", #selector(OutlineEditor.makeItalic), "Italic"),
            ("strikethrough", #selector(OutlineEditor.makeStruck), "Strikethrough"),
            ("highlighter", #selector(OutlineEditor.makeHighlighted), "Highlight"),
            ("chevron.left.forwardslash.chevron.right", #selector(OutlineEditor.makeCode), "Code"),
            ("number", #selector(OutlineEditor.cycleHeading), "Heading"),
            ("text.quote", #selector(OutlineEditor.toggleQuote), "Quote"),
        ])] as [(UIStackView, [(String, Selector, String)])] {
            Self.fill(stack, items, editor: editor, size: 17)
            capsule.contentView.addSubview(stack)
        }
        fold = tools.arrangedSubviews.first as? UIButton
        mic = tools.arrangedSubviews.last as? UIButton
        formatting.alpha = 0
        formatting.isHidden = true

        wordsButton.setImage(UIImage(systemName: "textformat", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        wordsButton.tintColor = Ink.text
        wordsButton.accessibilityLabel = "Formatting"
        wordsButton.addAction(UIAction { [weak self] _ in self?.toggleWords() }, for: .touchUpInside)
        words.contentView.addSubview(wordsButton)
        let down = Self.button("keyboard.chevron.compact.down", #selector(UIResponder.resignFirstResponder), "Done", editor: editor, size: 17)
        away.contentView.addSubview(down)

        chips.showsHorizontalScrollIndicator = false
        chips.isHidden = true
        chipRow.axis = .horizontal
        chipRow.spacing = 6
        chips.addSubview(chipRow)
        capsule.contentView.addSubview(chips)

        for piece in [history, shift, move, words, capsule, away] { container.contentView.addSubview(piece) }
        addSubview(container)
        autoresizingMask = .flexibleHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: Self.height) }

    private static func button(_ symbol: String, _ action: Selector, _ label: String, editor: OutlineEditor, size: CGFloat) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular)), for: .normal)
        button.tintColor = Ink.text
        button.accessibilityLabel = label
        button.addTarget(editor, action: action, for: .touchUpInside)
        return button
    }

    private static func fill(_ stack: UIStackView, _ items: [(String, Selector, String)], editor: OutlineEditor, size: CGFloat) {
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        for (symbol, action, label) in items { stack.addArrangedSubview(button(symbol, action, label, editor: editor, size: size)) }
    }

    private static func stack(_ items: [(String, Selector, String)], editor: OutlineEditor, size: CGFloat) -> UIStackView {
        let stack = UIStackView()
        fill(stack, items, editor: editor, size: size)
        return stack
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        let left = max(12, safeAreaInsets.left + 8), right = bounds.width - max(12, safeAreaInsets.right + 8)
        let y = Self.small + Self.gap
        words.frame = CGRect(x: left, y: y, width: Self.main, height: Self.main)
        away.frame = CGRect(x: right - Self.main, y: y, width: Self.main, height: Self.main)
        capsule.frame = CGRect(x: words.frame.maxX + Self.gap, y: y, width: away.frame.minX - Self.gap - words.frame.maxX - Self.gap, height: Self.main)
        wordsButton.frame = words.bounds
        away.contentView.subviews.first?.frame = away.bounds
        let inside = capsule.bounds.insetBy(dx: 8, dy: 0)
        tools.frame = inside
        formatting.frame = inside
        chips.frame = capsule.bounds
        let chipsWidth = chipRow.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width
        chipRow.frame = CGRect(x: 6, y: 6, width: chipsWidth, height: Self.main - 12)
        chips.contentSize = CGSize(width: chipsWidth + 12, height: Self.main)
        // The small ones over the middle of the main, side by side: undo, then the row's moves.
        let width: CGFloat = 88
        let middle = capsule.frame.midX
        history.frame = CGRect(x: middle - width * 1.5 - Self.gap, y: 0, width: width, height: Self.small)
        shift.frame = CGRect(x: middle - width / 2, y: 0, width: width, height: Self.small)
        move.frame = CGRect(x: middle + width / 2 + Self.gap, y: 0, width: width, height: Self.small)
        for piece in [history, shift, move] { piece.contentView.subviews.first?.frame = piece.bounds.insetBy(dx: 4, dy: 0) }
    }

    /// Touches between the pieces: the note's, under them, not the bar's.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === container || hit === container.contentView ? nil : hit
    }

    /// Aa: the capsule to the words' tools, Aa lit while it is; again, back.
    private func toggleWords() {
        let toWords = formatting.isHidden
        let effect = UIGlassEffect()
        effect.isInteractive = true
        if toWords { effect.tintColor = Ink.accent }
        let (shown, hidden) = toWords ? (formatting, tools) : (tools, formatting)
        // Links being chosen: the tools turned to, under them, for after.
        shown.isHidden = !chips.isHidden
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.words.effect = effect
            self.wordsButton.tintColor = toWords ? .white : Ink.text
            shown.alpha = 1
            hidden.alpha = 0
        } completion: { _ in
            hidden.isHidden = true
        }
    }

    /// The microphone: lit red while listening — faint while ElevenLabs is
    /// asked — and plain again when it stops.
    func showDictating(_ engine: Dictation.Engine?) {
        guard let mic else { return }
        mic.setImage(UIImage(systemName: engine == nil ? "mic" : "mic.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        mic.tintColor = engine == nil ? Ink.text : engine == .connecting ? UIColor.systemRed.withAlphaComponent(0.45) : .systemRed
        mic.accessibilityLabel = engine == nil ? "Dictate" : "Stop Dictating"
    }

    /// ↶ and ↷, dimmed when there is nothing to undo, or redo.
    func showUndo(canUndo: Bool, canRedo: Bool) {
        undo?.isEnabled = canUndo
        redo?.isEnabled = canRedo
    }

    /// Fold, for a row with children; Unfold, for one folded; dimmed, neither.
    func showFold(folded: Bool, foldable: Bool) {
        guard let fold else { return }
        fold.setImage(UIImage(systemName: folded ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)), for: .normal)
        fold.accessibilityLabel = folded ? "Unfold" : "Fold"
        fold.isEnabled = foldable
    }

    /// Links to choose from, in the capsule in place of its tools — the
    /// first, which Return puts in, marked — or, with none, the tools again.
    func show(_ candidates: [LinkSuggestions.Candidate], choose: @escaping (LinkSuggestions.Candidate) -> Void) {
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, candidate) in candidates.enumerated() {
            var configuration = UIButton.Configuration.filled()
            configuration.title = candidate.title
            configuration.image = UIImage(systemName: candidate.isDay ? "calendar" : candidate.title.hasPrefix("New “") ? "plus"
                                          : candidate.isTopic ? "number" : "doc.text",
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
        let choosing = !candidates.isEmpty
        chips.isHidden = !choosing
        let current = formatting.isHidden ? tools : formatting
        current.isHidden = choosing
        chips.contentOffset = .zero
        setNeedsLayout()
    }
}

extension OutlineEditor: UIEditMenuInteractionDelegate {
    /// Copy and Share, for the picture held; for a row held, what can be
    /// done to it.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let id = configuration.identifier as? NSString else { return nil }
        if id == "link" { return linkMenu() }
        if id == "notelink" { return noteLinkMenu() }
        if id.hasPrefix("row:"), let index = Int(id.substring(from: 4)) {
            let actions = rowActions(index)
            return actions.isEmpty ? nil : UIMenu(children: actions)
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
        if id == "link" { return heldLinkFrame ?? .null }
        if id == "notelink" { return heldNoteLink?.frame ?? .null }
        if id.hasPrefix("row:") { return CGRect(x: rowMenuPoint.x - 12, y: rowMenuPoint.y - 12, width: 24, height: 24) }
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
        (Card.flat ? Ink.text : Ink.accent).setStroke()
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
    static func image(_ progress: Checkboxes.Progress, side: CGFloat, tick: Bool = true) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            draw(progress, in: CGRect(x: 0, y: 0, width: side, height: side), lineWidth: 1.8, tick: tick)
        }
    }
}

/// The pictures Quick Look shows, and where in the note they grow from and
/// go back to.
final class PictureViewer: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let files: [URL]
    let frame: CGRect
    weak var view: UIView?

    init(files: [URL], from frame: CGRect, in view: UIView) {
        self.files = files
        self.frame = frame
        self.view = view
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { files.count }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        files[index] as NSURL
    }

    /// Grown from the picture in the note, and gone back into it.
    func previewController(_ controller: QLPreviewController, frameFor item: QLPreviewItem,
                           inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>) -> CGRect {
        view.pointee = self.view
        return frame
    }

    /// Not marked up here: the picture is the note's, and a copy would go
    /// nowhere. Sharing it can.
    func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
        .disabled
    }
}
