import AppKit
import GraphKit
import ReflectCore

/// Prism's outline editor, for another app to edit a page's body in —
/// Markdown in, Markdown out — its queries, embeds and callouts drawn as
/// Prism draws them. It takes the height its text needs: put it in
/// something that scrolls.
@MainActor
public final class PageOutlineEditor: NSView, NSTextViewDelegate, OutlineTextViewNavigator {
    /// Told the body's Markdown as it is edited.
    public var onChange: ((String) -> Void)?
    /// Told a `[[link]]`'s title when it is followed, and any other address.
    public var onOpenTitle: ((String) -> Void)?
    public var onOpenURL: ((URL) -> Void)?
    /// Told when the height it needs changes.
    public var onHeightChange: (() -> Void)?
    /// Rows folded or unfolded: the folds now, to keep — as Prism keeps a
    /// note's, apart from its text.
    public var onFoldsChange: (([OutlineFolds.Mark]) -> Void)?
    /// Told when the caret comes into the editor, and when it leaves.
    public var onFocusChange: ((Bool) -> Void)? {
        didSet {
            let told = onFocusChange
            editor.onFirstResponderChange = { [weak self] focused in
                // Leaving: what was typed told first, as it stands.
                if !focused { self?.flushEdits() }
                told?(focused)
                self?.placeTitleChip()
            }
        }
    }

    let editor: OutlineTextView

    // MARK: Titling

    /// Whether the page has no title yet: Title is offered at the end of
    /// its first row while the caret is on it, to make that row its title.
    public var isUntitled: () -> Bool = { false }
    /// Told the title an untitled page's first row makes, as the row goes.
    public var onTitle: ((String) -> Void)?
    /// Asked to title a page with no first row to title it by — or one
    /// titled already: its title, to be typed.
    public var onAskTitle: (() -> Void)?
    /// At the end of the first row: Title.
    var titleChip: NSButton {
        if let madeChip { return madeChip }
        let made = makeTitleChip()
        madeChip = made
        return made
    }
    /// The chip, once there has been reason to show it: not made for every
    /// card, with every move of the caret, only to be hidden.
    private(set) var madeChip: NSButton?
    /// Whether Title is offered at the end of an untitled page's first row;
    /// else it is titled by the app's own command alone.
    public var offersTitleChip = true
    /// Title offered quietly: once the first row is written — the caret
    /// gone on below it — small and grey, and only while `offersTitle`
    /// says so; not while the first row is being typed.
    public var quietTitleChip = false {
        didSet { madeChip.map(styleTitleChip) }
    }
    /// Whether Title may be offered now: a page made a moment ago, say.
    public var offersTitle: () -> Bool = { true }
    /// A first row typed as a heading — `# ` — then Return: that row made
    /// the title, while Title would be offered.
    public var titlesByHeading = false
    /// What the editor does not show — a body's trailing gap — kept as it was.
    private var shell = Outline(rows: [])
    public private(set) var text = ""
    private let undo = UndoManager()

    /// Whether a body can be edited as an outline and written back as it
    /// was: what Prism would show read-only cannot.
    nonisolated public static func canEdit(_ text: String) -> Bool {
        !text.contains(OutlineText.lineSeparator) && OutlineMarkdown.serialize(OutlineMarkdown.parse(text)) == text
    }

    /// Where a top-level row's words start, in from the editor's edge: for
    /// what is drawn in line with them, such as a placeholder.
    public static func textIndent(fontSize: CGFloat = 15) -> CGFloat {
        OutlineMetrics(fontSize: fontSize).textIndent(for: .blank)
    }

    /// How big a row's checkbox is drawn — a ring, a box — at a size of
    /// type: for marks drawn beside the editor to be the same.
    public static func markSize(fontSize: CGFloat = 15) -> CGFloat {
        (OutlineMetrics(fontSize: fontSize).body.pointSize * 0.95).rounded()
    }

    /// The colour a row's open checkbox is drawn in: for marks drawn
    /// beside the editor to be the same.
    public static var markColor: NSColor { OutlineMetrics(fontSize: 15).typography.ink.secondary }

    /// Whether nothing is written in it, as it is now — not as last told.
    public var isEmpty: Bool { (editor.textStorage?.length ?? 0) == 0 }
    /// Told at once when it comes to have words in it, or none: for a
    /// placeholder over it, which what is told a moment later would leave
    /// over the first letters typed.
    public var onEmptinessChange: ((Bool) -> Void)?
    private var toldEmpty: Bool?

    /// Words its spelling takes as written — the graph's own, its pages'
    /// names — not underlined, nor corrected to others.
    public func acceptSpelling(of words: [String]) {
        NSSpellChecker.shared.setIgnoredWords(words, inSpellDocumentWithTag: editor.spellCheckerDocumentTag)
    }

    /// An untitled page that is a thing to do — done or not: its ring drawn
    /// as its first row's mark, that row's own checkbox or bullet not shown.
    /// Clicked, `onLeadMark` is told.
    public var leadMark: Bool? {
        get { editor.leadMark }
        set { editor.leadMark = newValue }
    }
    public var onLeadMark: (() -> Void)? {
        get { editor.onLeadMark }
        set { editor.onLeadMark = newValue }
    }

    /// Told on a second Escape — rows selected by the first: out of the
    /// outline, as its host has it. Unset, back to the row's text.
    public var onEscapeFromRows: (() -> Void)? {
        get { editor.onEscapeFromRows }
        set { editor.onEscapeFromRows = newValue }
    }

    /// Whether its first row's gutter is the host's — a card's handle in
    /// it: that row, with no mark of its own, shows no ghost of one there,
    /// under the pointer or the caret.
    public var leadGutterTaken: Bool {
        get { editor.leadGutterTaken }
        set { editor.leadGutterTaken = newValue }
    }

    /// The middle of its first line's capitals, down from its top: what
    /// stands beside that line — a chevron, controls — centred on it.
    public var firstLineMiddle: CGFloat? {
        guard let middle = editor.firstLineMiddle else { return nil }
        let point = convert(NSPoint(x: 0, y: middle), from: editor)
        return isFlipped ? point.y : bounds.height - point.y
    }

    /// The notes `[[` completes from, for every outline editor.
    public static func completeLinks(from index: NoteIndex) {
        LinkCompletion.sources = SearchSources(index: index)
    }

    /// Where a `[[link]]`'s card finds the note it is to, for every outline
    /// editor: its file in the graph, and what it says — nil, a note not
    /// written yet. Unset, every link's card says there is no such note.
    public static func findNotes(_ find: @escaping @MainActor (String) -> (path: String, source: String)?) {
        LinkCard.noteSource = { title in find(title).map { (NoteRef(path: $0.path), $0.source) } }
    }

    /// What an untitled page is shown as, by its made-up name: what it
    /// begins with, for every outline editor's links to it.
    public static func nameUntitled(_ find: @escaping @MainActor (String) -> String?) {
        LinkPill.untitledName = find
    }

    /// A link's target's own icon, by its name — shown in its pill instead
    /// of its kind's — for every outline editor's links.
    public static func iconTargets(_ find: @escaping @MainActor (String) -> String?) {
        LinkPill.targetIcon = find
    }

    /// Where what is kept of how notes are shown — a picture's size, a PDF's
    /// page, a carousel's place — is kept: the app's own folder in
    /// Application Support, each app's apart. Said before any editor is made;
    /// `taking`, a folder whose state is taken, the first time, as it was.
    public static func keepState(in folder: String, taking earlier: String? = nil) {
        SessionState.folder = folder
        guard let earlier else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let mine = support.appendingPathComponent(folder).appendingPathComponent("State.json")
        let theirs = support.appendingPathComponent(earlier).appendingPathComponent("State.json")
        guard !FileManager.default.fileExists(atPath: mine.path), FileManager.default.fileExists(atPath: theirs.path) else { return }
        try? FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: theirs, to: mine)
    }

    /// What is kept written now, not a moment later: as the app quits.
    public static func saveState() { SessionState.shared.writeNow() }

    /// Each graph's pictures, read and fetched once for every editor of it.
    private static var pictureStores: [URL: ImageStore] = [:]

    private static func pictures(of root: URL) -> ImageStore {
        let key = root.standardizedFileURL
        if let known = pictureStores[key] { return known }
        let made = ImageStore(root: root)
        pictureStores[key] = made
        return made
    }

    /// The day the page is, if it is one: today's time blocks show the time
    /// now, and a task on it is not offered Do Today.
    public var day: Day? {
        get { editor.day }
        set { if editor.day != newValue { editor.day = newValue } }
    }

    /// Whether the page is private: its links are not looked up on the web.
    public var isPrivate: Bool {
        get { editor.isPrivateNote }
        set { editor.isPrivateNote = newValue }
    }

    /// A task moved to a day — Do Today, Later — told the rows and the day,
    /// to put at the top of that day's page, undone with the move. Unset,
    /// a task's menu has neither.
    public var onMoveToDay: ((_ rows: [Row], _ day: Day, _ undo: UndoManager?) -> Void)? {
        didSet {
            guard let onMoveToDay else { editor.onMoveRowsTo = nil; return }
            editor.onMoveRowsTo = { [weak self] editor, index, path in
                guard let day = GraphPaths.day(fromDailyPath: path) else { return }
                let name = day == .today ? "Today" : day == Day.today.adding(1) ? "Tomorrow" : self?.dayName(day) ?? day.description
                editor.moveRows(at: index, named: name) { rows, undo in onMoveToDay(rows, day, undo) }
            }
        }
    }

    /// What a day is called, in an undo's name: a later one's.
    public var dayName: (Day) -> String = { $0.description }

    /// `root`: the graph's folder, where its pictures are. `serif`: set in
    /// Apple's New York, not the system's face.
    public init(text: String, fontSize: CGFloat = 15, serif: Bool = false, root: URL? = nil) {
        editor = OutlineTextView(metrics: OutlineMetrics(fontSize: fontSize, serif: serif))
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        editor.delegate = self
        editor.navigator = self
        if let root { editor.images = Self.pictures(of: root) }
        editor.onPicturesChanged = { [weak self] in self?.heightChanged() }
        addSubview(editor)
        // Its rows' buttons in itself: the column it is in may be another
        // app's, whose document passes no clicks to views put in it.
        editor.rowButtonsHost = self
        // `# ` on the first row, then Return: that row the title.
        editor.onReturnInRow = { [weak self] index in self?.titleByHeading(at: index) ?? false }
        load(text)
        NotificationCenter.default.addObserver(self, selector: #selector(storageEdited), name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    // MARK: Scrolling

    /// Where the pointer is, as the editor follows it, is worked out from
    /// what of it is in view; scrolled by a column it is not the document
    /// of — another app's, with many of these in it — that is not worked
    /// out again: what is under the pointer, a picture's grip, the cursor,
    /// would be told only of part of it. Told again as the column scrolls.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        scrolled()
    }

    private var scrollObserver: NSObjectProtocol?
    private var trackingStale = false

    /// The editor's tracking worked out again, once a turn however much it scrolled.
    private func scrolled() {
        guard !trackingStale else { return }
        trackingStale = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            trackingStale = false
            editor.updateTrackingAreas()
            window?.invalidateCursorRects(for: editor)
        }
    }

    /// Shows a body, forgetting what was edited before — unless it is what
    /// is shown — its rows folded as `folds` say.
    public func load(_ text: String, folds: [OutlineFolds.Mark] = []) {
        guard !text.isSameText(as: self.text) || editor.textStorage?.length == 0 else { return }
        // Another body: what was typed in this one, not yet told, goes with it.
        flushing?.cancel()
        editsPending = false
        self.text = text
        var outline = OutlineMarkdown.parse(text)
        let rows = outline.rows
        outline.rows = []
        shell = outline
        editor.load(rows.isEmpty ? [.blank] : folds.isEmpty ? rows : OutlineFolds.apply(folds, to: rows))
        shownFolds = OutlineFolds.marks(editor.fullRows)
        heightChanged()
    }

    /// The folds as last told.
    private var shownFolds: [OutlineFolds.Mark] = []

    /// Its rows folded as `folds` say, the words left as they are: folded
    /// elsewhere — in another window, on another device.
    public func refold(_ folds: [OutlineFolds.Mark]) {
        guard folds != shownFolds else { return }
        editor.load(OutlineFolds.apply(folds, to: Row.unfold(editor.fullRows)))
        shownFolds = OutlineFolds.marks(editor.fullRows)
        heightChanged()
    }

    /// The graph the page is in, and its title: queries are asked of it —
    /// again, `refreshing`, when the graph changed.
    public func setGraph(_ pages: PageIndex?, title: String, refreshing: Bool = false) {
        let graph = pages.map { OutlineGraph(pages: $0, title: title) }
        guard refreshing || graph?.pages !== editor.graph?.pages || graph?.title != editor.graph?.title else { return }
        editor.graph = graph
    }

    /// The caret put in, at the end.
    public func focus() {
        window?.makeFirstResponder(editor)
        editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false)
    }

    /// Whether the caret is in it.
    public var isFocused: Bool { window?.firstResponder === editor }

    /// Whether it takes Prism's editor shortcuts — its Format, Outline and
    /// Selection menus' — itself while the caret is in it: for an app
    /// without those menus, and before its own that share a key.
    public var takesEditorKeys = false

    /// The editor menus' items that have a key.
    private static let editorKeys: [NSMenuItem] = {
        func items(_ item: NSMenuItem) -> [NSMenuItem] { [item] + (item.submenu?.items.flatMap(items) ?? []) }
        return [EditorMenus.selection(), EditorMenus.format(), EditorMenus.outline()].flatMap(items)
            .filter { $0.action != nil && !$0.keyEquivalent.isEmpty }
    }()

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard takesEditorKeys, isFocused, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // The key as the menus name it: an arrow as its function key, else
        // what it types unshifted — ⌘⇧8's 8, not its *.
        let typed = event.charactersIgnoringModifiers ?? ""
        let isFunction = typed.unicodeScalars.first.map { (0xF700...0xF8FF).contains($0.value) } ?? false
        let key = isFunction ? typed : event.characters(byApplyingModifiers: [])?.lowercased()
        if let item = Self.editorKeys.first(where: { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers }),
           let action = item.action {
            return NSApp.sendAction(action, to: editor, from: item)
        }
        return super.performKeyEquivalent(with: event)
    }

    /// The caret taken out.
    public func unfocus() {
        if isFocused { window?.makeFirstResponder(nil) }
    }

    // MARK: Size

    /// Room before its text, left empty — out in the column it is in, the
    /// margin before its rows: their ⋯ and Move to… shown there, on a task
    /// under the pointer, not over its checkbox. A click on nothing there
    /// goes to what is under it.
    public var leadingRoom: CGFloat = 0 {
        didSet { if leadingRoom != oldValue { needsLayout = true; heightChanged() } }
    }

    private func textWidth(_ width: CGFloat) -> CGFloat { max(1, width - leadingRoom) }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self && leadingRoom > 0 ? nil : hit
    }

    /// The height its text takes at a width.
    public func height(forWidth width: CGFloat) -> CGFloat {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return 0 }
        let width = textWidth(width)
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if layout.extraLineFragmentTextContainer != nil { height -= layout.extraLineFragmentRect.height }
        // Asked of another width than it has — SwiftUI asking its ideal
        // size — the text laid out again at its own: else it is drawn
        // wrapped as it was asked, taller or shorter than its frame.
        if bounds.width > 0, abs(textWidth(bounds.width) - width) > 0.5 {
            container.size = NSSize(width: textWidth(bounds.width), height: .greatestFiniteMagnitude)
        }
        return ceil(max(height, editor.metrics.fontSize * 1.4))
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width > 0 ? bounds.width : 600))
    }

    public override func layout() {
        super.layout()
        let height = height(forWidth: bounds.width)
        editor.frame = NSRect(x: leadingRoom, y: 0, width: textWidth(bounds.width), height: height)
        if abs(height - bounds.height) > 0.5 { checkHeight() }
        placeTitleChip()
    }

    private func heightChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        onHeightChange?()
    }

    /// Whatever changed the words or how they look — words dictated and
    /// not yet taken, put in by the system without an edit told; a row
    /// restyled — the height looked at again, once it is done.
    @objc private func storageEdited() { checkHeight() }

    private var checking = false
    /// The height last asked for that was not yet given.
    private var asked: CGFloat = -1

    /// The height told again when the words no longer fit what was given
    /// them — once for each height, should it not be given.
    private func checkHeight() {
        guard !checking else { return }
        checking = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            checking = false
            guard bounds.width > 0 else { return }
            let height = height(forWidth: bounds.width)
            guard abs(height - bounds.height) > 0.5 else {
                asked = -1
                return
            }
            guard height != asked else { return }
            asked = height
            heightChanged()
        }
    }

    // MARK: NSTextViewDelegate

    public func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range: NSRange) -> Int {
        LinkPill.spellingState(value, in: range, of: textView)
    }

    public func textViewDidChangeSelection(_ notification: Notification) { placeTitleChip() }

    public func textDidChange(_ notification: Notification) {
        defer { placeTitleChip() }
        let empty = isEmpty
        if empty != toldEmpty {
            toldEmpty = empty
            onEmptinessChange?(empty)
        }
        heightChanged()
        // Written back as Markdown a moment after the typing stops — the
        // whole body each time, and all that hears of it — not for each key.
        editsPending = true
        flushing?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushEdits() }
        flushing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }

    /// How long after the last key what was typed is told.
    static let flushDelay: TimeInterval = 0.15
    private var editsPending = false
    private var flushing: DispatchWorkItem?
    private var terminating: NSObjectProtocol?

    /// What was typed and not yet told, told now: the body's Markdown, and
    /// its folds. Done on its own a moment after typing stops, as the caret
    /// leaves, and before the app quits.
    public func flushEdits() {
        flushing?.cancel()
        flushing = nil
        guard editsPending else { return }
        editsPending = false
        var outline = shell
        outline.rows = editor.fullRows
        text = outline.isBlank ? "" : OutlineMarkdown.serialize(outline)
        onChange?(text)
        // Folding is an edit to the text on screen, if not to the page.
        let folds = OutlineFolds.marks(editor.fullRows)
        if folds != shownFolds {
            shownFolds = folds
            onFoldsChange?(folds)
        }
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Taken away: nothing typed left untold.
        if newWindow == nil { flushEdits() }
        super.viewWillMove(toWindow: newWindow)
        if terminating == nil {
            terminating = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushEdits() }
            }
        }
    }

    public func undoManager(for view: NSTextView) -> UndoManager? { undo }

    // MARK: OutlineTextViewNavigator

    /// ↑ on its first line, ↓ on its last: to its start, or its end, as Prism's.
    package func outlineView(_ view: OutlineTextView, leaveThrough edge: OutlineTextView.Edge, x: CGFloat) {
        view.enter(from: edge, x: edge == .top ? 0 : .greatestFiniteMagnitude)
    }

    package func outlineView(_ view: OutlineTextView, open url: URL, inSplit: Bool) {
        if let title = url.wikiTarget { onOpenTitle?(title) } else { onOpenURL?(url) }
    }
}
