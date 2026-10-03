import AppKit
import ReflectCore

/// Showing where a search found a note: the words it found, or the picture
/// whose text had them — opening folds they are hidden in, selecting them,
/// scrolling to them, and pointing them out.
extension OutlineTextView {
    /// What a search found in a note.
    package enum Found: Equatable {
        /// Words in its text, best first: the whole phrase is tried, then
        /// each word.
        case words([String])
        /// A picture it shows, by its path in the graph, and the words
        /// found in it.
        case picture(String, words: [String])
    }

    /// Shows what a search found, if it is still there; says whether it was.
    @discardableResult
    package func reveal(_ found: Found) -> Bool {
        if selectedRows != nil { leaveRowSelection() }
        // What was found may be anywhere in the note: all of it, to find it in.
        if focus != nil { unfocus(nil) }
        switch found {
        case .words(let words):
            let words = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !words.isEmpty else { return false }
            let candidates = (words.count > 1 ? [words.joined(separator: " ")] : []) + words
            guard let range = unfoldingToFind({ self.range(ofAny: candidates) }, matching: candidates) else { return false }
            setSelectedRange(range)
            if let layout = layoutManager, let container = textContainer {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                center(layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            }
            // Laid out and scrolled to first, then pointed out.
            DispatchQueue.main.async { [weak self] in self?.showFindIndicator(for: range) }
            return true
        case .picture(let path, let words):
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let references = ["](\(path)", "](\(encoded)", "(<\(path)>)"]
            guard let reference = unfoldingToFind({ self.range(ofAny: references, literally: true) }, matching: [path, encoded]),
                  let location = pictureLocation(near: reference.location) else { return false }
            setSelectedRange(NSRange(location: location, length: 0))
            guard let layout = layoutManager, location < textStorage!.length else { return true }
            let glyph = layout.glyphIndexForCharacter(at: location)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            center(line)
            DispatchQueue.main.async { [weak self] in self?.pointOutPicture(at: location, words: words) }
            return true
        }
    }

    /// Scrolls a rectangle of this view to the middle of the window, or
    /// as near as the scroller goes; one taller than the window, to its top.
    private func center(_ rect: NSRect) {
        guard let scrollView = enclosingScrollView, let document = scrollView.documentView else {
            _ = scrollToVisible(rect)
            return
        }
        let clip = scrollView.contentView
        let target = convert(rect, to: document)
        let visible = clip.bounds.height - scrollView.contentInsets.top
        var y = target.height > visible * 0.8 ? target.minY - 24 : target.midY - visible / 2
        y -= scrollView.contentInsets.top
        y = min(max(y, -scrollView.contentInsets.top), max(document.frame.height - clip.bounds.height, -scrollView.contentInsets.top))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The first of some strings in the text, as written or regardless of
    /// case and accents.
    private func range(ofAny candidates: [String], literally: Bool = false) -> NSRange? {
        let text = textStorage!.string as NSString
        let options: NSString.CompareOptions = literally ? [] : [.caseInsensitive, .diacriticInsensitive]
        for candidate in candidates {
            let range = text.range(of: candidate, options: options)
            if range.location != NSNotFound { return range }
        }
        return nil
    }

    /// Finds something in the text; when it is not there, opens the fold
    /// that hides it, a level at a time, and looks again.
    private func unfoldingToFind(_ find: () -> NSRange?, matching needles: [String]) -> NSRange? {
        let folded = needles.map(NoteIndex.foldKey)
        for _ in 0..<32 {
            if let range = find() { return range }
            let rows = rows
            guard let index = rows.indices.first(where: { index in
                guard rows[index].isFolded else { return false }
                return Row.unfold(rows[index].folded).contains { row in
                    let text = NoteIndex.foldKey(row.text)
                    return folded.contains { text.contains($0) }
                }
            }) else { return nil }
            perform("Expand", on: index..<(index + 1)) { rows, selection in
                OutlineEditing.unfold(&rows, at: selection.lowerBound)
                return selection
            }
        }
        return nil
    }

    /// Where the picture a reference belongs to is drawn from: the start of
    /// its `![…](…)`.
    private func pictureLocation(near reference: Int) -> Int? {
        var found: Int?
        let row = paragraphRanges[rowIndex(at: reference)]
        textStorage!.enumerateAttribute(.outlineImage, in: row) { value, range, stop in
            guard value != nil else { return }
            if range.location > reference {
                stop.pointee = true
            } else {
                found = range.location
            }
        }
        return found
    }

    /// A ring around a picture, that fades.
    private func pointOutPicture(at location: Int, words: [String]) {
        guard let storage = textStorage, location < storage.length,
              let box = storage.attribute(.outlineImage, at: location, effectiveRange: nil) as? ImageBox,
              let layout = layoutManager, let container = textContainer else { return }
        let glyph = layout.glyphIndexForCharacter(at: location)
        var lineGlyphs = NSRange()
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let characters = layout.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let indent = (storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
        guard let frame = ImageLine.frames(in: storage, characters: characters, container: container, fragment: fragment, indent: indent)
            .first(where: { $0.box === box })?.frame else { return }
        let picture = frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        let ring = RingView(frame: picture.insetBy(dx: -5, dy: -5))
        addSubview(ring)
        ring.flash()
        // And the words in it, where Vision sees them.
        guard !words.isEmpty, let file = images?.graphFile(box.source) else { return }
        Task.detached(priority: .userInitiated) {
            let boxes = ImageTextReader.boxes(of: words, in: file)
            await MainActor.run { [weak self] in
                guard let self else { return }
                for found in boxes {
                    // Vision's boxes are from the picture's lower left, as fractions of it.
                    let rect = NSRect(x: picture.minX + found.minX * picture.width,
                                      y: picture.minY + (1 - found.maxY) * picture.height,
                                      width: found.width * picture.width, height: found.height * picture.height)
                    let mark = MarkView(frame: rect.insetBy(dx: -2, dy: -2))
                    self.addSubview(mark)
                    mark.flash(for: 3)
                }
            }
        }
    }
}

/// A word found in a picture, marked in the find colour for a while.
private final class MarkView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor.findHighlightColor.withAlphaComponent(0.45).cgColor
        layer?.borderColor = NSColor.findHighlightColor.cgColor
        layer?.borderWidth = 1.5
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash(for seconds: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.8
                animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { self.removeFromSuperview() }
            })
        }
    }
}

/// A rounded ring in the find colour, that shows for a moment.
private final class RingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 4
        layer?.borderColor = NSColor.findHighlightColor.cgColor
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Comes up, stays a moment, and fades away.
    func flash() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.6
                animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { self.removeFromSuperview() }
            })
        }
    }
}
