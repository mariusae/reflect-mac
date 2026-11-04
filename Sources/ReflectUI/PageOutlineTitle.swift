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
        chip.sizeToFit()
        editor.addSubview(chip)
        return chip
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
    /// untitled page's, with words to be titled by.
    func placeTitleChip() {
        guard let text = editor.textStorage?.string as NSString?, window?.firstResponder === editor, isUntitled(),
              let row = firstRow, case let words = words(of: row, in: text), words.length > 0,
              case let caret = editor.selectedRange(), caret.location >= row.location, NSMaxRange(caret) <= NSMaxRange(words),
              !Untitled.title(from: text.substring(with: words)).isEmpty,
              let layout = editor.layoutManager, let container = editor.textContainer else {
            if !titleChip.isHidden { titleChip.isHidden = true }
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

    /// The first row made the title — its words, as a title — and taken
    /// out, with the blank rows after it; the caret at the start. False,
    /// when the page has a title, or its first row no words.
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
        onTitle?(title)
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(taken)
        editor.insertText("", replacementRange: taken)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        titleChip.isHidden = true
        return true
    }
}
