import AppKit
import ReflectCore

/// A note as an outline, under its name: a day of the timeline under its
/// date, or any other note under its title — unless the title is the note's
/// own first heading, which says it already.
///
/// A day with no note shows an empty row to write in, and is not a file
/// until something is written: a note is saved a moment after typing stops,
/// and an untouched day stays out of the graph.
@MainActor
final class DayView: NSView, NSTextViewDelegate {
    let ref: NoteRef
    /// The day, for a day of the timeline.
    var day: Day! { ref.day }
    let graph: Graph
    let editor: OutlineTextView
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let undo = UndoManager()

    /// Told when the view wants another height.
    var onHeightChange: ((DayView) -> Void)?

    /// The text may take more room or less: laid out again here — the
    /// editor sized to its text, even when the day's own frame stays as it
    /// is, as a note filling its pane does — and whoever placed the day told.
    /// An editor left shorter than its text draws the rest past its frame,
    /// out of the mouse's reach.
    private func heightMayHaveChanged() {
        needsLayout = true
        onHeightChange?(self)
    }
    /// Told when the note has been written to disk.
    var onSave: (() -> Void)?

    /// What is on disk, as last read or written; empty when there is no file.
    private(set) var savedText = ""
    /// The note's frontmatter and the like, which the editor does not show.
    private var shell = Outline(rows: [])
    private(set) var isDirty = false
    /// The note is gone — moved to the Trash — and is never written again.
    private(set) var isDiscarded = false
    private var saveTimer: Timer?
    /// A note the editor cannot write back as it was is shown, not edited.
    private(set) var isReadOnly = false
    /// A note carrying a sync conflict is shown as its two sides, with the
    /// choice of what to keep, instead of in the editor.
    private var conflictView: SyncConflictView?
    var hasConflict: Bool { conflictView != nil }
    /// What another app or a sync wrote while there was writing here not
    /// yet saved; saving waits on the choice between the two.
    private var parked: String?
    private var parkedNotice: ChangedOnDiskNotice?
    /// The least height to take, however little is written.
    var minimumHeight: CGFloat = 0 {
        didSet { if oldValue != minimumHeight { onHeightChange?(self) } }
    }

    static let columnWidth: CGFloat = 720
    private static let saveDelay: TimeInterval = 0.8

    override var isFlipped: Bool { true }

    convenience init(day: Day, graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.init(ref: .day(day), graph: graph, images: images, metrics: metrics)
    }

    init(ref: NoteRef, graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.ref = ref
        self.graph = graph
        editor = OutlineTextView(metrics: metrics)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        editor.delegate = self
        editor.onFocusChange = { [weak self] in self?.focusChanged() }
        editor.images = images
        editor.onPicturesChanged = { [weak self] in
            guard let self else { return }
            needsLayout = true
            heightMayHaveChanged()
        }
        editor.setAccessibilityLabel(ref.day.map { "Note for \(Self.titleFormatter.string(from: $0.date ?? Date()))" } ?? "Note")
        title.isSelectable = false
        badge.isSelectable = false
        badge.textColor = .secondaryLabelColor
        addSubview(title)
        addSubview(badge)
        addSubview(editor)
        applyMetrics()
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var metrics: OutlineMetrics {
        get { editor.metrics }
        set {
            editor.metrics = newValue
            applyMetrics()
            needsLayout = true
            heightMayHaveChanged()
        }
    }

    private func applyMetrics() {
        // In the headings' typeface, as the notes' own headings are.
        title.font = Typography.font(metrics.typography.headingFamily, face: metrics.typography.headingFace,
                                     size: round(metrics.fontSize * 1.45), weight: .bold)
        badge.font = .systemFont(ofSize: round(metrics.fontSize * 0.95), weight: .medium)
        updateTitle()
    }

    // MARK: Title

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMd")
        return formatter
    }()

    private static let titleWithYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
        return formatter
    }()

    func updateTitle() {
        guard let day = ref.day else {
            // A note's name, when its first heading does not already give it.
            let entry = NoteIndex.entry(path: ref.path, source: savedText)
            // Untitled: nothing over it — the title is typed in the note.
            let untitled = TitleRename.authoredTitle(path: ref.path, source: savedText) == nil && entry.title == "Untitled"
            title.stringValue = entry.titleIsHeading || untitled ? "" : entry.title
            var notes: [String] = []
            // A week's note: its days beside its name, this week's in the accent colour.
            let week = GraphPaths.week(fromWeeklyPath: ref.path)
            title.textColor = week == .current ? .controlAccentColor : .labelColor
            if let week {
                notes.append(OpenQuickly.weekRange(week))
                if week == .current { notes.append("This Week") }
            }
            if conflictView != nil { notes.append("Needs Review") } else if isReadOnly { notes.append("Read Only") }
            badge.stringValue = notes.joined(separator: " · ")
            badge.isHidden = notes.isEmpty
            needsLayout = true
            return
        }
        let today = Day.today
        let date = day.date ?? Date()
        title.stringValue = (day.year == today.year ? Self.titleFormatter : Self.titleWithYearFormatter).string(from: date)
        title.textColor = day == today ? .controlAccentColor : .labelColor
        var notes: [String] = []
        switch day {
        case today: notes.append("Today")
        case today.adding(-1): notes.append("Yesterday")
        case today.adding(1): notes.append("Tomorrow")
        default: break
        }
        if conflictView != nil { notes.append("Needs Review") } else if isReadOnly { notes.append("Read Only") }
        badge.stringValue = notes.joined(separator: " · ")
        badge.isHidden = notes.isEmpty
        needsLayout = true
    }

    // MARK: Layout

    private var column: NSRect {
        let width = min(metrics.columnWidth, bounds.width - 48)
        return NSRect(x: ((bounds.width - width) / 2).rounded(), y: 0, width: width, height: bounds.height)
    }

    private var headerTop: CGFloat { round(metrics.fontSize * 2.2) }
    private var headerHeight: CGFloat { ceil(title.intrinsicContentSize.height) }
    /// Where the note starts: under its name, or, for a note whose first
    /// heading is its name, straight away.
    private var editorTop: CGFloat {
        guard ref.day != nil || !title.stringValue.isEmpty || !badge.isHidden else { return round(metrics.fontSize * 1.6) }
        return headerTop + headerHeight + round(metrics.fontSize * 0.7)
    }
    private var bottomPadding: CGFloat { round(metrics.fontSize * 1.6) }

    override func layout() {
        super.layout()
        let column = column
        // A label draws its text a couple of points in from its edge.
        let textX = column.minX + metrics.indent - 2
        // Whole points, and a little over: a bold face's last figure reaches
        // past the width it is measured at.
        let size = title.intrinsicContentSize
        title.frame = NSRect(x: textX, y: headerTop, width: ceil(size.width) + 4, height: ceil(size.height))
        let badgeSize = badge.intrinsicContentSize
        badge.frame = NSRect(x: title.frame.maxX + 6, y: title.frame.maxY - ceil(badgeSize.height) - 3,
                             width: ceil(badgeSize.width) + 4, height: ceil(badgeSize.height))
        var y = editorTop
        if let focusBar {
            focusBar.frame = NSRect(x: column.minX + metrics.indent - 6, y: y, width: column.width - metrics.indent + 6, height: FocusBar.height)
            y += focusBarRoom
        }
        if let parkedNotice {
            let height = parkedNotice.height(forWidth: column.width)
            parkedNotice.frame = NSRect(x: column.minX, y: y, width: column.width, height: height)
            y += height + noticeSpacing
        }
        if let conflictView {
            conflictView.frame = NSRect(x: column.minX, y: y, width: column.width, height: conflictView.height(forWidth: column.width))
        } else {
            editor.frame = NSRect(x: column.minX, y: y, width: column.width, height: editorHeight(width: column.width))
            // Text past the day's own frame is drawn, but out of the mouse's
            // reach: whoever placed the day is told to measure it again.
            if editor.frame.maxY > bounds.height + 0.5 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, editor.frame.maxY > bounds.height + 0.5 else { return }
                    onHeightChange?(self)
                }
            }
        }
    }

    private var noticeSpacing: CGFloat { round(metrics.fontSize * 0.8) }

    // MARK: Focus

    /// The path to the row focused on, over the editor, while it is.
    private var focusBar: FocusBar?

    private func focusChanged() {
        if let focus = editor.focus {
            let bar = focusBar ?? {
                let bar = FocusBar()
                bar.onStep = { [weak self] index in
                    guard let self else { return }
                    if let index { editor.focusOn(fullRow: index) } else { editor.unfocus(nil) }
                    window?.makeFirstResponder(editor)
                }
                addSubview(bar)
                focusBar = bar
                return bar
            }()
            let name = ref.day.map(OpenQuickly.dayTitle) ?? NoteIndex.entry(path: ref.path, source: savedText).title
            bar.show(note: name, ancestors: focus.ancestors, fontSize: metrics.fontSize)
        } else {
            focusBar?.removeFromSuperview()
            focusBar = nil
        }
        heightMayHaveChanged()
    }

    /// The room the path takes over the editor, in focus.
    private var focusBarRoom: CGFloat { focusBar == nil ? 0 : FocusBar.height + round(metrics.fontSize * 0.4) }

    /// The height the text takes at a width, without the empty line a text
    /// view keeps after its last line break.
    private func editorHeight(width: CGFloat) -> CGFloat {
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if layout.extraLineFragmentTextContainer != nil {
            height -= layout.extraLineFragmentRect.height
        }
        return ceil(max(height, metrics.fontSize * 1.4))
    }

    /// The height the day wants at a width.
    func desiredHeight(width: CGFloat) -> CGFloat {
        let columnWidth = min(metrics.columnWidth, width - 48)
        var height = editorTop + bottomPadding + focusBarRoom
        if let parkedNotice { height += parkedNotice.height(forWidth: columnWidth) + noticeSpacing }
        height += conflictView?.height(forWidth: columnWidth) ?? editorHeight(width: columnWidth)
        return max(minimumHeight, height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Days are ruled apart; a note on its own needs no rule.
        guard ref.day != nil else { return }
        let column = column
        NSColor.separatorColor.setFill()
        NSRect(x: column.minX, y: 0, width: column.width, height: 1).fill()
    }

    // MARK: Reading and writing

    /// Reads the note from disk, and shows it.
    func load() {
        show(graph.read(path: ref.path) ?? "")
    }

    /// Shows a note as it stands on disk, clean.
    private func show(_ text: String) {
        savedText = text
        isDirty = false
        dropParked()
        conflictView?.removeFromSuperview()
        conflictView = nil
        if ConflictMarkers.detect(text) {
            // Markers are not an outline; the note is shown as its sides
            // until one is chosen, and never goes into the editor, whose
            // next save could lose what it did not understand.
            let view = SyncConflictView(source: text, fontSize: metrics.fontSize) { [weak self] keep in
                self?.resolveConflict(keeping: keep)
            }
            conflictView = view
            addSubview(view)
            editor.isHidden = true
            if window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        } else {
            editor.isHidden = false
            var outline = OutlineMarkdown.parse(text)
            isReadOnly = text.contains(OutlineText.lineSeparator) || OutlineMarkdown.serialize(outline) != text
            // The rows folded when the note was last on screen here.
            let rows = OutlineFolds.apply(SessionState.shared.folds(graph.root, ref), to: outline.rows)
            outline.rows = []
            shell = outline
            editor.load(rows.isEmpty ? [.blank] : rows)
            editor.isEditable = !isReadOnly
            editor.isPrivateNote = NoteIndex.entry(path: ref.path, source: text).isPrivate
        }
        updateTitle()
        needsLayout = true
    }

    /// Takes in what another app, or a sync, wrote. With writing here not
    /// yet saved, neither is written over: saving waits, and the choice is
    /// offered, as Reflect does.
    func reloadIfChanged() {
        let text = graph.read(path: ref.path) ?? ""
        guard text != savedText else { return }
        if isDirty {
            park(text)
            return
        }
        let focused = window?.firstResponder === editor
        let caret = editor.caretPosition
        show(text)
        if focused && !hasConflict { editor.restoreCaret(caret) }
        heightMayHaveChanged()
    }

    private func park(_ text: String) {
        saveTimer?.invalidate()
        saveTimer = nil
        parked = text
        guard parkedNotice == nil else { return }
        let notice = ChangedOnDiskNotice(keepMine: { [weak self] in self?.keepMine() },
                                         loadTheirs: { [weak self] in self?.loadTheirs() },
                                         fontSize: metrics.fontSize)
        parkedNotice = notice
        addSubview(notice)
        needsLayout = true
        heightMayHaveChanged()
    }

    private func dropParked() {
        parked = nil
        parkedNotice?.removeFromSuperview()
        parkedNotice = nil
    }

    /// Keep Mine: this writing goes to disk, over theirs.
    private func keepMine() {
        dropParked()
        isDirty = true
        save(overwriting: true)
        heightMayHaveChanged()
    }

    /// Load Theirs: what is on disk replaces this writing.
    private func loadTheirs() {
        guard let parked else { return }
        show(parked)
        heightMayHaveChanged()
    }

    /// Keeps one side of every conflict in the note, or both, by splicing
    /// the file's text — the markers never pass through the editor.
    private func resolveConflict(keeping keep: ConflictMarkers.Resolution) {
        let source = graph.read(path: ref.path) ?? savedText
        let resolved = ConflictMarkers.resolve(source, keeping: keep)
        do {
            try graph.write(resolved, path: ref.path)
            show(resolved)
            heightMayHaveChanged()
            onSave?()
            if !hasConflict {
                window?.makeFirstResponder(editor)
                editor.enter(from: .top, x: 0)
            }
        } catch {
            presentError(error)
        }
    }

    /// Writes the note, when there is anything new to write — and not
    /// while another version waits on a choice, nor over one that arrived
    /// unseen.
    func save(overwriting: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty, !isDiscarded, !isReadOnly, !hasConflict, parked == nil else { return }
        var outline = shell
        // In focus, the rows set aside too: the note is written whole.
        outline.rows = editor.fullRows
        let text = outline.isBlank ? "" : OutlineMarkdown.serialize(outline)
        guard text != savedText else {
            isDirty = false
            return
        }
        if text.isEmpty && !graph.exists(path: ref.path) {
            savedText = text
            isDirty = false
            return
        }
        let disk = graph.read(path: ref.path) ?? ""
        if !overwriting && disk != savedText && disk != text {
            park(disk)
            return
        }
        do {
            try graph.write(text, path: ref.path)
            savedText = text
            isDirty = false
            onSave?()
        } catch {
            presentError(error)
        }
    }

    /// Lets the note go without writing it: it has been deleted.
    func discard() {
        saveTimer?.invalidate()
        saveTimer = nil
        isDirty = false
        isDiscarded = true
    }

    // MARK: NSTextViewDelegate

    /// Where the caret is, noted as it moves while it is here — not as the
    /// note is loaded or changed from disk — so the note opens there again.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard window?.firstResponder === editor, !hasConflict else { return }
        SessionState.shared.setSelection(graph.root, ref, editor.selectedRange())
    }

    /// The caret put back where the note was left, when it was left
    /// somewhere still in it. Says whether it was.
    func restoreSelection() -> Bool {
        guard let place = SessionState.shared.place(graph.root, ref), let length = editor.textStorage?.length else { return false }
        let location = min(place.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(place.length, length - location)))
        return true
    }

    func textDidChange(_ notification: Notification) {
        // Folding is an edit to the text on screen, if not to the note.
        SessionState.shared.setFolds(graph.root, ref, OutlineFolds.marks(editor.fullRows))
        isDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        heightMayHaveChanged()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}
