import AppKit
import ReflectCore

/// An untitled page's first row, made its title: by Title, at the end of
/// that row while the caret is on it, or the app's own command.
extension PageOutlineEditor {
    func makeTitleChip() -> NSButton {
        let chip = NSButton(title: "Title", target: self, action: #selector(titleChipClicked(_:)))
        chip.bezelStyle = .inline
        chip.controlSize = .small
        chip.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        chip.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chip.imagePosition = .imageLeading
        chip.imageHugsTitle = true
        chip.contentTintColor = .controlAccentColor
        chip.toolTip = "Make this line the title (⌃⌘T)"
        chip.setAccessibilityLabel("Make this line the title")
        chip.refusesFirstResponder = true
        chip.isHidden = true
        styleTitleChip(chip)
        editor.addSubview(chip)
        return chip
    }

    /// Quiet, grey and borderless — a word in the margin, not a button
    /// asking; else the accent's.
    func styleTitleChip(_ chip: NSButton) {
        chip.isBordered = !quietTitleChip
        let color: NSColor = quietTitleChip ? .tertiaryLabelColor : .controlAccentColor
        chip.contentTintColor = color
        chip.attributedTitle = NSAttributedString(string: "Title", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: quietTitleChip ? .medium : .semibold),
            .foregroundColor: color,
        ])
        chip.sizeToFit()
    }

    @objc private func titleChipClicked(_ sender: Any?) {
        titleByFirstRow()
        window?.makeFirstResponder(editor)
    }

    /// The menu's Title, sent along the responder chain: untitled, by its
    /// first row; else its title asked for.
    @objc public func titlePage(_ sender: Any?) {
        if !titleByFirstRow() { onAskTitle?() }
    }

    /// The first row, as a paragraph of the editor's text: its line break too.
    private var firstRow: NSRange? {
        guard let text = editor.textStorage?.string as NSString?, text.length > 0 else { return nil }
        return text.paragraphRange(for: NSRange(location: 0, length: 0))
    }

    private func words(of row: NSRange, in text: NSString) -> NSRange {
        var words = row
        while words.length > 0, [10, 13].contains(text.character(at: NSMaxRange(words) - 1)) { words.length -= 1 }
        return words
    }

    /// The chip at the end of the first row while the caret is on it: an
    /// untitled page's, with words to be titled by. Titled by heading, it
    /// is there whenever that row is a heading, wherever the caret is.
    func placeTitleChip() {
        guard offersTitleChip, let text = editor.textStorage?.string as NSString?, window?.firstResponder === editor, isUntitled(),
              let row = firstRow, case let words = words(of: row, in: text), words.length > 0,
              case let caret = editor.selectedRange(),
              firstRowIsTitleHeading(words: words, in: text)
                // Quiet: once the first row is written, the caret gone on below it.
                || (quietTitleChip ? caret.location >= NSMaxRange(row) && NSMaxRange(row) < text.length && offersTitle()
                                   : caret.location >= row.location && NSMaxRange(caret) <= NSMaxRange(words)),
              !Untitled.title(from: text.substring(with: words)).isEmpty,
              let layout = editor.layoutManager, let container = editor.textContainer else {
            if madeChip?.isHidden == false { madeChip?.isHidden = true }
            return
        }
        let glyphs = layout.glyphRange(forCharacterRange: words, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        layout.ensureLayout(forGlyphRange: glyphs)
        let last = NSMaxRange(glyphs) - 1
        let used = layout.lineFragmentUsedRect(forGlyphAt: last, effectiveRange: nil)
        let end = layout.boundingRect(forGlyphRange: NSRange(location: last, length: 1), in: container)
        let size = titleChip.fittingSize
        let origin = editor.textContainerOrigin
        var x = end.maxX + origin.x + 8
        if x + size.width > editor.bounds.width { x = max(0, editor.bounds.width - size.width) }
        let frame = NSRect(x: x.rounded(), y: (used.midY + origin.y - size.height / 2).rounded(), width: size.width, height: size.height)
        if titleChip.frame != frame { titleChip.frame = frame }
        if titleChip.isHidden { titleChip.isHidden = false }
    }

    /// Return at the end of the first row, written as a heading — `# ` —
    /// of an untitled page: that row made the title, whenever it is made one.
    func titleByHeading(at index: Int) -> Bool {
        guard index == 0, offersTitleChip, isUntitled(),
              let text = editor.textStorage?.string as NSString?, let row = firstRow, case let words = words(of: row, in: text),
              editor.selectedRange().location == NSMaxRange(words), firstRowIsTitleHeading(words: words, in: text)
        else { return false }
        return titleByFirstRow()
    }

    /// Whether the first row is a top heading the page is titled by.
    private func firstRowIsTitleHeading(words: NSRange, in text: NSString) -> Bool {
        // Its kind, or — what was typed may not be in its rows yet — its words.
        titlesByHeading && (Self.isTitleHeading(editor.row(at: 0)) || Self.isTitleHeading(Row(kind: .bullet, text: text.substring(with: words))))
    }

    /// A row written as a top heading: made one, or `# ` typed at its start.
    nonisolated static func isTitleHeading(_ row: Row) -> Bool {
        if case .heading(1) = row.kind { return true }
        return row.text.hasPrefix("# ") && row.text.dropFirst(2).contains { !$0.isWhitespace }
    }

    /// The first row made the title — its words, as a title — and taken
    /// out, with the blank rows after it; the caret where it was in what is
    /// left, else at the start. False, when the page has a title, or its
    /// first row no words.
    @discardableResult
    public func titleByFirstRow() -> Bool {
        guard isUntitled(), let text = editor.textStorage?.string as NSString?, let row = firstRow else { return false }
        let title = Untitled.title(from: text.substring(with: words(of: row, in: text)))
        guard !title.isEmpty else { return false }
        var end = NSMaxRange(row)
        while end < text.length {
            let next = text.paragraphRange(for: NSRange(location: end, length: 0))
            guard next.length > 0, text.substring(with: next).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            end = NSMaxRange(next)
        }
        // The only row: emptied, not taken — there is always a row.
        let taken = end >= text.length ? words(of: NSRange(location: 0, length: text.length), in: text) : NSRange(location: 0, length: end)
        let caret = editor.selectedRange()
        onTitle?(title)
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(taken)
        editor.insertText("", replacementRange: taken)
        // Writing on below it: on where it was.
        let after = caret.location >= NSMaxRange(taken) ? NSRange(location: caret.location - taken.length, length: caret.length) : NSRange(location: 0, length: 0)
        editor.setSelectedRange(NSMaxRange(after) <= (editor.textStorage?.length ?? 0) ? after : NSRange(location: 0, length: 0))
        madeChip?.isHidden = true
        return true
    }
}
