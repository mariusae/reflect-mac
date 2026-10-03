import AppKit
import ReflectCore

/// Pictures dragged about: onto a row's text, where they go in among it, or
/// between rows — or into the space before a row's text — where they get a
/// row of their own. A line shows where such a row would go.
///
/// Within the app a picture moves, from one note to another too; dragged
/// out, it is its file, or its Markdown.
extension OutlineTextView {
    package static let pictureType = NSPasteboard.PasteboardType("com.mariusae.reflect.picture")

    /// A picture being dragged from this view: its Markdown, and where that is.
    package struct DraggedPicture {
        package var markdown: String
        package var range: NSRange
    }

    /// Where a dropped picture goes.
    package enum PictureDrop: Equatable {
        /// Into a row's text, at a place in the text view's text.
        case text(Int)
        /// A row of its own, at an index among the rows, at a depth.
        case row(index: Int, depth: Int)
        /// Straight after a picture, at a place in the text view's text:
        /// in a carousel with it.
        case join(Int)
    }

    // MARK: Dragging from

    /// Starts dragging a picture, from the mouse-down that picked it up.
    package func beginDragging(_ picture: ImageBox, frame: NSRect, event: NSEvent) {
        guard let location = rangeOfPicture(picture)?.location else { return }
        let spans = spans(atRowOf: location)
        guard var span = spans.first(where: { span in
                  guard span.range.location == location else { return false }
                  if case .url = span.kind { return true }
                  return span.isImage
              }) else { return }
        var picture = picture
        // From a carousel, the picture it shows.
        if let members = picture.carousel {
            let pictures = spans.filter { $0.isImage && $0.range.location >= location }
            let index = carouselIndex(picture)
            guard index < pictures.count, index < members.count else { return }
            span = pictures[index]
            picture = ImageBox(source: members[index], size: frame.size)
        }
        let markdown = (textStorage!.string as NSString).substring(with: span.range)
        draggedPicture = DraggedPicture(markdown: markdown, range: span.range)

        let item = NSPasteboardItem()
        item.setString(markdown, forType: Self.pictureType)
        if let file = images?.graphFile(picture.source) {
            item.setString(file.absoluteString, forType: .fileURL)
        } else {
            item.setString(picture.source, forType: .string)
        }
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(frame, contents: snapshot(of: picture, size: frame.size))
        LinkCard.shared.hide()
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    private func snapshot(of picture: ImageBox, size: NSSize) -> NSImage {
        let images = images
        return NSImage(size: size, flipped: true) { rect in
            guard let images else { return false }
            NSGraphicsContext.current?.cgContext.setAlpha(0.8)
            if let tweet = images.tweet(picture.source) {
                TweetCard.draw(tweet, in: rect, images: images)
            } else if let video = images.video(picture.source) {
                VideoCard.draw(video, in: rect, images: images)
            } else if let image = images.image(picture.source), image.size.width > 0, image.size.height > 0 {
                let scale = min(rect.width / image.size.width, rect.height / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    package override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard draggedPicture != nil || draggedRows != nil else { return super.draggingSession(session, sourceOperationMaskFor: context) }
        return context == .withinApplication ? .move : .copy
    }

    package override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if draggedPicture != nil || draggedRows != nil {
            draggedPicture = nil
            draggedRows = nil
            return
        }
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }

    // MARK: Dropping on

    package func carriesPicture(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.types?.contains(Self.pictureType) ?? false
    }

    /// Follows a picture dragged over the view: a line where it would get
    /// a row, or the text view's own caret where it would go in the text.
    package func pictureDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        let drop = pictureDrop(at: point, joining: Self.isPictureMarkdown(sender))
        dropRing.isHidden = true
        switch drop {
        case .text:
            dropLine.isHidden = true
            _ = super.draggingUpdated(sender)
        case .row(let index, let depth):
            super.draggingExited(sender)
            showDropLine(index: index, depth: depth)
        case .join:
            super.draggingExited(sender)
            dropLine.isHidden = true
            if let frame = outlineLayout.pictureFrame(at: point, origin: textContainerOrigin)?.frame {
                if dropRing.superview !== self { addSubview(dropRing) }
                dropRing.frame = frame.insetBy(dx: -3, dy: -3)
                dropRing.isHidden = false
            }
        }
        return sender.draggingSource is OutlineTextView ? .move : .copy
    }

    package func pictureDragEnded() {
        dropLine.isHidden = true
        dropRing.isHidden = true
    }

    /// Whether what is dragged is a picture's Markdown, which can join a carousel.
    package static func isPictureMarkdown(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.string(forType: pictureType)?.hasPrefix("![") ?? false
    }

    /// Puts a dropped picture in place, taking it from where it was when it
    /// came from a note.
    package func dropPicture(_ sender: NSDraggingInfo) -> Bool {
        dropLine.isHidden = true
        dropRing.isHidden = true
        guard isEditable, let markdown = sender.draggingPasteboard.string(forType: Self.pictureType) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let source = (sender.draggingSource as? OutlineTextView).flatMap { view in
            view.draggedPicture.map { (view, $0.range) }
        }
        movePicture(markdown, from: source, to: pictureDrop(at: point, joining: Self.isPictureMarkdown(sender)))
        return true
    }

    /// Moves a picture's Markdown to a place — from a place in this view or
    /// another, or from nowhere, for a copy.
    package func movePicture(_ markdown: String, from source: (view: OutlineTextView, range: NSRange)?, to drop: PictureDrop) {
        window?.makeFirstResponder(self)
        if selectedRows != nil { leaveRowSelection() }
        let before = rows
        var after = before
        let ranges = paragraphRanges
        // Where in the text it goes, as a row and a place in its text.
        var textTarget: (row: Int, offset: Int)?
        if case .text(let location) = drop {
            let index = rowIndex(at: location)
            textTarget = (index, snapped(min(location - ranges[index].location, (after[index].text as NSString).length), inRow: index))
        }
        if case .join(let location) = drop {
            // Exactly where it is asked for: straight after the picture.
            let index = rowIndex(at: location)
            textTarget = (index, min(location - ranges[index].location, (after[index].text as NSString).length))
        }
        var removed: (row: Int, gone: Bool)?

        if let source, source.view === self {
            let index = rowIndex(at: source.range.location)
            let offset = source.range.location - ranges[index].location
            if let target = textTarget, target.row == index, target.offset >= offset, target.offset <= offset + source.range.length {
                // Dropped where it already is: nothing to do.
                return
            }
            let cut = Self.cut(&after[index], at: offset, length: source.range.length)
            if let target = textTarget, target.row == index, target.offset > cut.location {
                textTarget?.offset = max(cut.location, target.offset - cut.length)
            }
            removed = (index, after[index].text.isEmpty && after[index].folded.isEmpty
                && !(index + 1 < after.count && after[index + 1].depth > after[index].depth))
        } else if let source {
            source.view.removePicture(at: source.range)
        }

        var caret: CaretPosition
        switch drop {
        case .join:
            guard let (index, offset) = textTarget else { return }
            let text = after[index].text as NSString
            after[index].text = text.replacingCharacters(in: NSRange(location: offset, length: 0), with: markdown)
            caret = CaretPosition(row: index, offset: offset + (markdown as NSString).length)
            if let (row, gone) = removed, gone, row != index {
                after.remove(at: row)
                if caret.row > row { caret.row -= 1 }
            }
        case .text:
            guard let (index, offset) = textTarget else { return }
            let text = after[index].text as NSString
            let spaceBefore = offset > 0 && !Self.isSpace(text.character(at: offset - 1))
            let spaceAfter = offset < text.length && !Self.isSpace(text.character(at: offset))
            let inserted = (spaceBefore ? " " : "") + markdown + (spaceAfter ? " " : "")
            after[index].text = text.replacingCharacters(in: NSRange(location: offset, length: 0), with: inserted)
            caret = CaretPosition(row: index, offset: offset + (inserted as NSString).length)
            if let (row, gone) = removed, gone, row != index {
                after.remove(at: row)
                if caret.row > row { caret.row -= 1 }
            }
        case .row(var index, let depth):
            after.insert(Row(kind: .bullet, depth: depth, text: markdown), at: index)
            if let (row, gone) = removed, gone {
                let at = row >= index ? row + 1 : row
                after.remove(at: at)
                if at < index { index -= 1 }
            }
            caret = CaretPosition(row: index, offset: (markdown as NSString).length)
        }
        place(&after, caret: caret, before: before)
    }

    private func place(_ after: inout [Row], caret: CaretPosition, before: [Row]) {
        OutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Move Picture")
        restoreCaret(caret)
        scrollRangeToVisible(selectedRange())
    }

    /// Takes a picture's Markdown out of this view's text, and its row with
    /// it when nothing else is left there.
    package func removePicture(at range: NSRange) {
        guard NSMaxRange(range) <= textStorage!.length else { return }
        let before = rows
        var after = before
        let index = rowIndex(at: range.location)
        _ = Self.cut(&after[index], at: range.location - paragraphRanges[index].location, length: range.length)
        if after[index].text.isEmpty, after[index].folded.isEmpty, after.count > 1,
           !(index + 1 < after.count && after[index + 1].depth > after[index].depth) {
            after.remove(at: index)
        }
        OutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Move Picture")
    }

    /// The nearest place to put something dropped, in the text view's
    /// text: not inside a word, nor inside a link or other Markdown.
    package func snappedLocation(_ location: Int) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return location }
        let index = rowIndex(at: min(location, storage.length - 1))
        let start = paragraphRanges[index].location
        let offset = min(max(location - start, 0), (rows[index].text as NSString).length)
        return start + snapped(offset, inRow: index)
    }

    /// The nearest place to put a picture in a row's text: not inside a
    /// word, nor inside a link or other Markdown.
    private func snapped(_ offset: Int, inRow index: Int) -> Int {
        let text = rows[index].text as NSString
        var offset = offset
        let isSpace = { (at: Int) in Self.isSpace(text.character(at: at)) }
        if offset > 0, offset < text.length, !isSpace(offset - 1), !isSpace(offset) {
            var back = offset, ahead = offset
            while back > 0, !isSpace(back - 1) { back -= 1 }
            while ahead < text.length, !isSpace(ahead) { ahead += 1 }
            offset = offset - back <= ahead - offset ? back : ahead
        }
        let start = paragraphRanges[index].location
        for span in spans(atRowOf: start) {
            let lower = span.range.location - start, upper = NSMaxRange(span.range) - start
            if offset > lower, offset < upper { offset = offset - lower <= upper - offset ? lower : upper }
        }
        return offset
    }

    /// Cuts some of a row's text, and a space beside it that would be left
    /// doubled or hanging; says what went, in the row's text as it was.
    package static func cut(_ row: inout Row, at offset: Int, length: Int) -> (location: Int, length: Int) {
        let text = row.text as NSString
        var range = NSRange(location: offset, length: length)
        let spaceAfter = NSMaxRange(range) < text.length && isSpace(text.character(at: NSMaxRange(range)))
        let spaceBefore = range.location > 0 && isSpace(text.character(at: range.location - 1))
        if spaceAfter && (spaceBefore || range.location == 0) {
            range.length += 1
        } else if spaceBefore && (spaceAfter || NSMaxRange(range) == text.length) {
            range.location -= 1
            range.length += 1
        }
        row.text = text.replacingCharacters(in: range, with: "")
        return (range.location, range.length)
    }

    private static func isSpace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09 || character == 0x0A
    }

    // MARK: Where it goes

    /// Where a picture dropped at a point goes: in among the text under it,
    /// or — dropped between rows, before a row's text, or on a row's
    /// pictures — in a row of its own, there.
    package func pictureDrop(at point: NSPoint, joining: Bool = false) -> PictureDrop {
        // Onto a picture: into a carousel with it.
        if joining, let target = joinTarget(at: point) { return .join(target) }
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else {
            return .row(index: 0, depth: 0)
        }
        let ranges = paragraphRanges
        let rows = rows
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = min(layout.glyphIndex(for: inContainer, in: container), max(layout.numberOfGlyphs - 1, 0))
        let index = rowIndex(at: layout.characterIndexForGlyph(at: glyph))
        let rect = rowRect(ranges[index])
        let row = rows[index]

        func between(below: Bool) -> PictureDrop {
            guard below else { return .row(index: index, depth: row.depth) }
            if index + 1 < rows.count, rows[index + 1].depth > row.depth {
                return .row(index: index + 1, depth: row.depth + 1)
            }
            return .row(index: index + 1, depth: row.depth)
        }

        if inContainer.y < rect.minY + 4 { return between(below: false) }
        if inContainer.y > rect.maxY - 4 { return between(below: true) }
        if inContainer.x < metrics.textIndent(for: row) - 4 { return between(below: inContainer.y > rect.midY) }
        // On a line's pictures, rather than its text.
        var lineGlyphs = NSRange()
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let characters = layout.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        let indent = metrics.textIndent(for: row)
        let pictures = ImageLine.frames(in: storage, characters: characters, container: container, fragment: fragment, indent: indent)
        if let top = pictures.first?.frame.minY, inContainer.y >= top - ImageBox.margin {
            return between(below: inContainer.y > (top + fragment.maxY) / 2)
        }
        return .text(characterIndexForInsertion(at: point))
    }

    /// Where a picture dropped onto one at a point is written: straight
    /// after it — after the last of its carousel, when it is in one. Nil off
    /// a picture, or on a card or a PDF, which carousels do not take.
    private func joinTarget(at point: NSPoint) -> Int? {
        guard let (box, _) = outlineLayout.pictureFrame(at: point, origin: textContainerOrigin), !box.isPDF,
              let images, box.carousel != nil || Carousel.isPicture(box.source, images: images),
              let location = rangeOfPicture(box)?.location else { return nil }
        let pictures = spans(atRowOf: location).filter { $0.isImage && $0.range.location >= location }
        let count = box.carousel?.count ?? 1
        guard count <= pictures.count else { return nil }
        return NSMaxRange(pictures[count - 1].range)
    }

    /// A row's rectangle in the text container: all its lines, pictures and all.
    private func rowRect(_ paragraph: NSRange) -> NSRect {
        guard let layout = layoutManager else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var rect = NSRect.null
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            rect = rect.union(fragment)
        }
        return rect.isNull ? .zero : rect
    }

    /// The line showing where a picture would get a row.
    package func showDropLine(index: Int, depth: Int) {
        let ranges = paragraphRanges
        let y: CGFloat
        if index < ranges.count {
            y = rowRect(ranges[index]).minY
        } else {
            y = rowRect(ranges[ranges.count - 1]).maxY
        }
        let x = textContainerOrigin.x + metrics.indent * CGFloat(depth + 1) - metrics.indent * 0.5
        let width = max(40, textContainerOrigin.x + (textContainer?.size.width ?? bounds.width) - x)
        if dropLine.superview !== self { addSubview(dropLine) }
        dropLine.frame = NSRect(x: x, y: textContainerOrigin.y + y - 1.5, width: width, height: 3)
        dropLine.isHidden = false
    }
}

/// Round a picture another dragged onto it would join.
package final class DropRingView: NSView {
    package override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 3
        isHidden = true
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func updateLayer() {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }

    package override var wantsUpdateLayer: Bool { true }

    package override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The line a picture's new row would go at.
package final class DropLineView: NSView {
    package override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 1.5
        isHidden = true
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }

    package override var wantsUpdateLayer: Bool { true }

    package override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
