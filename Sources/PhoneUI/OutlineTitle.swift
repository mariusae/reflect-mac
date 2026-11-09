#if os(iOS)
import PrismCore
import ReflectCore
import UIKit

/// An untitled note's first row, made its title: by Title — quiet, at the
/// end of that row once it is written and the caret has gone on below it —
/// or by Return after a first row typed as a heading.
extension OutlineEditor {
    private var titleChip: UIButton {
        if let madeTitleChip { return madeTitleChip }
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        configuration.imagePadding = 3
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        var title = AttributedString("Title")
        title.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        configuration.attributedTitle = title
        configuration.baseForegroundColor = Ink.faint
        let chip = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.titleByFirstRow() })
        chip.accessibilityLabel = "Make the first line the title"
        chip.isHidden = true
        chip.sizeToFit()
        addSubview(chip)
        madeTitleChip = chip
        return chip
    }

    /// The first row's words: its paragraph, but its line break.
    private var firstRowWords: NSRange? {
        let text = textStorage.string as NSString
        guard text.length > 0 else { return nil }
        var words = text.paragraphRange(for: NSRange(location: 0, length: 0))
        while words.length > 0, [10, 13].contains(text.character(at: NSMaxRange(words) - 1)) { words.length -= 1 }
        return words
    }

    /// Title at the end of the first row: while the caret is below it, in
    /// a note that has no title and is offered one — or, titled by
    /// heading, whenever that row is a heading.
    func placeTitleChip() {
        guard offersTitleChip, isFirstResponder, isUntitled(), let words = firstRowWords, words.length > 0,
              case let text = textStorage.string as NSString,
              !Untitled.title(from: text.substring(with: words)).isEmpty,
              firstRowIsTitleHeading(words: words, in: text)
                || (NSMaxRange(words) < text.length && selectedRange.location > NSMaxRange(words) && offersTitle()) else {
            if madeTitleChip?.isHidden == false { madeTitleChip?.isHidden = true }
            return
        }
        let glyphs = outlineLayout.glyphRange(forCharacterRange: words, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let last = NSMaxRange(glyphs) - 1
        let used = outlineLayout.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let end = outlineLayout.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: textContainer)
        let chip = titleChip
        let size = chip.intrinsicContentSize
        let inset = textContainerInset
        var x = end.maxX + inset.left + 2
        if x + size.width > bounds.width { x = max(0, bounds.width - size.width) }
        let frame = CGRect(x: x.rounded(), y: (used.midY + inset.top - size.height / 2).rounded(), width: size.width, height: size.height)
        if chip.frame != frame { chip.frame = frame }
        if chip.isHidden {
            chip.alpha = 0
            chip.isHidden = false
            UIView.animate(withDuration: 0.2) { chip.alpha = 1 }
        }
    }

    /// Return at the end of the first row, written as a heading, of an
    /// untitled note: that row made the title, whenever it is made one.
    func titleByHeading(at location: Int) -> Bool {
        guard offersTitleChip, isUntitled(), let words = firstRowWords, location == NSMaxRange(words),
              firstRowIsTitleHeading(words: words, in: textStorage.string as NSString) else { return false }
        return titleByFirstRow()
    }

    /// Whether the first row is a top heading the note is titled by.
    private func firstRowIsTitleHeading(words: NSRange, in text: NSString) -> Bool {
        // Its kind, or — what was typed may not be in its rows yet — its words.
        titlesByHeading && (rows.first.map(Self.isTitleHeading) == true
            || Self.isTitleHeading(Row(kind: .bullet, text: text.substring(with: words))))
    }

    /// A row written as a top heading: made one, or `# ` typed at its start.
    static func isTitleHeading(_ row: Row) -> Bool {
        if case .heading(1) = row.kind { return true }
        return row.text.hasPrefix("# ") && row.text.dropFirst(2).contains { !$0.isWhitespace }
    }

    /// The first row made the title — its words, as a title — and taken
    /// out, with the blank rows after it; the caret where it was in what is
    /// left, else at the start. False, when the note has a title, or its
    /// first row no words.
    @discardableResult
    public func titleByFirstRow() -> Bool {
        let all = rows
        guard isUntitled(), let first = all.first else { return false }
        let title = Untitled.title(from: first.text)
        guard !title.isEmpty else { return false }
        var taken = 1
        while taken < all.count, all[taken].task == nil, all[taken].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              all[taken].kind == .bullet || all[taken].kind == .paragraph {
            taken += 1
        }
        let before = caret
        var after = Array(all.dropFirst(taken))
        // The only row: emptied, not taken — there is always a row.
        if after.isEmpty { after = [Row.blank] }
        let caret = before.row >= taken ? OutlineKeys.Caret(row: before.row - taken, offset: before.offset) : OutlineKeys.Caret(row: 0, offset: 0)
        madeTitleChip?.isHidden = true
        replace(after, caret: caret, undoName: "Title")
        onTitle?(title)
        return true
    }
}
#endif
