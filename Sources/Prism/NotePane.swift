import AppKit
import ReflectCore
import ReflectUI
import PrismCore

/// A note, where it is read and written: under its bar — back and
/// forward, its name, what links to it, its menu — the note, then what
/// links to it. A day's note has its week over it, and two faces: the
/// note as written, or its hours, its time blocks down them.
final class NotePane: NSView, OutlineTextViewNavigator {
    let session: Session
    private(set) var history: PaneHistory
    var place: PanePlace { history.current }
    var ref: NoteRef { place.ref }

    /// Clicked or typed in: the pane worked in.
    var onActivate: ((NotePane) -> Void)?
    /// Somewhere else, or another face: the window's list and state caught up.
    var onMoved: ((NotePane) -> Void)?
    /// A link followed, or a note named: `beside`, in the other pane.
    var onOpenURL: ((URL, NotePane, _ beside: Bool) -> Void)?
    var onOpenPath: ((String, NotePane, _ beside: Bool) -> Void)?
    /// Its × clicked: closed, the other pane left.
    var onClose: ((NotePane) -> Void)?
    /// The week strip's calendar clicked: the days, in the list.
    var onShowDays: (() -> Void)?

    private let bar = PaneBar()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var weekStrip: WeekStrip?
    private var blocks: [ColumnBlock] = []
    private(set) var note: DayView?
    /// The hours, for a day's schedule.
    private var schedule: TimeBlocksPage?
    private var linkedHeader: InlineBacklinksHeader?
    private var linked: [BacklinkBlock] = []
    /// What links here, as last shown: not shown again unchanged.
    private var shownSources: [BacklinkSource]?
    /// What links here changed while typed in there: shown once the keyboard leaves.
    private var linkedStale = false

    override var isFlipped: Bool { true }

    var isActive = false { didSet { bar.isActive = isActive } }
    /// Whether a day has its week over it: not when the days are in the list beside.
    var showsWeek = true {
        didSet {
            guard showsWeek != oldValue else { return }
            weekStrip?.isHidden = !showsWeek
            needsLayout = true
        }
    }
    /// Beside another pane, on its right: a rule between them.
    var ruledLeft = false { didSet { leftRule.isHidden = !ruledLeft } }
    private let leftRule = RuleView()
    var closable = false { didSet { bar.closable = closable } }

    init(session: Session, place: PanePlace) {
        self.session = session
        history = PaneHistory(place)
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
        addSubview(scroll)
        addSubview(bar)
        leftRule.isHidden = true
        addSubview(leftRule)
        bar.onBack = { [weak self] in self?.goBack() }
        bar.onForward = { [weak self] in self?.goForward() }
        bar.onFace = { [weak self] face in self?.setFace(face) }
        bar.onLinked = { [weak self] in self?.scrollToLinked() }
        bar.onMenu = { [weak self] button in self?.showMenu(from: button) }
        bar.onClose = { [weak self] in
            guard let self else { return }
            onClose?(self)
        }
        bar.onTitle = { [weak self] in self?.scroll(toY: 0, animated: true) }
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Where it is

    /// Somewhere new, with a way back.
    func go(_ place: PanePlace) {
        guard place != history.current else { return focusNote() }
        saveScroll()
        history.go(place)
        show()
        onMoved?(self)
    }

    /// Where it is changed in place — another day of the week, another face — no way back to it.
    func replace(_ place: PanePlace) {
        guard place != history.current else { return }
        saveScroll()
        history.replace(place)
        show()
        onMoved?(self)
    }

    func goBack() {
        saveScroll()
        guard history.goBack() != nil else { return NSSound.beep() }
        show()
        onMoved?(self)
    }

    func goForward() {
        saveScroll()
        guard history.goForward() != nil else { return NSSound.beep() }
        show()
        onMoved?(self)
    }

    /// A day's face: its note, or its hours.
    func setFace(_ face: DayFace) {
        guard ref.day != nil else { return }
        replace(PanePlace(path: place.path, face: face))
    }

    /// A day before or after, in place.
    func stepDay(_ by: Int) {
        guard let day = ref.day ?? GraphPaths.week(fromWeeklyPath: place.path)?.monday else { return NSSound.beep() }
        replace(PanePlace(.day(day.adding(by)), face: place.face))
    }

    /// History put back as it was left.
    func restore(_ history: PaneHistory) {
        self.history = history
        show()
    }

    // MARK: Shown

    private func show() {
        let ref = ref
        let face = ref.day != nil ? place.face : .outline
        // The note kept when it is the one shown still.
        if let note, note.ref != ref || face == .schedule { letGo(note) }
        blocks.forEach { if !($0 is DayView) { $0.removeFromSuperview() } }
        blocks = []
        linked = []
        linkedHeader = nil
        shownSources = nil
        weekStrip?.removeFromSuperview()
        weekStrip = nil
        let week = GraphPaths.week(fromWeeklyPath: ref.path)
        if let day = ref.day ?? week?.monday {
            let strip = WeekStrip(day: day, week: week, marks: NoteCalendar.marks(graph: session.graph, index: session.index), metrics: session.metrics)
            strip.onChoose = { [weak self] day in
                guard let self else { return }
                replace(PanePlace(.day(day), face: place.face))
            }
            strip.onWeek = { [weak self] week in self?.go(PanePlace(path: GraphPaths.weeklyPath(for: week))) }
            strip.onMonth = { [weak self] _ in self?.onShowDays?() }
            addSubview(strip, positioned: .below, relativeTo: bar)
            strip.isHidden = !showsWeek
            weekStrip = strip
        }
        if face == .schedule, let day = ref.day {
            let page = schedule ?? makeSchedule(day)
            schedule = page
            page.show(day)
            document.addSubview(page.block)
            blocks = [page.block]
        } else {
            let view = note ?? makeView(ref)
            view.standsAlone = ref.day != nil || week != nil
            note = view
            blocks = [view]
            showLinked(session.backlinks(to: ref.path) { [weak self] sources in
                guard let self, self.ref.path == ref.path else { return }
                self.showLinked(sources)
            })
        }
        updateBar()
        needsLayout = true
        layoutSubtreeIfNeeded()
        relayout()
        if face == .schedule {
            schedule?.scrollToWork()
        } else {
            let offset = SessionState.shared.place(session.graph.root, ref)?.offset ?? 0
            scroll(toY: CGFloat(offset), animated: false)
        }
        if isActive { focusNote() }
    }

    /// The keyboard in the note, where its caret was.
    func focusNote() {
        guard let note, window != nil else {
            if let schedule { window?.makeFirstResponder(schedule.block.grid) }
            return
        }
        window?.makeFirstResponder(note.editor)
        if !note.restoreSelection() { note.editor.enter(from: .top, x: 0, scrolling: false) }
    }

    private func makeView(_ ref: NoteRef) -> DayView {
        let view = DayView(ref: ref, graph: session.graph, images: session.images, metrics: session.metrics)
        view.drawsRule = false
        view.editor.navigator = self
        view.onHeightChange = { [weak self] _ in self?.setNeedsRelayout() }
        view.onSave = { [weak self, weak view] in
            guard let view else { return }
            self?.session.noteSaved(view)
        }
        document.addSubview(view)
        session.noteShown(view)
        return view
    }

    private func letGo(_ view: DayView) {
        view.save()
        view.removeFromSuperview()
        session.noteLeft(view)
        note = nil
    }

    private func makeSchedule(_ day: Day) -> TimeBlocksPage {
        let store = TimeBlocksPage.Store(
            flush: { [weak self] in self?.session.save() },
            read: { [weak self] path in self?.session.graph.read(path: path) },
            write: { [weak self] writes in self?.session.write(writes) },
            openNote: { [weak self] path in
                guard let self else { return }
                onOpenPath?(path, self, true)
            })
        let page = TimeBlocksPage(store: store, day: day, typography: session.face.typography())
        page.onScrollTo = { [weak self] y in self?.scroll(toY: y + 12, animated: false) }
        return page
    }

    private func updateBar() {
        let ref = ref
        let (title, detail) = Self.name(of: ref, session: session)
        bar.show(title: title, detail: detail, metrics: session.metrics)
        bar.canGoBack = history.canGoBack
        bar.canGoForward = history.canGoForward
        bar.face = ref.day != nil ? place.face : nil
        bar.linkedCount = place.face == .schedule && ref.day != nil ? nil : shownSources?.count
        needsLayout = true
    }

    /// What the bar calls a note: a day as people say it, its date beside;
    /// a week by its days; any other note its title, and how long ago.
    static func name(of ref: NoteRef, session: Session) -> (String, String?) {
        if let week = GraphPaths.week(fromWeeklyPath: ref.path) { return ("Week \(week.week)", OpenQuickly.weekRange(week)) }
        guard let day = ref.day, let date = day.date else {
            let entry = session.index.entry(ref.path)
            return (session.name(of: ref.path).title, entry.map { CardSurface.ago($0.modified) })
        }
        let today = Day.today
        func format(_ template: String) -> String {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }
        let near = (today.adding(-6)...today.adding(6)).contains(day)
        let name = day == today ? "Today" : day == today.adding(-1) ? "Yesterday" : day == today.adding(1) ? "Tomorrow"
            : format(near ? "EEEE" : day.year == today.year ? "MMMMd" : "MMMMdyyyy")
        return (name, format(day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy"))
    }

    // MARK: What links here

    private func showLinked(_ sources: [BacklinkSource]?) {
        guard place.face == .outline || ref.day == nil, let note else { return }
        if sources == shownSources, !linked.isEmpty || sources?.isEmpty != false { return }
        // Not while typed in there: once the keyboard leaves.
        if isTypingInLinked {
            linkedStale = true
            return
        }
        linked.forEach { $0.removeFromSuperview() }
        linkedHeader?.removeFromSuperview()
        linked = []
        linkedHeader = nil
        shownSources = sources
        var blocks: [ColumnBlock] = [note]
        if let sources, !sources.isEmpty {
            let header = InlineBacklinksHeader(count: sources.count, metrics: session.metrics)
            document.addSubview(header)
            linkedHeader = header
            linked = sources.map(makeLinked)
            blocks += [header] + linked
        }
        self.blocks = blocks
        updateBar()
        relayout()
    }

    private func makeLinked(_ source: BacklinkSource) -> BacklinkBlock {
        let root = session.graph.root
        let name = session.name(of: source.path)
        let text = session.graph.read(path: source.path) ?? ""
        let slices = TaskSlice.slices(holding: source.contexts.map(\.link), path: source.path, in: text)
        let block = BacklinkBlock(path: source.path, slices: slices, editable: OutlineMarkdown.roundTrips(text),
                                  name: name.title, detail: name.detail,
                                  folded: SessionState.shared.backlinkFolded(root, to: ref.path, from: source.path),
                                  metrics: session.metrics, face: session.face, images: session.images, navigator: self)
        for editor in block.editors {
            editor.onEdit = { [weak self] editor in self?.writeBack(editor) }
            editor.onResize = { [weak self] in self?.relayout() }
            editor.view.onRestyle = { [weak self] in self?.relayout() }
            editor.onLeave = { [weak self] in
                guard let self, linkedStale else { return }
                linkedStale = false
                showLinked(session.backlinks(to: ref.path) { [weak self] in self?.showLinked($0) })
            }
        }
        let target = ref.path
        block.onFold = { [weak self] folded in
            SessionState.shared.setBacklinkFolded(root, to: target, from: source.path, folded)
            self?.relayout()
        }
        block.onOpen = { [weak self] beside in
            guard let self else { return }
            onOpenPath?(source.path, self, beside)
        }
        document.addSubview(block)
        return block
    }

    private var isTypingInLinked: Bool {
        guard let editor = window?.firstResponder as? OutlineTextView else { return false }
        return linked.contains { $0.editors.contains { $0.view === editor } }
    }

    /// A place a note links here from, edited here: written back into that note.
    private func writeBack(_ editor: TaskEditor) {
        let path = editor.slice.path
        guard let source = session.graph.read(path: path) else { return }
        let rows = editor.rowsInNote
        guard let updated = editor.slice.writing(rows, into: source) else { return }
        do {
            try session.graph.write(updated, path: path)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        session.index.refresh(path)
        let delta = rows.count - editor.slice.count
        editor.slice.count = rows.count
        for other in linked.flatMap(\.editors) where other !== editor && other.slice.path == path && other.slice.start > editor.slice.start {
            other.slice.start += delta
        }
        relayout()
    }

    private func scrollToLinked() {
        guard let linkedHeader else { return }
        scroll(toY: linkedHeader.frame.minY, animated: true)
    }

    // MARK: Changes from elsewhere

    /// Notes changed on disk: those shown, as they now are.
    func notesChanged(_ paths: Set<String>) {
        if let note, paths.contains(note.ref.path) { note.reloadIfChanged() }
        if let schedule { schedule.reload() }
        showLinked(session.backlinks(to: ref.path) { [weak self] in self?.showLinked($0) })
        updateBar()
        relayout()
    }

    func tick() { schedule?.tick() }

    func typographyChanged() {
        note?.metrics = session.metrics
        schedule?.setTypography(session.face.typography())
        let sources = shownSources
        shownSources = nil
        showLinked(sources)
        updateBar()
        relayout()
    }

    func saveNotes() {
        note?.save()
        saveScroll()
    }

    func noteMoved(from old: String, to new: String) {
        history.rename(old, to: new)
        guard note?.ref.path == old else { return updateBar() }
        let selection = note?.editor.selectedRange()
        let typing = note.map { window?.firstResponder === $0.editor } ?? false
        if let note { letGo(note) }
        show()
        if let editor = note?.editor, let selection {
            if typing { window?.makeFirstResponder(editor) }
            editor.setSelectedRange(NSRange(location: min(selection.location, (editor.string as NSString).length), length: 0))
        }
        onMoved?(self)
    }

    func discard(_ path: String) {
        if note?.ref.path == path { note?.discard() }
    }

    /// A note gone to the Trash: back from it, or to today.
    func noteTrashed(_ path: String) {
        history.forget(path)
        guard place.path == path else { return updateBar() }
        note?.removeFromSuperview()
        note = nil
        if history.canGoBack {
            history.goBack()
            history.forget(path)
        } else {
            history = PaneHistory(PanePlace(.day(.today)))
        }
        show()
        onMoved?(self)
    }

    // MARK: Its menu

    private func showMenu(from button: NSView) {
        onActivate?(self)
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Note" })?.submenu?.copy() as? NSMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneBar.height)
        let stripHeight: CGFloat = weekStrip == nil || !showsWeek ? 0 : WeekStrip.height - 8
        weekStrip?.frame = NSRect(x: 0, y: bar.frame.maxY - 6, width: bounds.width, height: WeekStrip.height)
        let top = bar.frame.maxY + stripHeight
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
        leftRule.frame = NSRect(x: 0, y: 0, width: 1, height: bounds.height)
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

    /// The blocks one under another, the one at the top kept where it is.
    func relayout() {
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        var y: CGFloat = 8
        for block in blocks {
            let height = block.desiredHeight(width: width)
            let frame = NSRect(x: 0, y: y, width: width, height: height)
            if block.frame != frame { block.frame = frame }
            y += height
        }
        y += 160
        let size = NSSize(width: width, height: max(y, scroll.contentSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    func scroll(toY y: CGFloat, animated: Bool) {
        let target = NSPoint(x: 0, y: max(0, min(y, document.frame.height - scroll.contentSize.height)))
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                scroll.contentView.animator().setBoundsOrigin(target)
            }
        } else {
            scroll.contentView.scroll(to: target)
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func scrolled() {
        bar.scrolledUnder = scroll.contentView.bounds.minY > 2
    }

    private func saveScroll() {
        guard place.face == .outline || ref.day == nil else { return }
        SessionState.shared.setOffset(session.graph.root, ref, Double(scroll.contentView.bounds.minY))
    }

    /// Whether a note is shown here.
    func shows(_ ref: NoteRef) -> Bool { note?.ref == ref }

    override func mouseDown(with event: NSEvent) {
        onActivate?(self)
        super.mouseDown(with: event)
    }

    // MARK: OutlineTextViewNavigator

    func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
    }

    func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        onOpenURL?(url, self, inSplit)
    }

    // MARK: Scripts

    var scheduleForScript: TimeBlocksPage? { schedule }
}

/// A pane's bar: back and forward; its note's name — a day's date beside
/// it; for a day, its two faces; what links here; the note's menu; and,
/// beside another pane, its ×.
final class PaneBar: NSView {
    static let height: CGFloat = 46
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onFace: ((DayFace) -> Void)?
    var onLinked: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onClose: (() -> Void)?
    var onTitle: (() -> Void)?

    private let back = CloseButton(symbol: "chevron.left", pointSize: 13, toolTip: "Back (⌘[)")
    private let forward = CloseButton(symbol: "chevron.right", pointSize: 13, toolTip: "Forward (⌘])")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let faces = NSSegmentedControl(labels: ["Outline", "Schedule"], trackingMode: .selectOne, target: nil, action: nil)
    private let linked = NSButton()
    private let menuButton = CloseButton(symbol: "ellipsis", pointSize: 13, toolTip: "This Note")
    private let close = CloseButton(symbol: "xmark", pointSize: 11, toolTip: "Close This Pane (⌘W)")

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    var canGoBack = false { didSet { back.isEnabled = canGoBack } }
    var canGoForward = false { didSet { forward.isEnabled = canGoForward } }
    var isActive = false { didSet { needsDisplay = true } }
    var closable = false { didSet { close.isHidden = !closable; needsLayout = true } }
    var scrolledUnder = false { didSet { if scrolledUnder != oldValue { needsDisplay = true } } }
    /// A day's face shown; nil, not a day.
    var face: DayFace? {
        didSet {
            faces.isHidden = face == nil
            faces.selectedSegment = face == .schedule ? 1 : 0
            needsLayout = true
        }
    }
    var linkedCount: Int? {
        didSet {
            linked.isHidden = (linkedCount ?? 0) == 0
            linked.title = linkedCount.map { "\($0) linked" } ?? ""
            linked.toolTip = "What links here"
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        for (button, action) in [(back, #selector(backClicked)), (forward, #selector(forwardClicked)), (menuButton, #selector(menuClicked)),
                                 (close, #selector(closeClicked))] {
            button.contentTintColor = Ink.secondary
            button.target = self
            button.action = action
            addSubview(button)
        }
        close.isHidden = true
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        detail.textColor = Ink.secondary
        addSubview(title)
        addSubview(detail)
        faces.segmentStyle = .rounded
        faces.controlSize = .small
        faces.target = self
        faces.action = #selector(faceChosen)
        faces.isHidden = true
        faces.setToolTip("The day as written (⌥⌘O)", forSegment: 0)
        faces.setToolTip("The day's hours (⌥⌘S)", forSegment: 1)
        addSubview(faces)
        linked.isBordered = false
        linked.target = self
        linked.action = #selector(linkedClicked)
        linked.image = NSImage(systemSymbolName: "arrow.turn.up.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        linked.imagePosition = .imageLeading
        linked.contentTintColor = Ink.secondary
        linked.isHidden = true
        addSubview(linked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail when: String?, metrics: OutlineMetrics) {
        let typography = metrics.typography
        title.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: typography.headingFont(size: round(metrics.fontSize * 1.05), weight: .bold), .foregroundColor: Ink.text,
        ])
        detail.attributedStringValue = NSAttributedString(string: when ?? "", attributes: [
            .font: Typography.font(typography.bodyFamily, face: typography.bodyFace, size: round(metrics.fontSize * 0.8)),
            .foregroundColor: Ink.secondary,
        ])
        linked.attributedTitle = NSAttributedString(string: linked.title, attributes: [
            .font: Typography.font(typography.bodyFamily, face: typography.bodyFace, size: round(metrics.fontSize * 0.8)),
            .foregroundColor: Ink.secondary,
        ])
        needsLayout = true
    }

    @objc private func backClicked() { onBack?() }
    @objc private func forwardClicked() { onForward?() }
    @objc private func menuClicked() { onMenu?(menuButton) }
    @objc private func closeClicked() { onClose?() }
    @objc private func linkedClicked() { onLinked?() }
    @objc private func faceChosen() { onFace?(faces.selectedSegment == 1 ? .schedule : .outline) }

    override func layout() {
        super.layout()
        let middle = (Self.height / 2).rounded()
        back.frame = NSRect(x: 12, y: middle - 12, width: 26, height: 24)
        forward.frame = NSRect(x: back.frame.maxX + 2, y: middle - 12, width: 26, height: 24)
        var right = bounds.width - 12
        if !close.isHidden {
            close.frame = NSRect(x: right - 24, y: middle - 12, width: 24, height: 24)
            right = close.frame.minX - 4
        }
        menuButton.frame = NSRect(x: right - 26, y: middle - 12, width: 26, height: 24)
        right = menuButton.frame.minX - 6
        if !linked.isHidden {
            linked.sizeToFit()
            linked.frame = NSRect(x: right - linked.frame.width - 4, y: middle - 11, width: linked.frame.width + 4, height: 22)
            right = linked.frame.minX - 8
        }
        if !faces.isHidden {
            faces.sizeToFit()
            faces.frame.origin = NSPoint(x: right - faces.frame.width, y: (middle - faces.frame.height / 2).rounded())
            right = faces.frame.minX - 12
        }
        let left = forward.frame.maxX + 12
        let titleSize = title.intrinsicContentSize
        let detailSize = detail.intrinsicContentSize
        let room = max(0, right - left)
        let titleWidth = min(ceil(titleSize.width) + 4, room)
        title.frame = NSRect(x: left, y: (middle - titleSize.height / 2).rounded(), width: titleWidth, height: ceil(titleSize.height))
        let detailRoom = right - title.frame.maxX - 10
        // Whole, or not at all.
        detail.isHidden = detailRoom < ceil(detailSize.width) + 4
        detail.frame = NSRect(x: title.frame.maxX + 10, y: (middle - detailSize.height / 2).rounded() + 1,
                              width: max(0, min(ceil(detailSize.width) + 4, detailRoom)), height: ceil(detailSize.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        Ink.paper.setFill()
        bounds.fill()
        Ink.rule.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil); return }
        if title.frame.contains(convert(event.locationInWindow, from: nil)) { onTitle?() }
    }
}

/// A hairline, in the rule's ink.
final class RuleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Ink.rule.setFill()
        bounds.fill()
    }
}
