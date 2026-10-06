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
package final class DayView: NSView, NSTextViewDelegate {
    package let ref: NoteRef
    /// The day, for a day of the timeline.
    package var day: Day! { ref.day }
    package let graph: Graph
    package let editor: OutlineTextView
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let undo = UndoManager()

    /// Told when the view wants another height.
    package var onHeightChange: ((DayView) -> Void)?

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
    package var onSave: (() -> Void)?

    /// What is on disk, as last read or written; empty when there is no file.
    package private(set) var savedText = ""
    /// The note's frontmatter and the like, which the editor does not show.
    private var shell = Outline(rows: [])
    package private(set) var isDirty = false
    /// The note is gone — moved to the Trash — and is never written again.
    package private(set) var isDiscarded = false
    private var saveTimer: Timer?
    /// A note the editor cannot write back as it was is shown, not edited.
    package private(set) var isReadOnly = false
    /// A note carrying a sync conflict is shown as its two sides, with the
    /// choice of what to keep, instead of in the editor.
    private var conflictView: SyncConflictView?
    package var hasConflict: Bool { conflictView != nil }
    /// What another app or a sync wrote while there was writing here not
    /// yet saved; saving waits on the choice between the two.
    /// The least height to take, however little is written.
    package var minimumHeight: CGFloat = 0 {
        didSet { if oldValue != minimumHeight { onHeightChange?(self) } }
    }

    package static let columnWidth: CGFloat = 720
    private static let saveDelay: TimeInterval = 0.8

    package override var isFlipped: Bool { true }

    package convenience init(day: Day, graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
        self.init(ref: .day(day), graph: graph, images: images, metrics: metrics)
    }

    package init(ref: NoteRef, graph: Graph, images: ImageStore, metrics: OutlineMetrics) {
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
        editor.day = ref.day
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
    package required init?(coder: NSCoder) { fatalError() }

    package var metrics: OutlineMetrics {
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
        title.font = metrics.typography.headingFont(size: round(metrics.fontSize * 1.45), weight: .bold)
        badge.font = .systemFont(ofSize: round(metrics.fontSize * 0.95), weight: .medium)
        badge.textColor = metrics.typography.ink.secondary
        // The rule over a day is drawn in the colours set.
        needsDisplay = true
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

    package func updateTitle() {
        guard let day = ref.day else {
            // A note's name, when its first heading does not already give it.
            let entry = NoteIndex.entry(path: ref.path, source: savedText)
            // Untitled: nothing over it — the title is typed in the note.
            let untitled = TitleRename.authoredTitle(path: ref.path, source: savedText) == nil && entry.title == "Untitled"
            title.stringValue = entry.titleIsHeading || untitled ? "" : entry.title
            var notes: [String] = []
            // A week's note: its days beside its name, this week's in the accent colour.
            let week = GraphPaths.week(fromWeeklyPath: ref.path)
            title.textColor = week == .current ? .controlAccentColor : metrics.typography.ink.text
            if let week {
                notes.append(OpenQuickly.weekRange(week))
                if week == .current { notes.append("This Week") }
            }
            if conflictView != nil { notes.append("Needs Review") } else if isReadOnly { notes.append("Read Only") }
            // A card says when the note last changed.
            if card != nil, week == nil, let modified = modified { notes.insert(CardSurface.ago(modified), at: 0) }
            badge.stringValue = notes.joined(separator: " · ")
            badge.isHidden = notes.isEmpty
            needsLayout = true
            return
        }
        let today = Day.today
        let date = day.date ?? Date()
        title.stringValue = (day.year == today.year ? Self.titleFormatter : Self.titleWithYearFormatter).string(from: date)
        title.textColor = day == today ? .controlAccentColor : metrics.typography.ink.text
        var notes: [String] = []
        switch day {
        case today: notes.append("Today")
        case today.adding(-1): notes.append("Yesterday")
        case today.adding(1): notes.append("Tomorrow")
        default:
            // A card says how far off any other day is.
            if card != nil, let a = today.date, let b = day.date {
                notes.append(CardSurface.distance(days: Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0))
            }
        }
        if conflictView != nil { notes.append("Needs Review") } else if isReadOnly { notes.append("Read Only") }
        badge.stringValue = notes.joined(separator: " · ")
        badge.isHidden = notes.isEmpty
        needsLayout = true
    }

    /// When the note's file last changed.
    private var modified: Date? {
        (try? graph.root.appendingPathComponent(ref.path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
    /// Whether its words beside the name — when, a week's days — sit on its
    /// first line instead: a note named by its first heading has no header
    /// of its own to hold them.
    private var badgeOnFirstLine: Bool { ref.day == nil && title.stringValue.isEmpty && !badge.isHidden }

    /// Room at the right of the first line, the window's buttons there.
    package var trailingReserve: CGFloat = 0 { didSet { if trailingReserve != oldValue { needsLayout = true } } }

    private var editorTop: CGFloat {
        guard ref.day != nil || !title.stringValue.isEmpty else { return round(metrics.fontSize * 1.6) }
        return headerTop + headerHeight + round(metrics.fontSize * 0.7)
    }
    private var bottomPadding: CGFloat { round(metrics.fontSize * 1.6) }

    package override func layout() {
        super.layout()
        let column = column
        card?.frame = CardSurface.frame(column: column, in: bounds)
        // A label draws its text a couple of points in from its edge.
        let textX = column.minX + metrics.indent - 2
        // Whole points, and a little over: a bold face's last figure reaches
        // past the width it is measured at.
        let size = title.intrinsicContentSize
        title.frame = NSRect(x: textX, y: headerTop, width: ceil(size.width) + 4, height: ceil(size.height))
        let badgeSize = badge.intrinsicContentSize
        badge.frame = NSRect(x: title.frame.maxX + 6, y: title.frame.maxY - ceil(badgeSize.height) - 3,
                             width: ceil(badgeSize.width) + 4, height: ceil(badgeSize.height))
        if badgeOnFirstLine {
            // At the right of the first line, on its middle, clear of the buttons there.
            let width = ceil(badgeSize.width) + 4
            var middle = editorTop + round(metrics.fontSize * 0.9)
            if let layout = editor.layoutManager, layout.numberOfGlyphs > 0 {
                middle = editorTop + editor.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).midY
            }
            badge.frame = NSRect(x: column.maxX - trailingReserve - width, y: (middle - badgeSize.height / 2).rounded(),
                                 width: width, height: ceil(badgeSize.height))
        }
        keepFirstLineClear(of: badgeOnFirstLine ? (width: ceil(badgeSize.width) + 4 + trailingReserve + 10, column: column) : nil)
        var y = editorTop
        if let focusBar {
            focusBar.frame = NSRect(x: column.minX + metrics.indent - 6, y: y, width: column.width - metrics.indent + 6, height: FocusBar.height)
            y += focusBarRoom
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

    /// The first line's text kept short of what sits at its right: the
    /// when, and the buttons — a long name wraps before them.
    private func keepFirstLineClear(of room: (width: CGFloat, column: NSRect)?) {
        guard let container = editor.textContainer else { return }
        var paths: [NSBezierPath] = []
        if let room, let layout = editor.layoutManager, layout.numberOfGlyphs > 0 {
            let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            paths = [NSBezierPath(rect: NSRect(x: max(0, room.column.width - room.width), y: 0, width: room.width, height: line.height))]
        }
        let old = container.exclusionPaths.map(\.bounds)
        guard old != paths.map(\.bounds) else { return }
        container.exclusionPaths = paths
        heightMayHaveChanged()
    }

    // MARK: Focus

    /// The path to the row focused on, over the editor, while it is.
    private var focusBar: FocusBar?

    private func focusChanged() {
        rememberFocus()
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

    /// Notes the row focused on — or that there is none — so the note
    /// opens so again, after a restart too.
    private func rememberFocus() {
        guard !restoringFocus else { return }
        let mark = editor.focus.map { focus in
            SessionState.FocusMark(index: focus.before.count, text: editor.rows.first?.text ?? "", path: focus.ancestors.map(\.text))
        }
        SessionState.shared.setFocus(graph.root, ref, mark)
    }

    /// Set while the focus is being put back, which is not a change to note.
    private var restoringFocus = false

    /// Focuses the note where it was left focused: on the row at the place
    /// noted, when it still says what it did; else the first that says so,
    /// in the same rows; else not at all.
    private func restoreFocus() {
        guard let mark = SessionState.shared.focus(graph.root, ref) else { return }
        let all = editor.fullRows
        let index: Int? = if mark.index < all.count, all[mark.index].text == mark.text {
            mark.index
        } else {
            OutlineFind.entries(all).first { $0.row.text == mark.text && $0.path == mark.path }.map { entry in
                // A place among the rows unfolded: the row's among those shown, when it shows.
                Self.shownIndex(of: entry.index, in: all)
            } ?? nil
        }
        guard let index else { return }
        restoringFocus = true
        editor.focusOn(fullRow: index)
        restoringFocus = false
    }

    /// Where a row, by its place among the rows unfolded, is among the rows
    /// shown — nil when it is folded away.
    private static func shownIndex(of unfolded: Int, in rows: [Row]) -> Int? {
        var place = 0
        for (index, row) in rows.enumerated() {
            if place == unfolded { return index }
            place += 1 + Row.unfold(row.folded).count
            if place > unfolded { return nil }
        }
        return nil
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
    package func desiredHeight(width: CGFloat) -> CGFloat {
        let columnWidth = min(metrics.columnWidth, width - 48)
        var height = editorTop + bottomPadding + focusBarRoom
        height += conflictView?.height(forWidth: columnWidth) ?? editorHeight(width: columnWidth)
        return max(minimumHeight, height)
    }

    /// Whether a day is ruled off from the one before it: not where each
    /// note's heading says enough.
    package var drawsRule = true { didSet { needsDisplay = true } }

    /// Drawn as a card of this fill — when it is, beside its name — or on
    /// the page, as Reflect has it.
    package var cardFill: NSColor? {
        didSet {
            if let cardFill {
                let surface = card ?? {
                    let surface = CardSurface()
                    addSubview(surface, positioned: .below, relativeTo: nil)
                    card = surface
                    return surface
                }()
                surface.fill = cardFill
            } else {
                card?.removeFromSuperview()
                card = nil
            }
            updateTitle()
        }
    }
    private var card: CardSurface?

    package override func draw(_ dirtyRect: NSRect) {
        // Days are ruled apart; a note on its own needs no rule.
        guard drawsRule, ref.day != nil else { return }
        let column = column
        metrics.typography.ink.rule.setFill()
        NSRect(x: column.minX, y: 0, width: column.width, height: 1).fill()
    }

    // MARK: Reading and writing

    /// Reads the note from disk, and shows it.
    package func load() {
        show(graph.read(path: ref.path) ?? "")
    }

    /// Shows a note as it stands on disk, clean.
    private func show(_ text: String) {
        savedText = text
        isDirty = false
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
            restoreFocus()
            editor.isEditable = !isReadOnly
            editor.isPrivateNote = NoteIndex.entry(path: ref.path, source: text).isPrivate
        }
        updateTitle()
        needsLayout = true
    }

    /// Takes in what another app, or a sync, wrote. With writing here not
    /// yet saved, it is saved now, merged with what came in: both kept, and
    /// where both changed the same lines, both between markers to settle.
    package func reloadIfChanged() {
        let text = graph.read(path: ref.path) ?? ""
        guard text != savedText else { return }
        if isDirty {
            save()
            return
        }
        let focused = window?.firstResponder === editor
        let caret = editor.caretPosition
        show(text)
        if focused && !hasConflict { editor.restoreCaret(caret) }
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

    /// Writes the note, when there is anything new to write — merged with
    /// what is on disk when that changed since it was read, never over it.
    package func save() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard isDirty, !isDiscarded, !isReadOnly, !hasConflict else { return }
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
        let merged = disk == savedText || disk == text ? TextMerge.Result(text: text, conflicted: false)
            : TextMerge.merge(base: savedText, ours: text, theirs: disk)
        do {
            try graph.write(merged.text, path: ref.path)
            savedText = merged.text
            isDirty = false
            onSave?()
        } catch {
            presentError(error)
            return
        }
        if merged.text != text {
            // What came in shown too, the caret where it was.
            let focused = window?.firstResponder === editor
            let caret = editor.caretPosition
            show(merged.text)
            if focused && !hasConflict { editor.restoreCaret(caret) }
            heightMayHaveChanged()
        }
    }

    /// Lets the note go without writing it: it has been deleted.
    package func discard() {
        saveTimer?.invalidate()
        saveTimer = nil
        isDirty = false
        isDiscarded = true
    }

    // MARK: NSTextViewDelegate

    /// Where the caret is, noted as it moves while it is here — not as the
    /// note is loaded or changed from disk — so the note opens there again.
    package func textViewDidChangeSelection(_ notification: Notification) {
        guard window?.firstResponder === editor, !hasConflict else { return }
        SessionState.shared.setSelection(graph.root, ref, editor.selectedRange())
    }

    /// The caret put back where the note was left, when it was left
    /// somewhere still in it. Says whether it was.
    package func restoreSelection() -> Bool {
        guard let place = SessionState.shared.place(graph.root, ref), let length = editor.textStorage?.length else { return false }
        let location = min(place.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(place.length, length - location)))
        return true
    }

    package func textDidChange(_ notification: Notification) {
        // Folding is an edit to the text on screen, if not to the note.
        SessionState.shared.setFolds(graph.root, ref, OutlineFolds.marks(editor.fullRows))
        isDirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
        heightMayHaveChanged()
    }

    package func undoManager(for view: NSTextView) -> UndoManager? { undo }
}
