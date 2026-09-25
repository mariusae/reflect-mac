import AppKit
import ReflectCore

/// Told when the keyboard runs off an edge of an outline, and when a link in
/// it is followed.
@MainActor
protocol OutlineTextViewNavigator: AnyObject {
    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat)
    func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool)
}

/// An outline editor in the manner of Bike.
///
/// Each paragraph is a row. Text is edited as text, one row at a time; a
/// selection that reaches past one row selects rows, and Escape does the
/// same for the row the caret is in. With rows selected the arrow keys move
/// between rows, fold and unfold them, and space checks them off. A row
/// always takes its children along — when indented, outdented, moved or
/// deleted.
final class OutlineTextView: NSTextView {
    enum Edge { case top, bottom }

    weak var navigator: OutlineTextViewNavigator?
    let styler: OutlineStyler
    var metrics: OutlineMetrics {
        didSet {
            styler.metrics = metrics
            styler.styleAll(textStorage!)
        }
    }

    /// Whether the note is marked `private: true`: its links are then never
    /// looked up on the web.
    var isPrivateNote = false

    /// A `[[link` being typed, and the list that finishes it.
    private var linkCompletion: LinkCompletion?

    /// Where the note's pictures come from.
    var images: ImageStore? {
        didSet {
            styler.images = images
            styler.styleAll(textStorage!)
        }
    }
    /// Told when pictures arrive and the text's height may have changed.
    var onPicturesChanged: (() -> Void)?

    /// The rows selected as rows, when they are.
    private(set) var selectedRows: Range<Int>?
    private(set) var rowAnchor = 0
    private(set) var rowHead = 0
    /// The selections Expand Selection came from, and where it got to; a
    /// selection made any other way starts afresh.
    var expansions: [SelectionSnapshot] = []
    var expandedTo: SelectionSnapshot?
    /// Set while the editor changes its own text, so that what it does is
    /// not taken for the writer's.
    private var adjusting = false
    /// The picture being dragged from here, while it is.
    var draggedPicture: DraggedPicture?
    /// Where a dragged picture's new row would go.
    let dropLine = DropLineView()
    /// How selected text looks, set aside while rows are selected, which
    /// look like rows instead.
    private var textSelectionAttributes: [NSAttributedString.Key: Any] = [:]
    private let hiddenGlyphs = HiddenMarkupGlyphs()
    private let caret = CaretView()

    init(metrics: OutlineMetrics) {
        self.metrics = metrics
        styler = OutlineStyler(metrics: metrics)
        let storage = NSTextStorage()
        let layout = OutlineLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 40), textContainer: container)
        layout.outlineView = self
        layout.delegate = hiddenGlyphs
        storage.delegate = styler
        styler.onCharactersEdited = { [weak self] in self?.paragraphCache = nil }
        NotificationCenter.default.addObserver(self, selector: #selector(pictureArrived(_:)), name: ImageStore.didLoad, object: nil)
        addSubview(caret)
        // The caret is drawn here, not by the text system.
        insertionPointColor = .clear

        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = .zero
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isContinuousSpellCheckingEnabled = true
        displaysLinkToolTips = true
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
        textSelectionAttributes = selectedTextAttributes
        load([.blank])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var outlineLayout: OutlineLayoutManager { layoutManager as! OutlineLayoutManager }

    // MARK: Content

    /// Puts rows on screen, forgetting what was there and how it got there.
    func load(_ rows: [Row]) {
        adjusting = true
        textStorage!.setAttributedString(OutlineText.attributed(rows.isEmpty ? [.blank] : rows))
        adjusting = false
        paragraphCache = nil
        selectedRows = nil
        super.setSelectedRanges([NSValue(range: NSRange(location: 0, length: 0))], affinity: .downstream, stillSelecting: false)
        undoManager?.removeAllActions(withTarget: textStorage!)
        undoManager?.removeAllActions()
    }

    /// The rows as they stand, folded rows folded.
    var rows: [Row] { OutlineText.rows(textStorage!) }

    fileprivate var paragraphCache: [NSRange]?

    /// The range of each row's paragraph.
    var paragraphRanges: [NSRange] {
        if let paragraphCache { return paragraphCache }
        let ranges = OutlineText.paragraphs(textStorage!.string as NSString)
        paragraphCache = ranges
        return ranges
    }

    /// The row a character belongs to.
    func rowIndex(at location: Int) -> Int {
        let ranges = paragraphRanges
        var low = 0, high = ranges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].location <= location { low = middle } else { high = middle - 1 }
        }
        return max(0, low)
    }

    func row(at index: Int) -> Row {
        OutlineText.style(textStorage!, at: paragraphRanges[index].location).row
    }

    /// The last place a caret can be: before the last line break.
    private var lastLocation: Int { max(0, textStorage!.length - 1) }

    // MARK: Changing text

    override func didChangeText() {
        paragraphCache = nil
        if !adjusting { tidy() }
        super.didChangeText()
        updateCaret()
    }

    /// An edit that would take some of a span's markup, but not all of it,
    /// leaves that markup be, so the span's text keeps its style.
    override func shouldChangeText(inRanges ranges: [NSValue], replacementStrings strings: [String]?) -> Bool {
        guard !adjusting, ranges.count == 1, let replacement = strings?.first, let storage = textStorage else {
            return super.shouldChangeText(inRanges: ranges, replacementStrings: strings)
        }
        let range = ranges[0].rangeValue
        guard range.length > 0, NSMaxRange(range) <= storage.length else {
            return super.shouldChangeText(inRanges: ranges, replacementStrings: strings)
        }
        let text = storage.string as NSString
        let covering = text.paragraphRange(for: range)
        let spans = InlineMarkup.spans(in: text, range: covering)
        let pieces = InlineEditing.deletablePieces(of: range, spans: spans)
        guard pieces != [range] else { return super.shouldChangeText(inRanges: ranges, replacementStrings: strings) }
        var kept = ""
        var location = range.location
        for piece in pieces {
            kept += text.substring(with: NSRange(location: location, length: piece.location - location))
            location = NSMaxRange(piece)
        }
        kept += text.substring(with: NSRange(location: location, length: NSMaxRange(range) - location))
        adjusting = true
        let changed = super.shouldChangeText(inRanges: ranges, replacementStrings: [replacement + kept])
        if changed {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement + kept, attributes: typingAttributes))
            didChangeText()
        }
        adjusting = false
        if changed {
            setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
            tidy()
        }
        return false
    }

    /// Puts right what an edit can leave wrong: the text must end in a line
    /// break, rows swallowed by an edit come back, and every row must sit at
    /// a depth Markdown can write.
    private func tidy() {
        adjusting = true
        defer { adjusting = false }
        let storage = textStorage!
        if storage.length == 0 || !storage.string.hasSuffix("\n") {
            let style = storage.length > 0 ? OutlineText.style(storage, at: storage.length - 1) : RowStyle(.blank)
            let selection = selectedRange()
            if shouldChangeText(in: NSRange(location: storage.length, length: 0), replacementString: "\n") {
                storage.append(NSAttributedString(string: "\n", attributes: [.outlineRow: style]))
                didChangeText()
            }
            setSelectedRange(selection)
        }
        paragraphCache = nil
        let orphans = styler.orphans
        styler.orphans = []
        let before = rows
        var after = before
        for orphan in orphans.reversed() {
            let index = rowIndex(at: min(orphan.location, lastLocation))
            after.insert(contentsOf: orphan.rows, at: index + 1)
        }
        OutlineEditing.normalize(&after)
        if after != before {
            let caret = caretPosition
            replace(before, with: after, actionName: nil)
            restoreCaret(caret)
        }
    }

    /// Replaces the rows on screen, changing only the paragraphs that differ,
    /// as one step to undo.
    func replace(_ before: [Row], with after: [Row], actionName: String?) {
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < before.count - prefix, suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        let ranges = paragraphRanges
        let start = prefix < ranges.count ? ranges[prefix].location : textStorage!.length
        let end = before.count - suffix > prefix ? NSMaxRange(ranges[before.count - suffix - 1]) : start
        let range = NSRange(location: start, length: end - start)
        let replacement = OutlineText.attributed(Array(after[prefix..<(after.count - suffix)]))
        guard range.length > 0 || replacement.length > 0 else { return }
        let wasAdjusting = adjusting
        adjusting = true
        // A change to the outline is its own step to undo, not part of the
        // typing before it.
        breakUndoCoalescing()
        if shouldChangeText(in: range, replacementString: replacement.string) {
            textStorage!.replaceCharacters(in: range, with: replacement)
            didChangeText()
        }
        adjusting = wasAdjusting
        if let actionName { undoManager?.setActionName(actionName) }
    }

    /// Replaces one row's text and style.
    func replaceRow(_ index: Int, with row: Row, actionName: String?) {
        var after = rows
        let before = after
        after[index] = row
        replace(before, with: after, actionName: actionName)
    }

    // MARK: Where the caret is

    struct CaretPosition {
        var row: Int
        var offset: Int
    }

    var caretPosition: CaretPosition {
        let location = selectedRange().location
        let row = rowIndex(at: location)
        return CaretPosition(row: row, offset: location - paragraphRanges[row].location)
    }

    func restoreCaret(_ position: CaretPosition) {
        let ranges = paragraphRanges
        let row = min(max(position.row, 0), ranges.count - 1)
        let offset = min(position.offset, ranges[row].length - 1)
        setSelectedRange(NSRange(location: ranges[row].location + max(offset, 0), length: 0))
    }

    /// The rows a command applies to: those selected, or the caret's.
    var targetRows: Range<Int> {
        if let selectedRows { return selectedRows }
        let range = selectedRange()
        let first = rowIndex(at: range.location)
        let last = rowIndex(at: max(range.location, NSMaxRange(range) - 1))
        return first..<(last + 1)
    }

    // MARK: Selection

    /// Puts back a selection noted before: rows, or a range of text, kept
    /// inside the text as it now is.
    func restoreSelection(location: Int, length: Int, rows: [Int]?) {
        let count = paragraphRanges.count
        if let rows, rows.count == 2 {
            selectRows(anchor: min(rows[0], count - 1), head: min(rows[1], count - 1))
            return
        }
        let start = min(max(location, 0), lastLocation)
        setSelectedRange(NSRange(location: start, length: min(max(length, 0), lastLocation - start)))
    }

    /// A selection, of text or of rows.
    struct SelectionSnapshot: Equatable {
        var range: NSRange
        var rows: Range<Int>?
        var anchor: Int
        var head: Int
    }

    var selectionSnapshot: SelectionSnapshot {
        SelectionSnapshot(range: selectedRange(), rows: selectedRows, anchor: rowAnchor, head: rowHead)
    }

    func restore(_ snapshot: SelectionSnapshot) {
        if snapshot.rows != nil {
            selectRows(anchor: snapshot.anchor, head: snapshot.head)
        } else {
            if selectedRows != nil { leaveRowSelection() }
            setSelectedRange(snapshot.range)
        }
    }

    var isSelectingRows: Bool { selectedRows != nil }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard let storage = textStorage, storage.length > 0, let first = ranges.first?.rangeValue else {
            super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
            return
        }
        var range = ranges.map(\.rangeValue).reduce(first, NSUnionRange)
        let limit = lastLocation
        let end = min(NSMaxRange(range), limit)
        range.location = min(range.location, limit)
        range.length = max(0, end - range.location)
        if !adjusting {
            // The caret never rests within hidden markup.
            let old = selectedRange()
            let start = snap(range.location, forward: range.location > old.location)
            let finish = range.length == 0 ? start : snap(NSMaxRange(range), forward: NSMaxRange(range) > NSMaxRange(old))
            range = NSRange(location: start, length: max(0, finish - start))
        }

        let top = rowIndex(at: range.location)
        let bottom = rowIndex(at: max(range.location, NSMaxRange(range) - 1))
        if top != bottom && !adjusting {
            // Selecting past a row selects rows.
            let anchor = selectedRows == nil ? rowIndex(at: selectedRange().location) : rowAnchor
            let head = anchor == top ? bottom : top
            selectRows(anchor: anchor, head: head, stillSelecting: stillSelecting)
            return
        }
        if selectedRows != nil && !adjusting { leaveRowSelection() }
        super.setSelectedRanges([NSValue(range: range)], affinity: affinity, stillSelecting: stillSelecting)
        typingAttributes = storage.attributes(at: min(paragraphRanges[top].location, storage.length - 1), effectiveRange: nil)
            .filter { $0.key != .link && $0.key != .outlineHidden }
        updateCaret()
        updateLinkCompletion()
    }

    @objc private func pictureArrived(_ notification: Notification) {
        guard let source = notification.object as? String, textStorage!.string.contains(source) else { return }
        styler.styleAll(textStorage!)
        onPicturesChanged?()
    }

    // MARK: Hidden markup

    /// The text of the row a location is in, line break left out.
    private func textRange(ofRowAt location: Int) -> NSRange {
        let paragraph = paragraphRanges[rowIndex(at: location)]
        let length = textStorage!.length
        let start = min(paragraph.location, length)
        return NSRange(location: start, length: max(0, min(paragraph.length - 1, length - start)))
    }

    /// The inline spans of the row a location is in.
    func spans(atRowOf location: Int) -> [InlineSpan] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let row = row(at: rowIndex(at: location))
        if case .code = row.kind { return [] }
        let found = InlineMarkup.spans(in: storage.string as NSString, range: textRange(ofRowAt: location))
        return images?.resolve(found) ?? found.filter { !$0.isImage }
    }

    private func snap(_ location: Int, forward: Bool) -> Int {
        guard textStorage!.length > 0 else { return location }
        return InlineEditing.snap(location, runs: spans(atRowOf: location).flatMap(\.markup), forward: forward)
    }

    /// Puts the caret where the selection is: a bar from the ascender to
    /// the descender of the type it stands in, not the height of the line,
    /// and beside hidden markup, a tail to say which side of it it is on.
    func updateCaret() {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage,
              selectedRows == nil, selectedRange().length == 0, window?.firstResponder === self,
              window?.isKeyWindow == true || Self.scripted, storage.length > 0 else {
            caret.hide()
            return
        }
        let location = selectedRange().location
        var count = 0
        guard let rects = layout.rectArray(forCharacterRange: NSRange(location: location, length: 0),
                                           withinSelectedCharacterRange: NSRange(location: location, length: 0),
                                           in: container, rectCount: &count), count > 0 else {
            caret.hide()
            return
        }
        let x = rects[0].minX + textContainerOrigin.x
        let fragmentRect = rects[0].offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // The caret's line is the one its rectangle is on: at the end of a
        // line that wraps, that is the line it ends, not the next.
        let inContainer = NSPoint(x: fragmentRect.midX - textContainerOrigin.x, y: fragmentRect.midY - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inContainer, in: container)
        let font = caretFont(at: location)
        let baseline = textContainerOrigin.y + outlineLayout.baseline(ofLineAt: glyph, font: font)
        let bar = NSRect(x: (x - 1).rounded(), y: (baseline - font.ascender).rounded(),
                         width: 2, height: ceil(font.ascender - font.descender))
        var tail: NSRect?
        if let side = InlineEditing.tail(at: location, spans: spans(atRowOf: location)) {
            let length = max(4, (font.pointSize * 0.3).rounded())
            tail = NSRect(x: side == .right ? bar.maxX : bar.minX - length, y: bar.maxY - 2, width: length, height: 2)
        }
        caret.show(bar: bar, tail: tail)
    }

    /// A script drives an app that is not in front; its caret is shown all
    /// the same, to be looked at.
    private static let scripted = ProcessInfo.processInfo.environment["REFLECT_SCRIPT"] != nil

    /// The type the caret stands in: that of the character before it in its
    /// row, else the one after.
    private func caretFont(at location: Int) -> NSFont {
        let storage = textStorage!
        let paragraph = paragraphRanges[rowIndex(at: location)]
        var index = location - 1
        while index >= paragraph.location {
            if storage.attribute(.outlineHidden, at: index, effectiveRange: nil) == nil,
               let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
            index -= 1
        }
        return storage.attribute(.font, at: min(location, storage.length - 1), effectiveRange: nil) as? NSFont ?? metrics.body
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyChanged(_:)), name: name, object: window)
        }
    }

    @objc private func keyChanged(_ notification: Notification) { updateCaret() }

    private var resizing = false

    override func setFrameSize(_ newSize: NSSize) {
        // A text view that is resized scrolls its selection into sight. The
        // timeline sizes every day, and keeps the window where it was; the
        // text view is not to move it too.
        resizing = true
        super.setFrameSize(newSize)
        resizing = false
        updateCaret()
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        resizing ? false : super.scrollToVisible(rect)
    }

    /// Selects rows as rows, from the one the selection started at to the
    /// one it has reached.
    func selectRows(anchor: Int, head: Int, stillSelecting: Bool = false) {
        let count = paragraphRanges.count
        rowAnchor = min(max(anchor, 0), count - 1)
        rowHead = min(max(head, 0), count - 1)
        let rows = min(rowAnchor, rowHead)..<(max(rowAnchor, rowHead) + 1)
        let entering = selectedRows == nil
        selectedRows = rows
        if entering {
            selectedTextAttributes = [:]
            caret.hide()
        }
        let ranges = paragraphRanges
        let start = ranges[rows.lowerBound].location
        let end = min(NSMaxRange(ranges[rows.upperBound - 1]), lastLocation)
        let wasAdjusting = adjusting
        adjusting = true
        super.setSelectedRanges([NSValue(range: NSRange(location: start, length: max(0, end - start)))],
                                affinity: .downstream, stillSelecting: stillSelecting)
        adjusting = wasAdjusting
        needsDisplay = true
    }

    func leaveRowSelection() {
        selectedRows = nil
        selectedTextAttributes = textSelectionAttributes
        needsDisplay = true
    }

    /// Back to editing text, with the caret at the end of a row.
    func editText(inRow index: Int, atEnd: Bool = true) {
        leaveRowSelection()
        let paragraph = paragraphRanges[min(index, paragraphRanges.count - 1)]
        setSelectedRange(NSRange(location: atEnd ? NSMaxRange(paragraph) - 1 : paragraph.location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // The caret is `CaretView`'s to draw.
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        let became = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateCaret() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        let resigned = super.resignFirstResponder()
        if resigned {
            caret.hide()
            endLinkCompletion()
        }
        return resigned
    }

    // MARK: Mouse

    /// The row under the pointer.
    private(set) var hoveredRow: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["hover"] != nil {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: ["hover": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hover(at: point)
        showLinkCard(at: point)
        // Bullets, checkboxes and pictures are things to click, not text:
        // over them the pointer is the arrow.
        if outlineLayout.handleHit(at: point, origin: textContainerOrigin) != nil
            || outlineLayout.pictureHit(at: point, origin: textContainerOrigin) != nil {
            NSCursor.arrow.set()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if outlineLayout.handleHit(at: point, origin: textContainerOrigin) != nil
            || outlineLayout.pictureHit(at: point, origin: textContainerOrigin) != nil {
            NSCursor.arrow.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(at: nil)
        LinkCard.shared.scheduleHide()
    }

    override func scrollWheel(with event: NSEvent) {
        LinkCard.shared.hide()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        LinkCard.shared.hide()
        super.keyDown(with: event)
    }

    /// Shows the card of the link under the pointer, or lets it go.
    private func showLinkCard(at point: NSPoint) {
        guard let hover = linkHover(at: point) else {
            LinkCard.shared.scheduleHide()
            return
        }
        let screen = firstRect(forCharacterRange: hover.range, actualRange: nil)
        LinkCard.shared.hover(hover, in: self, anchor: screen)
    }

    /// The link under a point: where it goes, where it is, and whether it is
    /// an address written out, which could take its page's title instead.
    func linkHover(at point: NSPoint) -> LinkCard.Hover? {
        guard let url = link(at: point), let layout = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let character = layout.characterIndexForGlyph(at: layout.glyphIndex(for: inContainer, in: container))
        let span = spans(atRowOf: character).first { span in
            guard NSLocationInRange(character, span.range) else { return false }
            switch span.kind {
            case .url, .link, .wikiLink: return true
            default: return false
            }
        }
        guard let span else {
            var range = NSRange()
            _ = storage.attribute(.link, at: character, effectiveRange: &range)
            return LinkCard.Hover(url: url, range: range, isBare: false)
        }
        switch span.kind {
        case .url:
            return LinkCard.Hover(url: url, range: span.range, isBare: true)
        case .link(let target):
            // `<https://…>` is an address written out too; `[text](…)` is not.
            let text = (storage.string as NSString).substring(with: span.content)
            return LinkCard.Hover(url: url, range: span.range, isBare: text == target)
        default:
            return LinkCard.Hover(url: url, range: span.range, isBare: false)
        }
    }

    /// Puts `[Title](address)` in place of a link's text.
    func replaceLink(_ range: NSRange, with title: String, url: URL) {
        let escaped = title.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        guard NSMaxRange(range) <= textStorage!.length else { return }
        window?.makeFirstResponder(self)
        insertText("[\(escaped)](\(url.absoluteString))", replacementRange: range)
        undoManager?.setActionName("Use Title")
    }

    /// Notes the row a point is over, in its text or in the space before it.
    func hover(at point: NSPoint?) {
        var row: Int?
        if let point, let layout = layoutManager, let container = textContainer, textStorage!.length > 0 {
            let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: inContainer, in: container)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if inContainer.y >= fragment.minY - 2 && inContainer.y <= fragment.maxY + 2 {
                row = rowIndex(at: layout.characterIndexForGlyph(at: glyph))
            }
        }
        guard row != hoveredRow else { return }
        hoveredRow = row
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = outlineLayout.handleHit(at: point, origin: textContainerOrigin) {
            window?.makeFirstResponder(self)
            clickHandle(ofRow: index)
            return
        }
        if let picture = outlineLayout.pictureHit(at: point, origin: textContainerOrigin) {
            window?.makeFirstResponder(self)
            if event.clickCount >= 2 {
                // Double-clicked, a picture opens in the app that opens it.
                if let url = URL(string: picture.source) { navigator?.outlineView(self, open: url, inSplit: false) }
            } else if let location = rangeOfPicture(picture)?.location {
                // Once, it takes the caret beside it — or, moved, it is dragged.
                let start = event.locationInWindow
                while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                    if next.type == .leftMouseUp { break }
                    if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 4 {
                        if let frame = outlineLayout.pictureFrame(at: point, origin: textContainerOrigin)?.frame, isEditable {
                            beginDragging(picture, frame: frame, event: event)
                        }
                        return
                    }
                }
                if selectedRows != nil { leaveRowSelection() }
                setSelectedRange(NSRange(location: location, length: 0))
            }
            return
        }
        LinkCard.shared.hide()
        if event.clickCount == 1, let url = link(at: point) {
            // A click on a link follows it — once the button comes up
            // without the pointer having moved off to drag.
            window?.makeFirstResponder(self)
            let start = event.locationInWindow
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                let moved = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
                if next.type == .leftMouseUp {
                    if moved < 4 { navigator?.outlineView(self, open: url, inSplit: event.modifierFlags.contains(.option)) }
                    return
                }
            }
            return
        }
        if selectedRows != nil { leaveRowSelection() }
        super.mouseDown(with: event)
    }

    /// The link under a point, when the point is on its text.
    private func link(at point: NSPoint) -> URL? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layout.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layout.numberOfGlyphs else { return nil }
        // Only on the glyph itself, not in the space beyond a line's end.
        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.insetBy(dx: -1, dy: -2).contains(inContainer) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        let value = storage.attribute(.link, at: character, effectiveRange: nil)
        return value as? URL ?? (value as? String).flatMap(URL.init(string:))
    }

    /// Where a picture's Markdown is in the text.
    func rangeOfPicture(_ picture: ImageBox) -> NSRange? {
        var found: NSRange?
        textStorage!.enumerateAttribute(.outlineImage, in: NSRange(location: 0, length: textStorage!.length)) { value, range, stop in
            if value as? ImageBox === picture {
                found = range
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: A picture's menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let picture = outlineLayout.pictureHit(at: point, origin: textContainerOrigin),
              let location = rangeOfPicture(picture)?.location else { return super.menu(for: event) }
        LinkCard.shared.hide()
        window?.makeFirstResponder(self)
        if selectedRows != nil { leaveRowSelection() }
        setSelectedRange(NSRange(location: location, length: 0))
        return pictureMenu(picture, at: location)
    }

    /// What can be done with a picture: as Safari and TextEdit offer it.
    private func pictureMenu(_ picture: ImageBox, at location: Int) -> NSMenu {
        let menu = NSMenu(title: "Picture")
        let source = picture.source
        let file = images?.graphFile(source)
        let address = URL(string: source)
        func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, run: run)
            return item
        }
        if images?.tweet(source) != nil {
            menu.addItem(item("Open Post") { [weak self] in
                guard let self, let address else { return }
                navigator?.outlineView(self, open: address, inSplit: false)
            })
            menu.addItem(item("Copy Link") { Self.copy(string: source) })
        } else {
            menu.addItem(item("Open Image") { [weak self] in
                guard let self else { return }
                if let file { NSWorkspace.shared.open(file) }
                else if let address { navigator?.outlineView(self, open: address, inSplit: false) }
            })
            if let file {
                menu.addItem(item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            }
            menu.addItem(.separator())
            menu.addItem(item("Copy Image") { [weak self] in self?.copyPicture(source, file: file) })
            menu.addItem(item("Copy Image Address") { Self.copy(string: source) })
        }
        if isEditable {
            menu.addItem(.separator())
            menu.addItem(item(images?.tweet(source) != nil ? "Delete Post" : "Delete Image") { [weak self] in
                self?.deletePicture(at: location)
            })
        }
        return menu
    }

    /// The picture on the clipboard, as PNG and TIFF both, so it pastes
    /// into any app; and, for one in the graph, its file too.
    private func copyPicture(_ source: String, file: URL?) {
        guard let image = images?.image(source) else { NSSound.beep(); return }
        let item = NSPasteboardItem()
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                item.setData(png, forType: .png)
            }
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.writeObjects([item])
        Log.shared.info("files", "Copied \(source)")
    }

    private static func copy(string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Takes a picture out of the note, its size and all.
    private func deletePicture(at location: Int) {
        guard let span = spans(atRowOf: location).first(where: { span in
            guard span.range.location == location else { return false }
            if case .url = span.kind { return true }
            return span.isImage
        }) else { return }
        insertText("", replacementRange: span.range)
        undoManager?.setActionName("Delete Image")
    }

    /// A checkbox checks; a bullet with children folds or unfolds them.
    private func clickHandle(ofRow index: Int) {
        let row = row(at: index)
        if row.task != nil {
            perform("Toggle Done", on: index..<(index + 1)) { rows, selection in
                OutlineEditing.toggleDone(&rows, selection)
                return selection
            }
        } else if row.isFolded {
            perform("Expand", on: index..<(index + 1)) { rows, selection in
                OutlineEditing.unfold(&rows, at: selection.lowerBound)
                return selection
            }
        } else if OutlineEditing.hasChildren(rows, index) {
            perform("Collapse", on: index..<(index + 1)) { rows, selection in
                OutlineEditing.fold(&rows, at: selection.lowerBound)
                return selection
            }
        } else {
            // A bullet with nothing to fold, or a ghost of one, picks the
            // row up as a row.
            selectRows(anchor: index, head: index)
        }
    }

    override func clicked(onLink link: Any, at charIndex: Int) {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return }
        navigator?.outlineView(self, open: url, inSplit: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    // MARK: Moving across edges

    private func lineFragment(at location: Int) -> NSRect {
        guard let layout = layoutManager, textStorage!.length > 0 else { return .zero }
        let glyph = layout.glyphIndexForCharacter(at: min(location, textStorage!.length - 1))
        guard glyph < layout.numberOfGlyphs else { return .zero }
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private var caretX: CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 0 }
        let location = selectedRange().location
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).minX + textContainerOrigin.x
    }

    /// Puts the caret on the first or last line, as near to `x` as it goes.
    func enter(from edge: Edge, x: CGFloat, scrolling: Bool = true) {
        leaveRowSelection()
        let location = edge == .top ? 0 : lastLocation
        let fragment = lineFragment(at: location)
        let point = NSPoint(x: min(max(x, 0), bounds.width - 1), y: fragment.midY + textContainerOrigin.y)
        let index = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: min(index, lastLocation), length: 0))
        if scrolling { scrollRangeToVisible(selectedRange()) }
    }

    /// Where the selection starts, in the view.
    var firstRectOfSelection: NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualCharacterRange: nil)
        return layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    override func moveUp(_ sender: Any?) {
        if let linkCompletion {
            linkCompletion.move(-1)
            return
        }
        if let selectedRows {
            let head = rowHead > 0 ? rowHead - 1 : 0
            if selectedRows.lowerBound == 0 && rowHead == 0 { NSSound.beep(); return }
            selectRows(anchor: head, head: head)
            scrollRowToVisible(head)
            return
        }
        if selectedRange().length == 0, lineFragment(at: selectedRange().location).minY <= lineFragment(at: 0).minY {
            navigator?.outlineView(self, leaveThrough: .top, x: caretX)
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if let linkCompletion {
            linkCompletion.move(1)
            return
        }
        if let selectedRows {
            let last = paragraphRanges.count - 1
            if selectedRows.upperBound - 1 == last && rowHead == last { NSSound.beep(); return }
            let head = min(rowHead + 1, last)
            selectRows(anchor: head, head: head)
            scrollRowToVisible(head)
            return
        }
        if selectedRange().length == 0, lineFragment(at: selectedRange().location).minY >= lineFragment(at: lastLocation).minY {
            navigator?.outlineView(self, leaveThrough: .bottom, x: caretX)
            return
        }
        super.moveDown(sender)
    }

    override func moveUpAndModifySelection(_ sender: Any?) {
        if selectedRows != nil {
            selectRows(anchor: rowAnchor, head: rowHead - 1)
            scrollRowToVisible(rowHead)
            return
        }
        let row = rowIndex(at: selectedRange().location)
        if lineFragment(at: selectedRange().location).minY <= lineFragment(at: paragraphRanges[row].location).minY, row > 0 {
            selectRows(anchor: row, head: row - 1)
            return
        }
        super.moveUpAndModifySelection(sender)
    }

    override func moveDownAndModifySelection(_ sender: Any?) {
        if selectedRows != nil {
            selectRows(anchor: rowAnchor, head: rowHead + 1)
            scrollRowToVisible(rowHead)
            return
        }
        let row = rowIndex(at: selectedRange().location)
        let paragraph = paragraphRanges[row]
        if lineFragment(at: NSMaxRange(selectedRange())).minY >= lineFragment(at: NSMaxRange(paragraph) - 1).minY,
           row < paragraphRanges.count - 1 {
            selectRows(anchor: row, head: row + 1)
            return
        }
        super.moveDownAndModifySelection(sender)
    }

    override func moveLeft(_ sender: Any?) {
        if selectedRows != nil { collapse(sender); return }
        if !stepOverMarkup(forward: false) { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        if selectedRows != nil { expand(sender); return }
        if !stepOverMarkup(forward: true) { super.moveRight(sender) }
    }

    /// Moves the caret a character within its row, stopping on both sides of
    /// hidden markup. False when there is no row left that way.
    private func stepOverMarkup(forward: Bool) -> Bool {
        let range = selectedRange()
        guard range.length == 0, textStorage!.length > 0 else { return false }
        let bounds = textRange(ofRowAt: range.location)
        if forward ? range.location >= NSMaxRange(bounds) : range.location <= bounds.location { return false }
        let next = InlineEditing.step(from: range.location, forward: forward, text: textStorage!.string as NSString,
                                      within: bounds, spans: spans(atRowOf: range.location))
        let wasAdjusting = adjusting
        adjusting = true
        setSelectedRange(NSRange(location: next, length: 0))
        adjusting = wasAdjusting
        typingAttributes = typingAttributes.filter { $0.key != .outlineHidden }
        updateCaret()
        scrollRangeToVisible(selectedRange())
        return true
    }

    private func scrollRowToVisible(_ index: Int) {
        guard index >= 0, index < paragraphRanges.count else { return }
        scrollRangeToVisible(paragraphRanges[index])
    }

    // MARK: Keys

    /// Escape selects the caret's row as a row, and goes back to its text.
    override func cancelOperation(_ sender: Any?) {
        if linkCompletion != nil {
            endLinkCompletion()
            return
        }
        if let selectedRows {
            editText(inRow: rowHead == selectedRows.lowerBound ? rowHead : rowHead)
        } else {
            let row = rowIndex(at: selectedRange().location)
            selectRows(anchor: row, head: row)
        }
    }

    override func selectAll(_ sender: Any?) {
        let row = rowIndex(at: selectedRange().location)
        let paragraph = paragraphRanges[row]
        // The first time, the row's text; then every row.
        let text = NSRange(location: paragraph.location, length: paragraph.length - 1)
        if selectedRows == nil && selectedRange() != text && text.length > 0 {
            setSelectedRange(text)
        } else {
            selectRows(anchor: 0, head: paragraphRanges.count - 1)
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        if selectedRows != nil {
            if text == " " { toggleDone(nil) } else { NSSound.beep() }
            return
        }
        if text == " ", replacementRange.location == NSNotFound, selectedRange().length == 0, applySmartRowType() { return }
        super.insertText(string, replacementRange: replacementRange)
        if text == "[" { beginLinkCompletion() }
    }

    // MARK: Finishing links

    /// `[[` just typed, outside code, starts a link to finish.
    private func beginLinkCompletion() {
        guard LinkCompletion.source != nil, linkCompletion == nil, let storage = textStorage else { return }
        let caret = selectedRange().location
        let text = storage.string as NSString
        guard caret >= 2, text.substring(with: NSRange(location: caret - 2, length: 2)) == "[[",
              caret < 3 || text.character(at: caret - 3) != 0x5b else { return }
        if case .code = row(at: rowIndex(at: caret)).kind { return }
        if spans(atRowOf: caret).contains(where: { $0.kind == .code && NSLocationInRange(caret - 1, $0.range) }) { return }
        let completion = LinkCompletion(textView: self, start: caret)
        linkCompletion = completion
        if !completion.refresh() { endLinkCompletion() }
    }

    /// Keeps the list with what is typed, or puts it away when the caret
    /// has left the link.
    private func updateLinkCompletion() {
        guard let completion = linkCompletion else { return }
        if !completion.refresh() { endLinkCompletion() }
    }

    func endLinkCompletion() {
        linkCompletion?.close()
        linkCompletion = nil
    }

    func acceptLinkCompletion() {
        guard let completion = linkCompletion else { return }
        linkCompletion = nil
        completion.close()
        completion.accept()
    }

    override func insertTab(_ sender: Any?) {
        if linkCompletion != nil { acceptLinkCompletion(); return }
        indentRows(sender)
    }
    override func insertBacktab(_ sender: Any?) { outdentRows(sender) }

    override func insertNewline(_ sender: Any?) {
        if linkCompletion != nil {
            acceptLinkCompletion()
            return
        }
        if let selectedRows {
            // Return from rows makes a new row after them, to write in.
            let index = selectedRows.upperBound - 1
            editText(inRow: index)
            insertRow(after: index)
            return
        }
        splitRow()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { insertNewline(sender) }

    override func insertLineBreak(_ sender: Any?) {
        guard selectedRows == nil else { return }
        if case .heading = row(at: rowIndex(at: selectedRange().location)).kind {
            splitRow()
            return
        }
        super.insertLineBreak(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if selectedRows != nil { deleteRows(sender); return }
        let range = selectedRange()
        if range.length == 0 {
            let index = rowIndex(at: range.location)
            if range.location == paragraphRanges[index].location {
                var row = row(at: index)
                // Deleting at the start of a row of some type makes it a
                // plain row first, as in Bike.
                if row.task != nil || !(row.kind == .bullet || row.kind == .paragraph) {
                    if row.task != nil {
                        row.task = nil
                        row.marker = "-"
                    } else {
                        row.kind = .bullet
                        row.marker = "-"
                        row.spacing = 1
                    }
                    row.text = self.row(at: index).text
                    replaceRow(index, with: rowWithText(index, row), actionName: "Change Row Type")
                    setSelectedRange(NSRange(location: paragraphRanges[index].location, length: 0))
                    return
                }
                if index == 0 { return }
            }
        }
        if !deleteShown(forward: false) { super.deleteBackward(sender) }
    }

    override func deleteForward(_ sender: Any?) {
        if selectedRows != nil { deleteRows(sender); return }
        if selectedRange().length == 0 && selectedRange().location >= lastLocation { return }
        if !deleteShown(forward: true) { super.deleteForward(sender) }
    }

    /// Deletes the nearest shown character, as Bike does, when hidden
    /// markup is in the way or the character is all a span shows. False
    /// when an ordinary delete will do.
    private func deleteShown(forward: Bool) -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, textStorage!.length > 0 else { return false }
        let bounds = textRange(ofRowAt: caret.location)
        let spans = spans(atRowOf: caret.location)
        guard !spans.isEmpty,
              let target = InlineEditing.deletion(at: caret.location, forward: forward, text: textStorage!.string as NSString,
                                                  within: bounds, spans: spans)
        else { return false }
        let adjacent = forward ? target.location == caret.location : NSMaxRange(target) == caret.location
        if adjacent && target.length == (textStorage!.string as NSString).rangeOfComposedCharacterSequence(at: target.location).length {
            return false
        }
        // The caret keeps its side of the markup it was beside.
        let after = forward ? caret.location : caret.location - target.length
        let wasAdjusting = adjusting
        adjusting = true
        if shouldChangeText(in: target, replacementString: "") {
            textStorage!.replaceCharacters(in: target, with: "")
            didChangeText()
        }
        adjusting = wasAdjusting
        tidy()
        let location = NSMaxRange(target) <= caret.location ? after : caret.location
        setSelectedRange(NSRange(location: min(location, lastLocation), length: 0))
        return true
    }

    private func rowWithText(_ index: Int, _ row: Row) -> Row {
        var row = row
        row.text = rows[index].text
        return row
    }

    // MARK: Pasteboard

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let selectedRows {
            guard type == .string else { return false }
            pboard.setString(markdown(forRows: selectedRows), forType: .string)
            return true
        }
        if type == .string {
            let text = (textStorage!.string as NSString).substring(with: selectedRange())
            pboard.setString(text.replacingOccurrences(of: OutlineText.lineSeparator, with: "\n"), forType: .string)
            return true
        }
        return super.writeSelection(to: pboard, type: type)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        selectedRows != nil ? [.string] : super.writablePasteboardTypes
    }

    override func copy(_ sender: Any?) {
        guard let selectedRows else { super.copy(sender); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(forRows: selectedRows), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard selectedRows != nil else { super.cut(sender); return }
        copy(sender)
        deleteRows(sender)
    }

    override func paste(_ sender: Any?) {
        let files = incoming(from: .general)
        if !files.isEmpty {
            add(files)
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else { super.paste(sender); return }
        let lines = text.hasSuffix("\n") ? String(text.dropLast()) : text
        if selectedRows == nil && !lines.contains("\n") {
            pasteAsPlainText(sender)
            return
        }
        pasteRows(OutlineMarkdown.parse(text).unfoldedRows)
    }

    /// The rows and all inside them, as Markdown standing on its own.
    func markdown(forRows selection: Range<Int>) -> String {
        let all = rows
        let block = OutlineEditing.block(all, selection)
        let base = all[block].map(\.depth).min() ?? 0
        var copied = Row.unfold(all[block].map { row in
            var row = row
            row.depth -= base
            return row
        })
        if !copied.isEmpty { copied[0].gap = [] }
        return OutlineMarkdown.serialize(Outline(rows: copied))
    }
}

/// The caret: a bar two points wide with rounded ends in the accent
/// colour, that holds steady while the caret moves and fades in and out as
/// it rests, as on iOS. Beside hidden markup it has a tail along the
/// baseline, pointing to the side it belongs to.
final class CaretView: NSView {
    private let bar = CALayer()
    private let tail = CALayer()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bar)
        layer?.addSublayer(tail)
        bar.cornerRadius = 1
        tail.cornerRadius = 1
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func hide() {
        isHidden = true
        layer?.removeAnimation(forKey: "blink")
    }

    /// Shows the caret at `bar`, with a tail at `tail`, both in the text
    /// view's coordinates, and starts its blink over.
    func show(bar barRect: NSRect, tail tailRect: NSRect?) {
        let frame = tailRect.map { barRect.union($0) } ?? barRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        bar.frame = barRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        tail.frame = tailRect?.offsetBy(dx: -frame.minX, dy: -frame.minY) ?? .zero
        tail.isHidden = tailRect == nil
        let color = NSColor.controlAccentColor.usingColorSpace(.deviceRGB)?.cgColor ?? NSColor.controlAccentColor.cgColor
        bar.backgroundColor = color
        tail.backgroundColor = color
        isHidden = false
        CATransaction.commit()
        blink()
    }

    /// Solid for a moment after moving; then fading out and in again.
    private func blink() {
        guard let layer else { return }
        layer.removeAnimation(forKey: "blink")
        layer.opacity = 1
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [1, 1, 0, 0, 1]
        animation.keyTimes = [0, 0.45, 0.6, 0.85, 1]
        animation.duration = 1.1
        animation.repeatCount = .infinity
        animation.beginTime = CACurrentMediaTime() + 0.5
        animation.fillMode = .backwards
        layer.add(animation, forKey: "blink")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.backgroundColor = NSColor.controlAccentColor.cgColor
            tail.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire(_ sender: Any?) { run() }
}
