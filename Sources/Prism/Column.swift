import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// One mark on the scrubber: a day or week, a heading, or a topic.
struct ScrubMark {
    var y: CGFloat
    var title: String
    var detail: String?
    /// 3 for a day or week, 2 for a heading, 1 for a topic.
    var rank: Int
    /// A week's mark, in a shade of its own.
    var isWeek = false
}

/// A column of the window, the window's way of arranging things: the days,
/// one after another, oldest at the top, each week's note before the days
/// it covers; a note on its own; or what links to a note. It is a stack of
/// blocks — each note the outline editor's, under its name — with a
/// scrubber down the left whose ticks are the blocks and what is in them.
@MainActor
final class Column: NSView, OutlineTextViewNavigator {
    enum Kind: Equatable {
        case timeline
        case note(NoteRef)
        /// The notes linking to a note.
        case backlinks(NoteRef)
        /// The notes in the inbox.
        case inbox
        /// The tasks of every note, grouped as Reflect groups them.
        case tasks
        /// The notes some words are found in.
        case search(String)
        /// A link note's page, on the web, marked with its highlights.
        case web(NoteRef)
    }

    let graph: Graph
    let images: ImageStore
    private(set) var kind: Kind = .timeline
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let scrubber = Scrubber()
    private let tip = ScrubTip()
    private let close = CloseButton()
    /// Folds the column away, to a strip at the window's right.
    private let foldButton = CloseButton(symbol: "sidebar.right", pointSize: 11, toolTip: "Fold Column Away (⌥⌘C)")
    var onFold: ((Column) -> Void)?
    /// Where it was among the columns before it was folded: gone back to, opened.
    var unfoldedIndex: Int?
    private let fade = TopFade()
    /// While the pointer is over the column: a sheet of each kind to add.
    private let sheetBar = SheetBar()
    /// A sheet of a kind asked for, from the bar, on this column.
    var onAddSheet: ((Column, SheetBar.Choice) -> Void)?
    private let grip = SheetGrip()
    /// The sheets beneath, bunched in the title bar.
    private let stackPill = StackPill()
    /// What floats over the sheet, left out of its picture.
    var chrome: [NSView] { [stackPill, sheetBar, close, preview] + (stackScrubber.map { [$0] } ?? []) }
    /// The bunch spread across the top, while hovered.
    private var stackScrubber: StackScrubber?
    /// Over the column while scrubbing: the sheet pointed at, as it was.
    private let preview = NSImageView()
    /// The sheets beneath the one shown, the bottom first: where the column
    /// has been, to go back to.
    var beneath: [Sheet] = [] { didSet { stackChanged() } }
    /// The sheets gone back from, the nearest first: the way forward again.
    var ahead: [Sheet] = [] { didSet { stackChanged() } }
    /// Whether its own sheet is pinned: kept when the column goes back past it.
    var isPinned = false { didSet { if isPinned != oldValue { stackChanged() } } }
    // MARK: Folded away

    /// Folded to a strip at the side: its name, to open it again by.
    var isCollapsed = false {
        didSet {
            guard isCollapsed != oldValue else { return }
            if isCollapsed { hideSheetList(animated: false) }
            strip.isHidden = !isCollapsed
            for view in unfolded { view.isHidden = isCollapsed }
            if !isCollapsed {
                stackPill.isHidden = !hasStack
                close.isHidden = !closable
                foldButton.isHidden = !closable
                preview.isHidden = true
                tip.isHidden = true
                updateSheetBar()
            } else {
                sheetBar.isHidden = true
            }
            strip.title = Self.title(of: kind, top: current?.ref)
            strip.symbol = StackPill.symbol(for: kind)
            strip.count = beneath.count + 1
            strip.face = face
            needsLayout = true
        }
    }
    let strip = CollapsedStrip()
    /// What a folded column hides.
    private var unfolded: [NSView] { [scroll, fade, scrubber, close, foldButton, grip, stackPill] }
    /// Its folded strip was clicked, or hovered.
    var onUnfold: ((Column) -> Void)?
    var onStripHover: ((Column, Bool) -> Void)?

    /// Told to go forward to a sheet gone back from, by its place in `ahead`.
    var onForward: ((Column, Int) -> Void)?
    /// Told to pin or unpin a sheet: its own, for nil; else one beneath.
    var onPinSheet: ((Column, Int?) -> Void)?

    private var hasStack: Bool { !beneath.isEmpty || !ahead.isEmpty }

    /// Whether it shows a page on the web: no sheets on it, nor bar to add
    /// them — only closed.
    var isWeb: Bool { if case .web = kind { true } else { false } }

    private func stackChanged() {
        stackPill.sheets = beneath
        stackPill.forward = beneath.isEmpty ? ahead.first : nil
        stackPill.isHidden = !hasStack || switcher != nil || stackScrubber != nil || isCollapsed || isWeb
        if !hasStack { hideSheetList() }
        needsLayout = true
    }
    /// A picture drawn of a sheet, at the column's size: for one beneath
    /// that has none, left before a restart.
    var onNeedPicture: ((Sheet, NSSize) -> NSImage?)?

    /// The sheet beneath at a place, its picture drawn if it has none.
    private func pictured(_ index: Int) -> NSImage? {
        guard beneath.indices.contains(index) else { return nil }
        if let image = beneath[index].snapshot { return image }
        let image = onNeedPicture?(beneath[index], bounds.size)
        beneath[index].snapshot = image
        return image
    }

    /// A sheet on the way forward, its picture drawn if it has none.
    private func aheadPicture(_ index: Int) -> NSImage? {
        guard ahead.indices.contains(index) else { return nil }
        if let image = ahead[index].snapshot { return image }
        let image = onNeedPicture?(ahead[index], bounds.size)
        ahead[index].snapshot = image
        return image
    }

    /// Told to bring a sheet beneath to the top, by its place in `beneath`.
    var onRaise: ((Column, Int) -> Void)?
    /// A sheet was picked up: the top, for nil; else one beneath, by its place.
    var onDragSheet: ((Column, Int?, NSEvent) -> Void)?
    /// ⌘E's file of cards, while it is open.
    private(set) var switcher: SheetSwitcher?
    private(set) var blocks: [ColumnBlock] = []
    /// The notes in it, to edit.
    var views: [DayView] { blocks.compactMap { $0 as? DayView } }

    var metrics: OutlineMetrics {
        didSet {
            for view in views { view.metrics = metrics }
            relayout()
        }
    }
    var face: Typeface = .mona
    /// Its share of the window's width, among the columns'.
    var share: CGFloat = 1

    /// A link to follow, from here: and whether to a column of its own.
    var onOpen: ((URL, Column, _ newColumn: Bool) -> Void)?
    /// A note to open, from here — a backlink's — and whether in a column of its own.
    var onOpenPath: ((String, Column, _ newColumn: Bool) -> Void)?
    /// It was scrolled.
    var onScroll: ((Column) -> Void)?
    /// A note in it was written.
    var onSave: ((DayView) -> Void)?
    /// The note at the top of the column changed.
    var onCurrent: ((Column) -> Void)?
    var onClose: ((Column) -> Void)?
    /// Whether it may be closed: not when it is the only one.
    var closable = false {
        didSet {
            close.isHidden = !closable || isCollapsed
            foldButton.isHidden = !closable || isCollapsed
        }
    }

    init(graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.graph = graph
        self.images = images
        self.metrics = metrics
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.drawsBackground = false
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(cardModeChanged(_:)), name: CardModes.changed, object: nil)
        // Clicked anywhere in it: the column worked in. Not holding the click
        // back from what it lands on.
        let ground = NSClickGestureRecognizer(target: self, action: #selector(groundClicked(_:)))
        ground.delaysPrimaryMouseButtonEvents = false
        document.addGestureRecognizer(ground)
        scroll.wantsLayer = true
        addSubview(scroll)
        addSubview(fade)
        addSubview(scrubber)
        // Out of sight till pointed at.
        scrubber.alphaValue = 0
        addSubview(tip)
        addSubview(close)
        addSubview(foldButton)
        foldButton.isHidden = true
        foldButton.target = self
        foldButton.action = #selector(foldClicked)
        addSubview(grip)
        strip.isHidden = true
        strip.onClick = { [weak self] in
            guard let self else { return }
            onUnfold?(self)
        }
        strip.onHover = { [weak self] inside in
            guard let self else { return }
            onStripHover?(self, inside)
        }
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignTop
        preview.wantsLayer = true
        preview.isHidden = true
        addSubview(preview)
        addSubview(stackPill)
        stackPill.isHidden = true
        addSubview(sheetBar)
        sheetBar.alphaValue = 0
        sheetBar.isHidden = true
        sheetBar.onChoose = { [weak self] choice in
            guard let self else { return }
            onAddSheet?(self, choice)
        }
        stackPill.onClick = { [weak self] in
            guard let self else { return }
            hideSheetList()
            if !beneath.isEmpty { onRaise?(self, beneath.count - 1) } else if !ahead.isEmpty { onForward?(self, 0) }
        }
        stackPill.onDrag = { [weak self] event in
            guard let self else { return }
            hideSheetList()
            onDragSheet?(self, nil, event)
        }
        stackPill.onHover = { [weak self] inside in
            if inside { self?.showSheetList() }
        }
        grip.onDrag = { [weak self] event in
            guard let self else { return }
            onDragSheet?(self, nil, event)
        }
        tip.isHidden = true
        close.isHidden = true
        close.target = self
        close.action = #selector(closeColumn)
        scrubber.onHover = { [weak self] mark, y in self?.hover(mark, at: y) }
        scrubber.onPick = { [weak self] mark in
            guard let self else { return }
            if let webPage, webOutline != nil { webPage.scroll(toY: mark.y, animated: true) } else { scroll(toY: mark.y, animated: true) }
        }
        scrubber.onDrag = { [weak self] fraction in self?.drag(to: fraction) }
        scrubber.onPage = { [weak self] earlier in self?.page(earlier: earlier) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeColumn() { onClose?(self) }
    @objc private func foldClicked() { onFold?(self) }

    // MARK: The bar of sheets to add

    /// Whether the keyboard is in it: its bar of sheets to add shows.
    var isFocused = false { didSet { if isFocused != oldValue { updateSheetBar() } } }

    /// The bar shown on the focused column, always — but not over its stack
    /// dealt out, nor over ⌘E's cards.
    func updateSheetBar() {
        let shown = isFocused && stackScrubber == nil && switcher == nil && !isCollapsed && livePeek == nil && !isWeb
        if shown { sheetBar.backlinksEnabled = current != nil || { if case .backlinks = kind { true } else { false } }() }
        guard shown != (!sheetBar.isHidden && sheetBar.alphaValue > 0) else { return }
        if shown {
            sheetBar.isHidden = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.sheetBar.animator().alphaValue = 1 }
        } else {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; self.sheetBar.animator().alphaValue = 0 }) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.sheetBar.alphaValue == 0 else { return }
                    self.sheetBar.isHidden = true
                }
            }
        }
    }

    // MARK: Contents

    var isTimeline: Bool { kind == .timeline }
    /// Whether it shows many notes, one after another: the timeline, the inbox.
    var listsNotes: Bool { isTimeline || kind == .inbox }

    // MARK: Sheets

    /// The bunch spread, and a sheet pointed at: for a script's picture.
    func showSheetListForScript(pointingAt index: Int?) {
        showSheetList(animated: false)
        if let index { stackScrubber?.hover(index) }
        if let at = ProcessInfo.processInfo.environment["PRISM_PEEK_AT"].flatMap(Double.init) { stackScrubber?.freeze(at: CGFloat(at)) }
    }

    /// The middle of the oldest sheet's shown part, dealt out: for a script's click.
    var oldestSheetPointForScript: NSPoint? {
        guard let scrubber = stackScrubber else { return nil }
        return NSPoint(x: scrubber.frame.minX + 40, y: scrubber.frame.midY)
    }

    /// Spreads the bunched sheets across the top, to scrub along: the
    /// column shows each pointed at, as it was; a click goes back to it.
    private func showSheetList(animated: Bool = true) {
        guard hasStack, switcher == nil, stackScrubber == nil, !isWeb else { return }
        let own = Sheet(kind: kind, place: nil, offset: 0, title: Self.title(of: kind, top: current?.ref), snapshot: nil, pinned: isPinned)
        let scrubber = StackScrubber()
        scrubber.show(beneath + [own] + ahead, own: beneath.count, face: face)
        scrubber.onHover = { [weak self] index in self?.showPreview(index) }
        // Its places: the sheets beneath, its own, then the way forward.
        scrubber.onChoose = { [weak self] index in
            guard let self else { return }
            hideSheetList(animated: false)
            if index < beneath.count { onRaise?(self, index) } else if index > beneath.count { onForward?(self, index - beneath.count - 1) }
        }
        scrubber.onPin = { [weak self] index in
            guard let self, index <= beneath.count else { return }
            onPinSheet?(self, index < beneath.count ? index : nil)
            scrubber.show(beneath + [Sheet(kind: kind, place: nil, offset: 0, title: own.title, snapshot: nil, pinned: isPinned)] + ahead,
                          own: beneath.count, face: face)
        }
        scrubber.onDrag = { [weak self] index, event in
            guard let self, index <= beneath.count else { return }
            hideSheetList(animated: false)
            onDragSheet?(self, index < beneath.count ? index : nil, event)
        }
        scrubber.onLeave = { [weak self] in
            // Peeking live, the pointer goes down into the sheet: it stays.
            guard let self, livePeek == nil else { return }
            hideSheetList()
        }
        // ⌥ down: the sheet pointed at, live; let go: back to its own.
        optionMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, let scrubber = stackScrubber else { return event }
            if event.modifierFlags.contains(.option) {
                if let index = scrubber.hovered, index != beneath.count { peekLive(index) }
            } else if livePeek != nil {
                endLivePeek()
                let point = convert(event.locationInWindow, from: nil)
                if scrubber.frame.contains(point), let index = scrubber.hovered { showPreview(index) } else { hideSheetList() }
            }
            return event
        }
        stackScrubber = scrubber
        addSubview(scrubber)
        stackPill.isHidden = true
        updateSheetBar()
        // Dealt out from the bunch, leftward across the top.
        let pill = stackPill.frame
        let front = NSRect(x: pill.maxX - stackPill.front.width, y: pill.maxY - stackPill.front.maxY,
                           width: stackPill.front.width, height: stackPill.front.height)
        // As tall as the title bar, about the bunch's middle.
        let barHeight: CGFloat = 40
        // Clear of the window's buttons, in the column under them.
        var left: CGFloat = 16
        if let window, let zoom = window.standardWindowButton(.zoomButton), let buttons = zoom.superview {
            let corner = convert(buttons.convert(zoom.frame, to: nil), from: nil)
            if corner.maxX > 0, corner.minY < bounds.maxY { left = max(left, corner.maxX + 14) }
        }
        // Each a peek's width at most: a few sheets stay by the bunch.
        let width = min(front.maxX - left, StackScrubber.width(for: beneath.count + 1 + ahead.count))
        let across = NSRect(x: front.maxX - width, y: (front.midY - barHeight / 2).rounded(), width: width, height: barHeight)
        scrubber.frame = across
        // The bunch, in the scrubber's own (flipped) coordinates.
        scrubber.bunch = NSRect(x: front.minX - across.minX, y: across.maxY - front.maxY, width: front.width, height: front.height)
        scrubber.deal(animated: animated)
    }

    // MARK: Peeking live, ⌥ held

    /// A sheet made, live, to read and scroll in — not to stay: the controller's.
    var onLivePeek: ((Sheet, NSSize) -> Column?)?
    /// The sheet being peeked at live, over this one, while ⌥ is held.
    private var livePeek: Column?
    private var livePeekIndex: Int?
    private var optionMonitor: Any?

    /// The sheet at a place among those spread out: beneath, its own, ahead.
    private func spreadSheet(_ index: Int) -> Sheet? {
        if index < beneath.count { return beneath[index] }
        if index > beneath.count { return ahead.indices.contains(index - beneath.count - 1) ? ahead[index - beneath.count - 1] : nil }
        return nil
    }

    /// Shows a sheet live over this one — scrolled in, read, copied from —
    /// till ⌥ is let go.
    private func peekLive(_ index: Int) {
        guard index != livePeekIndex else { return }
        endLivePeek()
        guard let sheet = spreadSheet(index), let live = onLivePeek?(sheet, bounds.size) else { return }
        live.frame = bounds
        live.autoresizingMask = [.width, .height]
        // Its own paper: what it lies over does not show through.
        live.wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance { live.layer?.backgroundColor = Ink.page.cgColor }
        if let scrubber = stackScrubber { addSubview(live, positioned: .below, relativeTo: scrubber) } else { addSubview(live) }
        livePeek = live
        livePeekIndex = index
        preview.isHidden = true
        updateSheetBar()
    }

    func peekLiveForScript(_ index: Int) { peekLive(index) }
    var scrubberAlphaForScript: CGFloat { scrubber.alphaValue }

    private func endLivePeek() {
        livePeek?.saveAll()
        livePeek?.removeFromSuperview()
        livePeek = nil
        livePeekIndex = nil
    }

    /// The column shows a sheet beneath as it was; its own, as it is.
    private func showPreview(_ index: Int) {
        if NSEvent.modifierFlags.contains(.option), index != beneath.count { return peekLive(index) }
        endLivePeek()
        let image: NSImage? = if index < beneath.count { pictured(index) }
            else if index > beneath.count { aheadPicture(index - beneath.count - 1) } else { nil }
        guard let image else {
            preview.isHidden = true
            return
        }
        preview.image = image
        preview.frame = bounds
        effectiveAppearance.performAsCurrentDrawingAppearance { preview.layer?.backgroundColor = Ink.page.cgColor }
        preview.isHidden = false
    }

    private func hideSheetList(animated: Bool = true) {
        guard let scrubber = stackScrubber else { return }
        endLivePeek()
        if let optionMonitor { NSEvent.removeMonitor(optionMonitor) }
        optionMonitor = nil
        stackScrubber = nil
        preview.isHidden = true
        preview.image = nil
        let done = { [weak self] in
            scrubber.removeFromSuperview()
            guard let self else { return }
            stackPill.isHidden = !hasStack || switcher != nil
            updateSheetBar()
        }
        guard animated, hasStack else { return done() }
        scrubber.gather { done() }
    }

    /// Opens ⌘E's cards on the sheet just beneath the top — ⇧⌘E, on the
    /// top itself, from where only going back down is left.
    func openSwitcher(backward: Bool) {
        guard switcher == nil, !beneath.isEmpty else { return }
        hideSheetList()
        // The nearest few drawn, where they have no pictures: the cards show them.
        for index in beneath.indices.reversed().prefix(6) { _ = pictured(index) }
        let sheets = beneath + [currentSheet]
        let switcher = SheetSwitcher(sheets: sheets, contentSize: bounds.size, selection: backward ? sheets.count - 1 : sheets.count - 2, face: face)
        switcher.frame = bounds
        // The sheets beneath come out of their bunch, and go back into it.
        switcher.origin = stackPill.frame
        switcher.onPick = { [weak self] index in self?.closeSwitcher(choosing: index) }
        addSubview(switcher)
        self.switcher = switcher
        stackPill.isHidden = true
        updateSheetBar()
        switcher.present()
    }

    /// Moves the choice: down the stack for E, up for ⇧E.
    func moveSwitcher(_ delta: Int) { switcher?.move(delta) }

    /// Closes the cards on the one chosen — the top, for none: the sheets
    /// over it taken off, as going back does.
    func closeSwitcher(choosing index: Int?) {
        guard let switcher, !switcher.isClosing else { return }
        let top = beneath.count
        let chosen = index ?? top
        switcher.dismiss(to: chosen) { [weak self, weak switcher] in
            switcher?.tearDown()
            switcher?.removeFromSuperview()
            guard let self else { return }
            self.switcher = nil
            if chosen != top { onRaise?(self, chosen) }
            stackPill.isHidden = !hasStack
            updateSheetBar()
        }
    }

    var switcherSelection: Int? { switcher?.selection }
    /// What was typed in ⌘E's cards, to find a sheet by.
    var switcherQuery: String? { switcher?.query }
    func findInSwitcher(_ typed: String) { switcher?.find(typed) }
    /// A folded column's picture, as it was when folded: shown when its strip is hovered.
    var foldedPicture: NSImage?

    /// Settles the cards at once, for a script's picture.
    func settleSwitcherForScript() { switcher?.settle() }
    func freezeSwitcherForScript(at openness: CGFloat) { switcher?.freeze(at: openness) }

    // MARK: Searching

    /// The words looked for were changed, here.
    var onSearch: ((String, Column) -> Void)?

    /// Shows a search: its head, and the notes found — nil while looking —
    /// each with where the words are, editable. The head is kept as it is
    /// typed in.
    func showSearch(_ query: String, found: [(path: String, slices: [TaskSlice], editable: Bool)]?,
                    names: (String) -> (title: String, detail: String?)) {
        let head = (kind == .search(query) || { if case .search = kind { true } else { false } }())
            ? blocks.first as? SearchHeader : nil
        let top = scroll.contentView.bounds.minY
        let same = head != nil
        if !same { removeBlocks() } else { blocks.dropFirst().forEach { $0.removeFromSuperview() } }
        kind = .search(query)
        let header = head ?? {
            let header = SearchHeader(query: query, metrics: metrics)
            header.onQuery = { [weak self] words in
                guard let self else { return }
                onSearch?(words, self)
            }
            document.addSubview(header)
            return header
        }()
        header.show(count: found?.count)
        let words = Self.words(query)
        let root = graph.root
        let results: [ColumnBlock] = (found ?? []).map { note in
            let name = names(note.path)
            let block = BacklinkBlock(path: note.path, slices: note.slices, editable: note.editable, name: name.title,
                                      detail: name.detail,
                                      folded: SessionState.shared.backlinkFolded(root, to: "search:", from: note.path),
                                      unit: "match", highlight: words, metrics: metrics, face: face, images: images,
                                      navigator: self)
            block.onFold = { [weak self] folded in
                SessionState.shared.setBacklinkFolded(root, to: "search:", from: note.path, folded)
                self?.relayout()
            }
            block.onOpen = { [weak self] newColumn in
                guard let self else { return }
                onOpenPath?(note.path, self, newColumn)
            }
            for editor in block.editors {
                editor.onEdit = { [weak self] editor in
                    guard let self else { return }
                    onSliceEdit?(editor, self)
                }
                editor.onResize = { [weak self] in self?.relayout() }
                editor.view.onRestyle = { [weak self] in self?.relayout() }
                editor.onLeave = { [weak self] in
                    guard let self else { return }
                    onSliceLeave?(self)
                }
            }
            return block
        }
        blocks = [header] + results
        results.forEach(document.addSubview)
        relayout()
        if same {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(top, max(0, document.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scroll(toY: 0, animated: false)
            window?.makeFirstResponder(header.field)
        }
        settled = true
    }

    /// A query's words, as looked for.
    static func words(_ query: String) -> [String] { NoteSearch.words(query) }

    /// Whether the keyboard is in the search's field.
    var isTypingQuery: Bool {
        guard let header = blocks.first as? SearchHeader, let editor = header.field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    // MARK: The tasks

    /// Each task shown, editable where it is.
    var taskEditors: [TaskEditor] { blocks.compactMap { $0 as? TaskGroupBlock }.flatMap(\.editors) }
    /// Every piece of a note shown here away from it — tasks, the rows
    /// links are in — editable where it is.
    var sliceEditors: [TaskEditor] { taskEditors + blocks.compactMap { $0 as? BacklinkBlock }.flatMap(\.editors) }
    /// A piece of a note was typed in: to write back.
    var onSliceEdit: ((TaskEditor, Column) -> Void)?
    /// The keyboard left a piece of a note: what changed meanwhile can be shown.
    var onSliceLeave: ((Column) -> Void)?
    /// Whether the keyboard is in a piece of a note here: shown again only once it leaves.
    var isTypingInSlice: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return sliceEditors.contains { $0.view === responder }
    }

    /// Shows the tasks, their groups under a head — scrolled where they
    /// were, when they were shown already.
    func showTasks(_ groups: [TaskGroupBlock], count: Int) {
        let same = kind == .tasks
        let top = scroll.contentView.bounds.minY
        removeBlocks()
        kind = .tasks
        let head = InboxHeader(metrics: metrics, title: "Tasks")
        head.count = count
        blocks = [head] + groups
        blocks.forEach(document.addSubview)
        relayout()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: same ? min(top, max(0, document.frame.height - scroll.contentSize.height)) : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        settled = true
    }

    // MARK: The inbox

    /// Told to take a note out of the inbox: its handle was clicked.
    var onRemoveFromInbox: ((NoteRef) -> Void)?
    /// Each inbox note's handle, by the note.
    private var handles: [NoteRef: CloseButton] = [:]
    /// The rules between the inbox's notes, as the days are ruled apart.
    private var rules: [NSView] = []
    /// Each note's flags — inbox, pinned, private, topic — by its name.
    private var badges: [NoteRef: NoteBadges] = [:]
    /// Each listed note's ⋯, at the right of its name: its own menu.
    private var menuButtons: [NoteRef: NSButton] = [:]
    /// Told when a note's ⋯ is clicked: its menu, to show from the button.
    var onNoteMenu: ((DayView, NSButton) -> Void)?
    /// What each note's frontmatter says of it, by path: the graph's index's.
    static var flags: (String) -> NoteFlags = { _ in [] }
    /// The page a link note is of, by path: nil for any other note.
    static var linkPage: (String) -> URL? = { _ in nil }
    /// Each link note's open button, at the right of its name: its page, beside.
    private var openButtons: [NoteRef: NSButton] = [:]
    /// A link note's page asked for: to open in a column of its own.
    var onOpenPage: ((NoteRef, Column) -> Void)?
    /// Over each note's header, among many: a click opens the note alone.
    private var headerLinks: [NoteRef: NoteHeaderLink] = [:]
    /// A note's header was clicked: the note, to open on its own — with ⌘,
    /// in a column of its own.
    var onOpenAlone: ((NoteRef, Column, _ newColumn: Bool) -> Void)?

    /// Shows the inbox's notes: those already shown kept where they are,
    /// those new to it first, those gone from it let go.
    func showInbox(_ refs: [NoteRef]) {
        let wasInbox = kind == .inbox
        if !wasInbox {
            removeBlocks()
            kind = .inbox
            settled = false
        }
        var existing = notesShown()
        let header = blocks.lazy.compactMap { $0 as? InboxHeader }.first
        let wanted = Set(refs)
        let kept = blocks.compactMap { ($0 as? DayView)?.ref ?? ($0 as? NoteCardBlock)?.ref }.filter(wanted.contains)
        let ordered = refs.filter { !kept.contains($0) } + kept
        let head = header ?? {
            let head = InboxHeader(metrics: metrics)
            document.addSubview(head)
            return head
        }()
        head.metrics = metrics
        head.count = ordered.count
        blocks = [head] + ordered.map { ref in reuse(ref, from: &existing) }
        existing.values.forEach(letGo)
        for (ref, handle) in handles where !wanted.contains(ref) {
            handle.removeFromSuperview()
            handles[ref] = nil
        }
        for ref in ordered where handles[ref] == nil {
            let handle = CloseButton(symbol: "checkmark.circle", pointSize: round(metrics.fontSize * 1.05), toolTip: "Done: Remove from Inbox")
            handle.target = self
            handle.action = #selector(removeFromInbox(_:))
            handle.identifier = NSUserInterfaceItemIdentifier(ref.path)
            document.addSubview(handle)
            handles[ref] = handle
        }
        relayout()
        if !wasInbox {
            scroll(toY: 0, animated: false)
            settled = true
        }
    }

    @objc private func removeFromInbox(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onRemoveFromInbox?(NoteRef(path: path))
    }

    /// Each handle at the right of its note's name; a rule over each note
    /// but the first.
    private func placeHandles() {
        placeBadges()
        guard kind == .inbox else { return }
        let notes = views
        // The cards part the notes: no rules between.
        while let rule = rules.popLast() { rule.removeFromSuperview() }
        // The check hangs in the margin before the name, where a task's box is.
        for view in notes {
            guard let handle = handles[view.ref] else { continue }
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let marker = view.frame.minX + ((view.frame.width - column) / 2).rounded() + metrics.indent / 2
            handle.frame = NSRect(x: round(marker - 12), y: round(nameMiddle(of: view)) - 12, width: 24, height: 24)
        }
    }

    @objc private func openPageClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpenPage?(NoteRef(path: path), self)
    }

    // MARK: A page on the web

    private var webPage: WebPageView?
    private let webTitle: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Ink.secondary
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.isHidden = true
        return label
    }()
    /// A passage highlighted on the page shown: to keep in its note.
    var onHighlight: ((NoteRef, String) -> Void)?

    /// Shows a link note's page, its highlights marked.
    func showWeb(_ ref: NoteRef, url: URL, highlights: [String]) {
        if kind != .web(ref) { removeBlocks() }
        kind = .web(ref)
        let page = webPage ?? {
            let page = WebPageView()
            addSubview(page, positioned: .above, relativeTo: scroll)
            webPage = page
            return page
        }()
        page.onHighlight = { [weak self] passage in
            guard let self else { return }
            onHighlight?(ref, passage)
        }
        // The page's own outline on the scrubber, when it has one.
        webOutline = nil
        scrubber.isHidden = true
        page.onOutline = { [weak self] outline in self?.showWebOutline(outline) }
        page.onScroll = { [weak self] top, visible in
            guard let self, webOutline != nil else { return }
            scrubber.update(visible: NSRect(x: 0, y: top, width: 1, height: visible))
        }
        page.load(url)
        page.highlights = highlights
        scroll.isHidden = true
        // Only a page: its site over it, and the ×.
        webTitle.stringValue = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        webTitle.isHidden = false
        stackPill.isHidden = true
        grip.isHidden = true
        updateSheetBar()
        needsLayout = true
        settled = true
    }

    /// The page's headings, for its scrubber; none, no scrubber.
    private var webOutline: WebPageView.Outline?

    private func showWebOutline(_ outline: WebPageView.Outline) {
        guard isWeb else { return }
        // A heading or two is not an outline to find one's way by.
        guard outline.headings.count >= 2 else {
            webOutline = nil
            scrubber.isHidden = true
            return
        }
        webOutline = outline
        scrubber.isHidden = false
        let marks = outline.headings.map { ScrubMark(y: $0.y, title: $0.title, detail: nil, rank: $0.level == 1 ? 3 : $0.level == 2 ? 2 : 1) }
        scrubber.earlier = nil
        scrubber.later = nil
        scrubber.update(marks: marks, height: outline.height, visible: NSRect(x: 0, y: 0, width: 1, height: bounds.height))
    }

    func checkWebForScript(choosing passage: String?, done: @escaping (String) -> Void) {
        guard let webPage else { return done("no page") }
        webPage.checkForScript(choosing: passage, done: done)
    }

    /// The page shown, its highlights as its note now says.
    func updateWebHighlights(_ highlights: [String]) { webPage?.highlights = highlights }

    @objc private func noteMenuClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, let view = view(for: NoteRef(path: path)) else { return }
        onNoteMenu?(view, sender)
    }

    /// Where a note's name is, down its view: the title over it, or else
    /// its own first line.
    private func nameMiddle(of view: DayView) -> CGFloat {
        // Laid out at its frame first: the editor placed under its name.
        view.layoutSubtreeIfNeeded()
        let editor = view.editor
        if editor.frame.minY < metrics.fontSize * 2, let layout = editor.layoutManager, layout.numberOfGlyphs > 0 {
            let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            return view.frame.minY + editor.frame.minY + editor.textContainerOrigin.y + line.midY
        }
        return view.frame.minY + round(metrics.fontSize * 2.2) + round(metrics.fontSize * 1.45 * 1.2 / 2)
    }

    /// Over each note's header, where it has one of its own — a day's date,
    /// a week's name, a title — a link to the note alone.
    private func placeHeaderLinks() {
        let notes = listsNotes ? views : []
        let shown = Set(notes.map(\.ref))
        for (ref, link) in headerLinks where !shown.contains(ref) {
            link.removeFromSuperview()
            headerLinks[ref] = nil
        }
        for view in notes {
            view.layoutSubtreeIfNeeded()
            let top = view.editor.frame.minY
            // Its first heading its name, it has no header but its text.
            guard top >= metrics.fontSize * 2 else {
                headerLinks[view.ref]?.removeFromSuperview()
                headerLinks[view.ref] = nil
                continue
            }
            let link = headerLinks[view.ref] ?? {
                let link = NoteHeaderLink()
                let ref = view.ref
                link.onClick = { [weak self] newColumn in
                    guard let self else { return }
                    onOpenAlone?(ref, self, newColumn)
                }
                link.toolTip = "Open “\(Self.name(of: ref).title)” (⌘-click: in the column beside; ⇧⌘-click: in a new one)"
                // Just over its note, and under the flags, which say what they are.
                document.addSubview(link, positioned: .above, relativeTo: view)
                headerLinks[view.ref] = link
                return link
            }()
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let left = view.frame.minX + ((view.frame.width - column) / 2).rounded()
            link.frame = NSRect(x: left, y: view.frame.minY + round(metrics.fontSize * 1.6), width: column,
                                height: max(0, top - round(metrics.fontSize * 1.6) - 2))
        }
    }

    /// Each note's flags, at the right of its name — left of the inbox's ×.
    private func placeBadges() {
        placeHeaderLinks()
        let notes = views
        let shown = Set(notes.map(\.ref))
        for (ref, badge) in badges where !shown.contains(ref) {
            badge.removeFromSuperview()
            badges[ref] = nil
        }
        // A ⋯ on each note among many, its own menu.
        let menuSide: CGFloat = 26
        for (ref, button) in menuButtons where !shown.contains(ref) || !listsNotes {
            button.removeFromSuperview()
            menuButtons[ref] = nil
        }
        if listsNotes {
            for view in notes {
                let button = menuButtons[view.ref] ?? {
                    let button = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Note Menu")!,
                                          target: self, action: #selector(noteMenuClicked(_:)))
                    button.isBordered = false
                    button.contentTintColor = Ink.secondary
                    button.toolTip = "Pin, inbox, copy link…"
                    document.addSubview(button)
                    menuButtons[view.ref] = button
                    return button
                }()
                button.identifier = NSUserInterfaceItemIdentifier(view.ref.path)
                let column = min(metrics.columnWidth, view.frame.width - 48)
                let right = view.frame.minX + ((view.frame.width - column) / 2).rounded() + column
                button.frame = NSRect(x: right - menuSide, y: round(nameMiddle(of: view) - menuSide / 2), width: menuSide, height: menuSide)
            }
        }
        // A link note's page, a button away.
        for (ref, button) in openButtons where !shown.contains(ref) || Self.linkPage(ref.path) == nil {
            button.removeFromSuperview()
            openButtons[ref] = nil
        }
        for view in notes where Self.linkPage(view.ref.path) != nil {
            let button = openButtons[view.ref] ?? {
                let button = NSButton(image: NSImage(systemSymbolName: "safari", accessibilityDescription: "Open Page")!,
                                      target: self, action: #selector(openPageClicked(_:)))
                button.isBordered = false
                button.contentTintColor = Ink.secondary
                button.toolTip = "Open the page beside this note, its highlights marked"
                document.addSubview(button)
                openButtons[view.ref] = button
                return button
            }()
            button.identifier = NSUserInterfaceItemIdentifier(view.ref.path)
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let right = view.frame.minX + ((view.frame.width - column) / 2).rounded() + column - (listsNotes ? menuSide : 0)
            button.frame = NSRect(x: right - menuSide, y: round(nameMiddle(of: view) - menuSide / 2), width: menuSide, height: menuSide)
        }
        for view in notes {
            var flags = Self.flags(view.ref.path)
            // In the inbox, being in it goes without saying: its check says so.
            if kind == .inbox { flags.remove(.inbox) }
            guard !flags.isEmpty else {
                badges[view.ref]?.removeFromSuperview()
                badges[view.ref] = nil
                continue
            }
            let badge = badges[view.ref] ?? {
                let badge = NoteBadges()
                document.addSubview(badge)
                badges[view.ref] = badge
                return badge
            }()
            badge.flags = flags
            badge.size = round(metrics.fontSize * 0.8)
            let column = min(metrics.columnWidth, view.frame.width - 48)
            let right = view.frame.minX + ((view.frame.width - column) / 2).rounded() + column - 4 - (listsNotes ? menuSide : 0)
                - (openButtons[view.ref] != nil ? menuSide : 0)
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: right - size.width, y: round(nameMiddle(of: view) - size.height / 2), width: size.width, height: size.height)
        }
    }

    // MARK: The timeline

    /// Every day and week there is a note for, in order: the timeline the
    /// column shows a window on.
    private var entries: [NoteRef] = []
    /// The entries shown: some fifty about where the reader is, slid along
    /// as they scroll to either end — so the column, and its scrubber, hold
    /// about as much wherever in time they are.
    private(set) var shown: Range<Int> = 0..<0
    private static let span = 48
    private static let step = 24

    /// Shows the timeline, the window on it about a note.
    func showTimeline(_ entries: [NoteRef], around ref: NoteRef) {
        self.entries = entries
        let center = entries.firstIndex(of: ref) ?? entries.count - 1
        let low = max(0, min(center - Self.span / 2, entries.count - Self.span))
        shown = low..<min(entries.count, low + Self.span)
        if kind != .timeline { removeBlocks() }
        kind = .timeline
        settled = false
        setBlocks(entries[shown])
    }

    /// The timeline as it now is — a day written in elsewhere, a week
    /// begun — the window kept on the same days.
    func updateTimeline(_ entries: [NoteRef]) {
        guard isTimeline, !shown.isEmpty else { return }
        let first = self.entries[shown.lowerBound], last = self.entries[shown.upperBound - 1]
        self.entries = entries
        let low = entries.firstIndex(of: first) ?? entries.firstIndex { $0 == last } ?? 0
        let high = (entries.firstIndex(of: last) ?? entries.count - 1) + 1
        shown = low..<max(low, high)
        setBlocks(entries[shown])
    }

    /// Whether a note is among those shown.
    func shows(_ ref: NoteRef) -> Bool { isTimeline && entries[shown].contains(ref) }

    /// Moves the window a step along, earlier or later: notes added at that
    /// end, and as many taken off the other, out of sight.
    private func slide(earlier: Bool) {
        var low = shown.lowerBound, high = shown.upperBound
        if earlier {
            low = max(0, low - Self.step)
            high = min(high, low + Self.span + Self.step)
        } else {
            high = min(entries.count, high + Self.step)
            low = max(low, high - Self.span - Self.step)
        }
        guard low..<high != shown else { return }
        shown = low..<high
        setBlocks(entries[shown])
    }

    /// The timeline's notes in place of those shown: those still shown kept
    /// as they are, the others made, or written and let go.
    private func setBlocks(_ refs: ArraySlice<NoteRef>) {
        var existing = notesShown()
        for block in blocks where !(block is DayView || block is NoteCardBlock) { block.removeFromSuperview() }
        blocks = refs.map { ref -> ColumnBlock in
            if let gap = ref.gap { return makeGap(gap) }
            return reuse(ref, from: &existing)
        }
        existing.values.forEach(letGo)
        relayout()
    }

    // MARK: Cards

    /// The notes shown, each whole or as a card, by note.
    private func notesShown() -> [NoteRef: ColumnBlock] {
        var shown: [NoteRef: ColumnBlock] = [:]
        for block in blocks {
            if let view = block as? DayView { shown[view.ref] = view } else if let card = block as? NoteCardBlock { shown[card.ref] = card }
        }
        return shown
    }

    /// A note's block among those shown, when it shows as asked; else made.
    private func reuse(_ ref: NoteRef, from existing: inout [NoteRef: ColumnBlock]) -> ColumnBlock {
        let mode = CardModes.mode(ref.path)
        if let block = existing[ref], (block as? NoteCardBlock)?.mode ?? .full == mode {
            existing[ref] = nil
            return block
        }
        return makeBlock(ref)
    }

    /// A note among many: whole, or — asked for — its card short or closed.
    private func makeBlock(_ ref: NoteRef) -> ColumnBlock {
        let mode = CardModes.mode(ref.path)
        guard mode == .summary || mode == .collapsed else { return makeView(ref) }
        let name = Self.name(of: ref).title
        let card = NoteCardBlock(ref: ref, mode: mode, name: name, when: Self.when(of: ref), source: graph.read(path: ref.path) ?? "",
                                 metrics: metrics, images: images)
        card.onOpen = { [weak self] newColumn in
            guard let self else { return }
            onOpenAlone?(ref, self, newColumn)
        }
        card.onResize = { [weak self] in self?.setNeedsRelayout() }
        document.addSubview(card)
        return card
    }

    /// When a note is, on its card: a day by how far off it is, any other
    /// note by when it last changed.
    static func when(of ref: NoteRef) -> String? {
        if let day = ref.day {
            let today = Day.today
            switch day {
            case today: return "Today"
            case today.adding(-1): return "Yesterday"
            case today.adding(1): return "Tomorrow"
            default:
                guard let a = today.date, let b = day.date else { return nil }
                return CardSurface.distance(days: Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0)
            }
        }
        return modified(ref.path).map { CardSurface.ago($0) }
    }

    /// When a note last changed: the graph's index's.
    static var modified: (String) -> Date? = { _ in nil }

    private func letGo(_ block: ColumnBlock) {
        if let view = block as? DayView { letGo(view) } else { block.removeFromSuperview() }
    }

    /// A note's card asked to show it otherwise: shown so, where it is listed.
    @objc private func cardModeChanged(_ notification: Notification) {
        guard listsNotes, let path = notification.object as? String,
              blocks.contains(where: { ($0 as? DayView)?.ref.path == path || ($0 as? NoteCardBlock)?.ref.path == path }) else { return }
        if isTimeline {
            setBlocks(entries[shown])
        } else if kind == .inbox {
            showInbox(blocks.compactMap { ($0 as? DayView)?.ref ?? ($0 as? NoteCardBlock)?.ref })
        }
    }

    /// Shows a note on its own.
    func showNote(_ ref: NoteRef) {
        removeBlocks()
        backlinks = nil
        blocks = [makeView(ref)]
        kind = .note(ref)
        settled = false
        relayout()
        scroll(toY: 0, animated: false)
    }

    /// Shows what links to a note: `sources` nil while they are looked for.
    func showBacklinks(of ref: NoteRef, name: String, sources: [BacklinkSource]?,
                       names: (String) -> (title: String, detail: String?)) {
        let top = scroll.contentView.bounds.minY
        let same = kind == .backlinks(ref)
        removeBlocks()
        kind = .backlinks(ref)
        let header = BacklinksHeader(note: name, count: sources?.count, metrics: metrics)
        header.onOpen = { [weak self] newColumn in
            guard let self else { return }
            onOpenPath?(ref.path, self, newColumn)
        }
        let blocks: [ColumnBlock] = [header] + backlinkBlocks(to: ref, sources ?? [], names: names)
        self.blocks = blocks
        blocks.forEach(document.addSubview)
        relayout()
        // Looked for again, the column stays where it was read to.
        if sources != nil, let offset = pendingOffset {
            pendingOffset = nil
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(offset, document.frame.height - scroll.contentSize.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else {
            scroll(toY: same ? top + 12 : 0, animated: false)
        }
    }

    /// A block for each note linking to a note: its name, and the links,
    /// folded away when they were left so.
    private func backlinkBlocks(to ref: NoteRef, _ sources: [BacklinkSource],
                                names: (String) -> (title: String, detail: String?)) -> [ColumnBlock] {
        let root = graph.root
        return sources.map { source in
            let name = names(source.path)
            let text = graph.read(path: source.path) ?? ""
            let slices = TaskSlice.slices(holding: source.contexts.map(\.link), path: source.path, in: text)
            let block = BacklinkBlock(path: source.path, slices: slices, editable: OutlineMarkdown.roundTrips(text),
                                      name: name.title, detail: name.detail,
                                      folded: SessionState.shared.backlinkFolded(root, to: ref.path, from: source.path),
                                      metrics: metrics, face: face, images: images, navigator: self)
            for editor in block.editors {
                editor.onEdit = { [weak self] editor in
                    guard let self else { return }
                    onSliceEdit?(editor, self)
                }
                editor.onResize = { [weak self] in self?.relayout() }
                editor.view.onRestyle = { [weak self] in self?.relayout() }
                editor.onLeave = { [weak self] in
                    guard let self else { return }
                    onSliceLeave?(self)
                }
            }
            block.onFold = { [weak self] folded in
                SessionState.shared.setBacklinkFolded(root, to: ref.path, from: source.path, folded)
                self?.relayout()
            }
            block.onOpen = { [weak self] newColumn in
                guard let self else { return }
                onOpenPath?(source.path, self, newColumn)
            }
            return block
        }
    }

    /// A topic note's backlinks, under it in its column: what it is, it is
    /// by what links to it. Nil takes them away.
    func showInlineBacklinks(_ sources: [BacklinkSource]?, names: (String) -> (title: String, detail: String?)) {
        guard case .note(let ref) = kind, let note = blocks.first as? DayView else { return }
        for block in blocks.dropFirst() { block.removeFromSuperview() }
        var blocks: [ColumnBlock] = [note]
        if let sources {
            let head = InlineBacklinksHeader(count: sources.count, metrics: metrics)
            blocks += [head] + backlinkBlocks(to: ref, sources, names: names)
        }
        self.blocks = blocks
        blocks.dropFirst().forEach(document.addSubview)
        relayout()
    }

    private func removeBlocks() {
        webPage?.removeFromSuperview()
        webPage = nil
        webOutline = nil
        scrubber.isHidden = false
        webTitle.isHidden = true
        grip.isHidden = false
        scroll.isHidden = false
        openButtons.values.forEach { $0.removeFromSuperview() }
        openButtons = [:]
        headerLinks.values.forEach { $0.removeFromSuperview() }
        headerLinks = [:]
        badges.values.forEach { $0.removeFromSuperview() }
        badges = [:]
        handles.values.forEach { $0.removeFromSuperview() }
        handles = [:]
        rules.forEach { $0.removeFromSuperview() }
        rules = []
        for block in blocks {
            if let view = block as? DayView { letGo(view) } else { block.removeFromSuperview() }
        }
        blocks = []
    }

    // MARK: Clicked between the cards

    override var acceptsFirstResponder: Bool { true }

    /// A click on the column's ground — between the cards, or around one —
    /// makes it the column worked in: the keyboard to it, unless it is in
    /// it already, where the caret stays. (A click in a card's text puts the
    /// caret there first, which says as much.)
    @objc private func groundClicked(_ gesture: NSClickGestureRecognizer) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { return }
        window?.makeFirstResponder(self)
    }

    func view(for ref: NoteRef) -> DayView? { views.first { $0.ref == ref } }

    /// A note shown here, shown no more: written, and told of.
    private func letGo(_ view: DayView) {
        view.save()
        view.removeFromSuperview()
        onViewGone?(view)
    }

    /// A note began to be shown here: its title as it is, to tell a new one by.
    var onViewMade: ((DayView) -> Void)?
    /// A note is no longer shown here.
    var onViewGone: ((DayView) -> Void)?

    /// Told when a gap in the timeline is clicked: some of its days to show.
    var onRevealGap: ((TimelineGap) -> Void)?

    private func makeGap(_ gap: TimelineGap) -> GapView {
        let view = GapView(gap: gap, metrics: metrics)
        view.onReveal = { [weak self] gap in self?.onRevealGap?(gap) }
        document.addSubview(view)
        return view
    }

    private func makeView(_ ref: NoteRef) -> DayView {
        let view = DayView(ref: ref, graph: graph, images: images, metrics: metrics)
        // Each note a card: the cards part them, no rule between.
        view.drawsRule = false
        view.cardFill = Ink.card
        view.editor.navigator = self
        view.onHeightChange = { [weak self] _ in self?.setNeedsRelayout() }
        view.onSave = { [weak self, weak view] in
            guard let view else { return }
            self?.onSave?(view)
        }
        document.addSubview(view)
        onViewMade?(view)
        return view
    }

    func saveAll() { views.forEach { $0.save() } }
    func reloadFromDisk() {
        views.forEach { $0.reloadIfChanged() }
        relayout()
    }

    /// The notes shown that changed on disk, as they now are — a note with
    /// writing not yet saved here keeps it, and is told of the change.
    func reloadFromDisk(_ paths: Set<String>) {
        let changed = views.filter { paths.contains($0.ref.path) }
        guard !changed.isEmpty else { return }
        changed.forEach { $0.reloadIfChanged() }
        relayout()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        strip.frame = bounds
        if strip.superview == nil { addSubview(strip) }
        guard !isCollapsed else { return }
        // The top sheet: the column's notes, under the sheets beneath.
        let card = bounds
        scroll.frame = card
        // A page on the web, under the title bar's controls.
        webPage?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 44))
        if webTitle.superview == nil { addSubview(webTitle) }
        webTitle.frame = NSRect(x: 60, y: bounds.height - 30, width: max(0, bounds.width - 120), height: 18)
        fade.frame = NSRect(x: 0, y: card.maxY - 64, width: card.width, height: 64)
        scrubber.frame = NSRect(x: 4, y: 56, width: 40, height: max(0, card.height - 112))
        // It wakes only from left of the cards, not over their text.
        let column = min(metrics.columnWidth, scroll.contentSize.width - 48)
        let cardLeft = ((scroll.contentSize.width - column) / 2).rounded() - CardSurface.outset
        scrubber.wakeWidth = min(40, max(12, cardLeft - 4))
        close.frame = NSRect(x: bounds.width - 34, y: bounds.height - 34, width: 22, height: 22)
        foldButton.frame = close.frame.offsetBy(dx: -24, dy: 0)
        // What sits left of the ×: left of the fold button too, when it shows.
        let controlsLeft = foldButton.isHidden ? close.frame.minX : foldButton.frame.minX
        let bar = sheetBar.fittingSize
        // At the foot, centred: the title bar left to the sheets.
        let barX = ((bounds.width - bar.width) / 2).rounded()
        sheetBar.frame = NSRect(x: max(8, barX), y: card.minY + 14, width: bar.width, height: bar.height)
        grip.frame = NSRect(x: 56, y: bounds.height - 12, width: max(0, bounds.width - 112), height: 12)
        // The sheets beneath, bunched left of the ×, on its middle.
        let pillHeight = StackPill.fittingHeight
        let pillWidth = stackPill.fittingWidth(within: max(0, min(260, bounds.width * 0.45)))
        stackPill.frame = NSRect(x: controlsLeft - 6 - pillWidth, y: (close.frame.midY - pillHeight / 2).rounded(),
                                 width: pillWidth, height: pillHeight)
        switcher?.frame = bounds
        relayout()
    }

    private var relayoutPending = false

    private func setNeedsRelayout() {
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            relayoutPending = false
            relayout()
        }
    }

    /// The blocks laid out here already, whose frames say where they are.
    private var placed: Set<ObjectIdentifier> = []

    /// Lays the notes out one under another, the one at the top of the
    /// column kept where it is, however those above it grew or shrank.
    func relayout() {
        defer { placeHandles() }
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        let top = scroll.contentView.bounds.minY
        // Only blocks this has placed: a new one's frame says nothing yet.
        let laidOut = blocks.filter { placed.contains(ObjectIdentifier($0)) && $0.frame.height > 0 }
        let anchor = (laidOut.last { $0.frame.minY <= top } ?? laidOut.first).map { ($0, top - $0.frame.minY) }
        var y: CGFloat = isTimeline ? 24 : 40
        // The notes across the whole column: the scrubber lies over them,
        // when it is wanted.
        let inset: CGFloat = 0
        for view in blocks {
            let height = view.desiredHeight(width: width - inset)
            let frame = NSRect(x: inset, y: y, width: width - inset, height: height)
            if view.frame != frame { view.frame = frame }
            y += height
        }
        // Room for the last note to come to the top.
        y += isTimeline && shown.upperBound == entries.count ? max(120, scroll.contentSize.height - 260) : 160
        let size = NSSize(width: width, height: max(y, scroll.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
        placed = Set(blocks.map { ObjectIdentifier($0) })
        if let (view, offset) = anchor, blocks.contains(where: { $0 === view }) {
            let target = max(0, min(view.frame.minY + offset, size.height - scroll.contentSize.height))
            if abs(target - top) > 0.5 {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        refreshMarks()
    }

    private func refreshMarks() {
        // A page on the web marks its own, from its headings.
        guard !isWeb else { return }
        let marks = blocks.flatMap { block in
            block.scrubMarks(listed: listsNotes).map { mark in
                var mark = mark
                mark.y += block.frame.minY
                return mark
            }
        }
        scrubber.update(marks: marks, height: document.frame.height, visible: scroll.contentView.bounds)
        scrubber.earlier = isTimeline && shown.lowerBound > 0 ? Self.name(of: entries[shown.lowerBound - 1]).title : nil
        scrubber.later = isTimeline && shown.upperBound < entries.count ? Self.name(of: entries[shown.upperBound]).title : nil
    }

    /// Goes to the note just past the window's end, the window about it.
    private func page(earlier: Bool) {
        guard isTimeline else { return }
        let index = earlier ? shown.lowerBound - 1 : shown.upperBound
        guard entries.indices.contains(index) else { return }
        let ref = entries[index]
        showTimeline(entries, around: ref)
        reveal(ref, animated: false)
    }

    /// Notes' titles, by path: the graph's index's.
    static var titles: (String) -> String? = { _ in nil }

    /// What a note is called on the scrubber: a day's date, a week's
    /// number, any other note its title.
    static func name(of ref: NoteRef) -> (title: String, detail: String?) {
        if let gap = ref.gap { return ("⋯", GapView.describe(gap)) }
        if let day = ref.day { return (OpenQuickly.dayTitle(day), day == .today ? "Today" : nil) }
        if let week = GraphPaths.week(fromWeeklyPath: ref.path) { return ("Week \(week.week)", OpenQuickly.weekRange(week)) }
        return (titles(ref.path) ?? (ref.path as NSString).lastPathComponent, nil)
    }

    // MARK: Scrolling

    private var sliding = false
    /// Whether the column has been taken to the note it was opened at: till
    /// then, where it is scrolled to says nothing of where the reader is.
    private var settled = false

    @objc private func scrolled() {

        scrubber.update(visible: scroll.contentView.bounds)
        // Within a screen of either end, the window slides along.
        if isTimeline, settled, !sliding {
            sliding = true
            let visible = scroll.contentView.bounds
            if visible.minY < visible.height, shown.lowerBound > 0 {
                slide(earlier: true)
            } else if visible.maxY > document.frame.height - visible.height, shown.upperBound < entries.count {
                slide(earlier: false)
            }
            sliding = false
        }
        onCurrent?(self)
        // The note at the top keeps how far into it it was read — on its
        // own or among the days — to open there again, wherever it is opened.
        if settled, let view = current {
            SessionState.shared.setOffset(graph.root, view.ref, Double(scroll.contentView.bounds.minY - view.frame.minY))
        }
        onScroll?(self)
    }

    /// The note at the top of the column.
    var current: DayView? {
        let top = scroll.contentView.bounds.minY + 60
        return views.last { $0.frame.minY <= top } ?? views.first
    }

    /// Whether the note at the top has its name scrolled out of sight.
    var currentNameHidden: Bool {
        guard let current else { return false }
        return current.frame.minY + 40 < scroll.contentView.bounds.minY
    }

    func scroll(toY y: CGFloat, animated: Bool) {
        let target = NSPoint(x: 0, y: max(0, min(y - 12, document.frame.height - scroll.contentSize.height)))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scroll.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scroll.contentView.scroll(to: target)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Brings a note to the top, the keyboard in it.
    /// Where a column is: the note at its top, and how far into it.
    struct Place: Equatable {
        var ref: NoteRef
        var offset: CGFloat
    }

    var place: Place? {
        guard let current else { return nil }
        return Place(ref: current.ref, offset: scroll.contentView.bounds.minY - current.frame.minY)
    }

    /// Scrolls back to a place, when its note is shown — the keyboard put in
    /// `key`, where its caret was left, when that is shown too.
    func restore(_ place: Place, key: NoteRef? = nil) {
        relayout()
        if let view = view(for: place.ref) {
            let y = max(0, min(view.frame.minY + place.offset, document.frame.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        settled = true
        guard let key, let view = view(for: key), !view.hasConflict else { return }
        window?.makeFirstResponder(view.editor)
        if view.restoreSelection() { keepCaretInSight(view) }
    }

    /// The caret put back, in sight: scrolled to, when it is not.
    func keepCaretInSight(_ view: DayView) {
        let editor = view.editor
        guard let layout = editor.layoutManager, let container = editor.textContainer, let storage = editor.textStorage else { return }
        let location = min(editor.selectedRange().location, max(0, storage.length - 1))
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: location, length: storage.length > 0 ? 1 : 0), actualCharacterRange: nil)
        let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
        let caret = document.convert(line.offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y), from: editor)
        let visible = scroll.contentView.bounds
        let margin: CGFloat = 80
        guard caret.minY < visible.minY + margin || caret.maxY > visible.maxY - margin else { return }
        scroll(toY: max(0, caret.midY - visible.height / 3), animated: false)
    }

    /// How far down the column is scrolled.
    var scrollOffset: CGFloat { scroll.contentView.bounds.minY }

    /// What links to the note, as last shown: not shown again unchanged.
    var backlinks: [BacklinkSource]?

        /// A backlinks column's place, to go back to once its notes are found.
    var pendingOffset: CGFloat?

    func reveal(_ ref: NoteRef, animated: Bool) {
        guard let view = view(for: ref) else { return }
        relayout()
        scroll(toY: view.frame.minY, animated: animated)
        settled = true
        guard !view.hasConflict else { return }
        window?.makeFirstResponder(view.editor)
        if view.restoreSelection() { keepCaretInSight(view) } else { view.editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false) }
    }

    private func drag(to fraction: CGFloat) {
        if let webPage, let webOutline {
            webPage.scroll(toY: fraction * webOutline.height - bounds.height / 2 + 12, animated: false)
            return
        }
        let y = fraction * document.frame.height - scroll.contentSize.height / 2
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, document.frame.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func hover(_ mark: ScrubMark?, at y: CGFloat) {
        guard let mark else { tip.isHidden = true; return }
        tip.show(mark, face: face)
        let size = tip.fittingSize
        let point = convert(NSPoint(x: scrubber.frame.maxX, y: y), from: scrubber)
        tip.frame = NSRect(x: point.x + 2, y: round(point.y - size.height / 2), width: size.width, height: size.height)
        tip.isHidden = false
    }

    var scrolledForScript: String { "\(scroll.contentView.bounds.minY) of \(document.frame.height)" }

    /// Scrolls by some points, as the wheel does.
    func scrollForScript(by amount: CGFloat) {
        let y = max(0, min(scroll.contentView.bounds.minY + amount, document.frame.height - scroll.contentSize.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func hoverForScript(_ fraction: CGFloat) {
        layoutSubtreeIfNeeded()
        scrubber.reveal()
        scrubber.hover(atFraction: fraction)
    }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        guard listsNotes, let index = views.firstIndex(where: { $0.editor === view }) else {
            view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
            return
        }
        let next = index + (edge == .top ? -1 : 1)
        guard views.indices.contains(next) else { return }
        let target = views[next]
        window?.makeFirstResponder(target.editor)
        target.editor.enter(from: edge == .top ? .bottom : .top, x: x)
        if edge == .bottom {
            // Going down into a day shows its date along with its first line.
            target.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: target.editor.frame.minY + 1))
        }
    }

    func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        onOpen?(url, self, inSplit)
    }
}

/// The ticks down a column's left: a long one for each day and week, a
/// shorter one for each heading, the shortest for each topic. Those on
/// screen are darker; weeks are ochre. Hovered, a tick says what it is;
/// clicked, goes there; dragged along, scrolls.
final class Scrubber: NSView {
    var onHover: ((ScrubMark?, CGFloat) -> Void)?
    var onPick: ((ScrubMark) -> Void)?
    /// Dragged along: how far down the page, from 0 to 1.
    var onDrag: ((CGFloat) -> Void)?
    /// One of the ends was clicked: earlier, or later.
    var onPage: ((_ earlier: Bool) -> Void)?
    /// What is past each end, when anything is: shown as a chevron there.
    var earlier: String? { didSet { if earlier != oldValue { needsDisplay = true } } }
    var later: String? { didSet { if later != oldValue { needsDisplay = true } } }

    private var marks: [ScrubMark] = []
    /// Each kept mark and where on the scrubber it is.
    private var placed: [(mark: ScrubMark, y: CGFloat)] = []
    private var height: CGFloat = 1
    private var visible: NSRect = .zero
    private var hovered: Int?
    private var dragged = false

    override var isFlipped: Bool { true }

    // MARK: Shown while wanted

    /// Whether the pointer is over it.
    private var inUse = false
    /// How far in from its left edge the pointer wakes it: the room left of
    /// the cards. Out of sight, the rest of it is the cards', to click in.
    var wakeWidth: CGFloat = 40
    private var isShown: Bool { alphaValue > 0.5 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard isShown || local.x <= wakeWidth else { return nil }
        return super.hitTest(point)
    }
    private var fadeTimer: Timer?

    /// Shown only while the pointer is over it: else out of the way of the reading.
    func reveal() {
        fadeTimer?.invalidate()
        // At once, as the page moves; it fades away slowly after.
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { $0.duration = 0 }
            alphaValue = 1
        }
        guard !inUse else { return }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
    }

    private func fadeOut() {
        guard !inUse else { return }
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; animator().alphaValue = 0 }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isShown || convert(event.locationInWindow, from: nil).x <= wakeWidth else { return }
        inUse = true
        reveal()
    }

    func update(marks: [ScrubMark], height: CGFloat, visible: NSRect) {
        self.marks = marks.sorted { $0.y < $1.y }
        self.height = max(height, 1)
        self.visible = visible
        place()
    }

    func update(visible: NSRect) {
        self.visible = visible
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    /// Room at each end for its chevron.
    private static let pad: CGFloat = 18

    private func position(_ y: CGFloat) -> CGFloat {
        Self.pad + y / height * max(1, bounds.height - 2 * Self.pad)
    }

    /// Where each mark goes. With more than there is room for, the least
    /// are left out — topics, then headings — and of marks still too close
    /// to tell apart, the greater kept.
    private func place() {
        placed = []
        let room = Int(max(0, bounds.height - 2 * Self.pad) / 6)
        let least = (1...3).first { rank in marks.filter { $0.rank >= rank }.count <= room } ?? 3
        for mark in marks where mark.rank >= least {
            let y = round(position(mark.y))
            if let last = placed.last, y - last.y < 5 {
                if mark.rank > last.mark.rank || (mark.isWeek && !last.mark.isWeek) { placed[placed.count - 1] = (mark, last.y) }
                continue
            }
            placed.append((mark, y))
        }
        hovered = nil
        needsDisplay = true
    }

    /// Where the ticks start, and how long a day's is.
    private static let tickX: CGFloat = 12
    private static let dayLength: CGFloat = 20

    /// The ends' chevrons, when there is more past them: centred over the
    /// days' ticks.
    private var earlierRect: NSRect { NSRect(x: Self.tickX, y: 0, width: Self.dayLength, height: 14) }
    private var laterRect: NSRect { NSRect(x: Self.tickX, y: bounds.height - 14, width: Self.dayLength, height: 14) }

    private func drawChevron(in rect: NSRect, up: Bool, hot: Bool) {
        let path = NSBezierPath()
        let mid = rect.midX, y = rect.midY
        path.move(to: NSPoint(x: mid - 5, y: y + (up ? 2.5 : -2.5)))
        path.line(to: NSPoint(x: mid, y: y + (up ? -2.5 : 2.5)))
        path.line(to: NSPoint(x: mid + 5, y: y + (up ? 2.5 : -2.5)))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (hot ? Ink.accent : Ink.secondary).setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Over the text, a ground of the page's colour to read the ticks on.
        Ink.page.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        if earlier != nil { drawChevron(in: earlierRect, up: true, hot: hoveredEnd == true) }
        if later != nil { drawChevron(in: laterRect, up: false, hot: hoveredEnd == false) }
        let top = position(visible.minY)
        let bottom = position(visible.maxY)
        for (i, item) in placed.enumerated() {
            let length: CGFloat = item.mark.rank == 3 ? Self.dayLength : item.mark.rank == 2 ? 13 : 7
            let near = item.y >= top - 2 && item.y <= bottom + 2
            let color = i == hovered ? Ink.accent
                : item.mark.isWeek ? (near ? Ink.week : Ink.week.withAlphaComponent(0.45))
                : near ? Ink.text : Ink.faint
            color.setFill()
            let grow: CGFloat = i == hovered ? 4 : 0
            let thickness: CGFloat = item.mark.rank == 3 ? 2 : 1.5
            NSBezierPath(roundedRect: NSRect(x: Self.tickX, y: item.y - thickness / 2, width: length + grow, height: thickness),
                         xRadius: thickness / 2, yRadius: thickness / 2).fill()
        }
    }

    private func nearest(_ y: CGFloat) -> Int? {
        let best = placed.enumerated().min { abs($0.element.y - y) < abs($1.element.y - y) }
        guard let best, abs(best.element.y - y) <= 8 else { return nil }
        return best.offset
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// The end the pointer is on: true for the earlier.
    private var hoveredEnd: Bool? { didSet { if hoveredEnd != oldValue { needsDisplay = true } } }

    private func end(at point: NSPoint) -> Bool? {
        if earlier != nil, earlierRect.insetBy(dx: -4, dy: -4).contains(point) { return true }
        if later != nil, laterRect.insetBy(dx: -4, dy: -4).contains(point) { return false }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Over the cards, out of sight: theirs. From the strip left of them, woken.
        if !inUse {
            guard point.x <= wakeWidth else { return }
            inUse = true
            reveal()
        }
        hoveredEnd = end(at: point)
        if let isEarlier = hoveredEnd, let name = isEarlier ? earlier : later {
            hovered = nil
            onHover?(ScrubMark(y: 0, title: isEarlier ? "Earlier" : "Later", detail: name, rank: 3),
                     isEarlier ? earlierRect.midY : laterRect.midY)
            return
        }
        let y = point.y
        let index = nearest(y)
        if index != hovered {
            hovered = index
            needsDisplay = true
        }
        onHover?(index.map { placed[$0].mark }, index.map { placed[$0].y } ?? y)
    }

    func hover(atFraction fraction: CGFloat) {
        let y = Self.pad + fraction * (bounds.height - 2 * Self.pad)
        hovered = placed.enumerated().min { abs($0.element.y - y) < abs($1.element.y - y) }?.offset
        needsDisplay = true
        onHover?(hovered.map { placed[$0].mark }, hovered.map { placed[$0].y } ?? y)
    }

    override func mouseExited(with event: NSEvent) {
        inUse = false
        reveal()
        hovered = nil
        hoveredEnd = nil
        needsDisplay = true
        onHover?(nil, 0)
    }

    override func mouseDown(with event: NSEvent) { dragged = false }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
        let y = convert(event.locationInWindow, from: nil).y
        onDrag?(min(1, max(0, (y - Self.pad) / max(1, bounds.height - 2 * Self.pad))))
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragged else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let isEarlier = end(at: point) {
            onPage?(isEarlier)
            return
        }
        let y = point.y
        if let index = nearest(y) { onPick?(placed[index].mark) }
    }
}

/// What a hovered tick is: its words, and the day it is in.
final class ScrubTip: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 10
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            return shadow
        }()
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ mark: ScrubMark, face: Typeface) {
        let text = NSMutableAttributedString(string: mark.title, attributes: [
            .font: face.font(size: 13, weight: mark.rank == 3 ? .semibold : .regular),
            .foregroundColor: mark.isWeek ? Ink.week : Ink.text,
        ])
        if let detail = mark.detail {
            text.append(NSAttributedString(string: "  " + detail, attributes: [
                .font: face.font(size: 12), .foregroundColor: Ink.secondary,
            ]))
        }
        label.attributedStringValue = text
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Ink.paper.cgColor
            layer?.borderColor = Ink.rule.cgColor
        }
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let size = label.attributedStringValue.size()
        return NSSize(width: min(420, ceil(size.width) + 24), height: ceil(size.height) + 10)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = NSRect(x: 10, y: floor((bounds.height - size.height) / 2), width: bounds.width - 20, height: size.height)
    }
}

/// The top of a column, where the text goes under the title bar: the paper
/// fading in over it, so what is pinned there stays legible.
final class TopFade: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSGradient(colors: [Ink.page, Ink.page, Ink.page.withAlphaComponent(0)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
    }
}

/// A column's ×, or an inbox note's: faint until the pointer is on it.
final class CloseButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    private lazy var restingTint = contentTintColor ?? Ink.faint

    init(symbol: String = "xmark", pointSize: CGFloat = 10, toolTip: String = "Close Column") {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: symbol == "xmark" ? .semibold : .regular))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = symbol == "xmark" ? Ink.faint : Ink.secondary
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = Ink.text }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = restingTint }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            Ink.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Over a note's header among many: the pointer a hand, a click the note
/// alone.
final class NoteHeaderLink: NSView {
    var onClick: ((_ newColumn: Bool) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?(event.modifierFlags.contains(.command))
    }
}

/// Over a column while the pointer is in it, as Mail shows its message's
/// actions: a button for each kind of sheet that can be put on it.
final class SheetBar: NSView {
    /// In the title bar: a click here is its own, not the start of moving the window.
    override var mouseDownCanMoveWindow: Bool { false }

    enum Choice: CaseIterable {
        case timeline, backlinks, inbox, tasks, search

        var symbol: String {
            switch self {
            case .timeline: "calendar"
            case .backlinks: "link"
            case .inbox: "tray"
            case .tasks: "checkmark.circle"
            case .search: "magnifyingglass"
            }
        }

        var name: String {
            switch self {
            case .timeline: "Timeline"
            case .backlinks: "Backlinks"
            case .inbox: "Inbox"
            case .tasks: "Tasks"
            case .search: "Search"
            }
        }
    }

    var onChoose: ((Choice) -> Void)?
    var backlinksEnabled = true { didSet { buttons[Choice.allCases.firstIndex(of: .backlinks)!].isEnabled = backlinksEnabled } }
    private var buttons: [NSButton] = []
    private static let side: CGFloat = 30

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2 + 3
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        for choice in Choice.allCases {
            let button = BarButton(symbol: choice.symbol, name: choice.name)
            button.target = self
            button.action = #selector(chose(_:))
            addSubview(button)
            buttons.append(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func chose(_ sender: NSButton) {
        guard let index = buttons.firstIndex(of: sender) else { return }
        onChoose?(Choice.allCases[index])
    }

    override var fittingSize: NSSize {
        NSSize(width: CGFloat(buttons.count) * (Self.side + 4) + 8, height: Self.side + 6)
    }

    override func layout() {
        super.layout()
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: 6 + CGFloat(i) * (Self.side + 4), y: 3, width: Self.side, height: Self.side)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = Ink.rule.cgColor
            layer?.borderWidth = 1
        }
    }

    /// Clicks on the bar, between its buttons, are not the text's under it.
    override func mouseDown(with event: NSEvent) {}
}

/// One of the bar's buttons: its symbol, its name on hover.
private final class BarButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, name: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Ink.secondary
        toolTip = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; contentTintColor = Ink.text }
    override func mouseExited(with event: NSEvent) { hovering = false; contentTintColor = Ink.secondary }

    override func draw(_ dirtyRect: NSRect) {
        if hovering, isEnabled {
            Ink.hover.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        super.draw(dirtyRect)
    }
}
