import UIKit
import ReflectCore
import PrismCore

extension NSAttributedString.Key {
    /// Markup not shown: a span's marks, while the caret is away from it.
    static let prismHidden = NSAttributedString.Key("PrismHidden")
    /// A link drawn as a pill.
    static let prismPill = NSAttributedString.Key("PrismPill")
    /// Where a link goes, as tapped: a note's title, or an address.
    static let prismLink = NSAttributedString.Key("PrismLink")
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
    /// Where the caret is: the span it is in shows its marks.
    var caret: Int?
    /// Rows folded inside a row an edit swallowed, with where they belong.
    var orphans: [(location: Int, rows: [Row])] = []

    init(metrics: PhoneMetrics) {
        self.metrics = metrics
    }

    func textStorage(_ storage: NSTextStorage, didProcessEditing mask: NSTextStorage.EditActions,
                     range edited: NSRange, changeInLength delta: Int) {
        guard storage.length > 0 else { return }
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
            storage.fixAttributes(in: paragraph)
        }
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
        if case .heading = row.kind { before = round(metrics.size * 0.8) }
        paragraph.paragraphSpacingBefore = previous == nil ? 0 : before
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: Ink.text]
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
            case .wikiLink(let title):
                storage.addAttributes([.foregroundColor: Ink.accent, .prismLink: "[[" + title + "]]"], range: content)
                if !inHeading { storage.addAttribute(.prismPill, value: true, range: span.range) }
            case .tag:
                storage.addAttribute(.foregroundColor, value: Ink.accent, range: span.range)
            case .comment:
                if !revealed { storage.addAttribute(.prismHidden, value: true, range: span.range) }
            case .image, .imageText:
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
    var hasChildren: (Int) -> Bool = { _ in false }

    override init() {
        super.init()
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: UIFont, forGlyphRange range: NSRange) -> Int {
        guard let storage = textStorage else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for i in 0..<range.length {
            let index = characterIndexes[i]
            guard index < storage.length, storage.attribute(.prismHidden, at: index, effectiveRange: nil) != nil else { continue }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: range.length)) }
            changed![i] = .null
        }
        guard let changed else { return 0 }
        changed.withUnsafeBufferPointer { buffer in
            setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: characterIndexes, font: font, forGlyphRange: range)
        }
        return range.length
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0, let container = textContainers.first else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let text = storage.string as NSString
        let covered = text.paragraphRange(for: characters)
        let paragraphs = OutlineText.paragraphs(text)
        // Pills behind links.
        storage.enumerateAttribute(.prismPill, in: covered) { value, range, _ in
            guard value != nil else { return }
            // Behind what shows of it, a pill a line: hidden brackets have no place.
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
                    let rect = CGRect(x: start, y: used.minY, width: end - start, height: used.height)
                    let pill = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: 1)
                    Ink.pill.setFill()
                    UIBezierPath(roundedRect: pill, cornerRadius: 5).fill()
                }
            }
        }
        for (index, paragraph) in paragraphs.enumerated() where NSIntersectionRange(paragraph, covered).length > 0 || paragraph.location == covered.location {
            let row = OutlineText.style(storage, at: paragraph.location).row
            // The row's first glyph shown: hidden markup has no place of its own.
            var first = paragraph.location
            while first < NSMaxRange(paragraph) - 1, storage.attribute(.prismHidden, at: first, effectiveRange: nil) != nil { first += 1 }
            let glyph = glyphIndexForCharacter(at: first)
            guard glyph < numberOfGlyphs else { continue }
            let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
            let font = storage.attribute(.font, at: paragraph.location, effectiveRange: nil) as? UIFont ?? metrics.body
            let markerX = metrics.indent * CGFloat(row.depth) + metrics.indent / 2 + origin.x
            let glyphLocation = location(forGlyphAt: glyph)
            let baseline = line.minY + glyphLocation.y
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
                    if row.isFolded || hasChildren(index) && row.isFolded {
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
        outlineLayout.allowsNonContiguousLayout = false
        super.init(frame: .zero, textContainer: container)
        delegate = self
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        tintColor = Ink.accent
        autocorrectionType = .default
        smartDashesType = .no
        smartQuotesType = .no
        keyboardDismissMode = .interactive
        outlineLayout.hasChildren = { [weak self] index in
            guard let self else { return false }
            return OutlineEditing.hasChildren(rows, index)
        }
        markerTap.addTarget(self, action: #selector(tapped(_:)))
        markerTap.delegate = self
        addGestureRecognizer(markerTap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            addGestureRecognizer(swipe)
        }
        inputAccessoryView = OutlineToolbar(editor: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Rows

    func load(_ rows: [Row]) {
        adjusting = true
        let text = OutlineText.attributed(rows.isEmpty ? [.blank] : rows)
        textStorage.setAttributedString(text)
        styler.styleAll(textStorage)
        adjusting = false
        undoManager?.removeAllActions()
        heightMayHaveChanged()
    }

    var rows: [Row] { OutlineText.rows(textStorage) }

    var paragraphRanges: [NSRange] { OutlineText.paragraphs(textStorage.string as NSString) }

    func rowIndex(at location: Int) -> Int {
        let ranges = paragraphRanges
        return ranges.firstIndex { NSLocationInRange(location, $0) } ?? max(0, ranges.count - 1)
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
        let height = rowsHeight(width: bounds.width > 0 ? bounds.width : 320)
        if abs(height - lastHeight) > 0.5 {
            lastHeight = height
            invalidateIntrinsicContentSize()
            onHeightChange?()
        }
    }

    // MARK: Typing

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        guard !adjusting else { return true }
        let rows = rows
        let ranges = paragraphRanges
        let index = rowIndex(at: range.location)
        guard ranges.indices.contains(index) else { return true }
        let paragraph = ranges[index]
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
        if text.isEmpty, range.length == 1, selectedRange.length == 0 {
            let row = rowIndex(at: selectedRange.location)
            if ranges.indices.contains(row), selectedRange.location == ranges[row].location {
                if let plain = OutlineKeys.plain(rows, at: row) {
                    replace(plain, caret: OutlineKeys.Caret(row: row, offset: 0), undoName: "Change Row Type")
                    return false
                }
                if row == 0 { return false }
            }
        }
        // A space after Markdown typed at a row's start: the row's type.
        if text == " ", range.length == 0 {
            let prefix = (textStorage.string as NSString).substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
            if !prefix.isEmpty, let typed = OutlineKeys.smartType(rows, at: index, typed: prefix) {
                replace(typed, caret: OutlineKeys.Caret(row: index, offset: 0), undoName: "Change Row Type")
                return false
            }
        }
        // Lines within a row, as pasted, are not rows.
        if text.contains("\n"), text != "\n" {
            insertText(text.replacingOccurrences(of: "\n", with: OutlineText.lineSeparator))
            return false
        }
        // What is typed is of the row it is typed in: an empty row's style
        // is its line break's, not the one before it.
        typingAttributes = textStorage.attributes(at: NSMaxRange(paragraph) - 1, effectiveRange: nil)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        tidy()
        changed()
    }

    /// Where the caret is, in the editor.
    var caretRect: CGRect? {
        guard isFirstResponder, let end = selectedTextRange?.end else { return nil }
        return caretRect(for: end)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        onCaretMove?()
        // The span the caret is in shows its marks; the one it left, not.
        let old = styler.caret
        styler.caret = selectedRange.length == 0 ? selectedRange.location : nil
        guard old != styler.caret else { return }
        if let old { styler.restyle(textStorage, around: min(old, max(0, textStorage.length - 1))) }
        if let new = styler.caret { styler.restyle(textStorage, around: min(new, max(0, textStorage.length - 1))) }
    }

    func textViewDidBeginEditing(_ textView: UITextView) { onFocusChange?(true) }
    func textViewDidEndEditing(_ textView: UITextView) { onFocusChange?(false) }

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
    @objc func moveUp() { perform("Move Up") { OutlineEditing.moveUp(&$0, $1) } }
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

    @objc func foldHere() { toggleFold(at: caret.row) }

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
        case nil:
            break
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
    func rowsHeight(width: CGFloat) -> CGFloat {
        let fit = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let extra = outlineLayout.extraLineFragmentRect.height
        return max(0, fit - (extra > 0 ? extra : round(metrics.face.lineHeight * metrics.size)))
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
            ("chevron.down.circle", #selector(OutlineEditor.foldHere), "Fold"),
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
