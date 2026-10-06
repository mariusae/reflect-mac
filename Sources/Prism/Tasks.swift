import AppKit
import ReflectCore
import PrismCore
import ReflectUI

typealias TaskSlice = NoteSlice

/// A task in the column, editable where it is: what is typed goes back to
/// its place in its note.
@MainActor
final class TaskEditor: NSObject, NSTextViewDelegate {
    let view: OutlineTextView
    var slice: TaskSlice
    /// Told, a moment after typing stops, to write it back.
    var onEdit: ((TaskEditor) -> Void)?
    /// Told as it is typed in: it may want another height.
    var onResize: (() -> Void)?
    /// Told when the keyboard leaves it: what changed meanwhile can be shown.
    var onLeave: (() -> Void)?
    /// Words to mark where they are — what a search found — as a
    /// highlighter would, never in the note itself.
    var highlight: [String] = [] { didSet { markHighlights() } }

    private func markHighlights() {
        guard let layout = view.layoutManager else { return }
        let text = view.string as NSString
        let all = NSRange(location: 0, length: text.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        for word in highlight where !word.isEmpty {
            var from = 0
            while from < text.length {
                let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: from, length: text.length - from))
                guard found.location != NSNotFound else { break }
                layout.addTemporaryAttribute(.backgroundColor, value: Ink.marked, forCharacterRange: found)
                from = NSMaxRange(found)
            }
        }
    }
    private var timer: Timer?

    init(slice: TaskSlice, metrics: OutlineMetrics, images: ImageStore, navigator: OutlineTextViewNavigator) {
        self.slice = slice
        view = OutlineTextView(metrics: metrics)
        super.init()
        view.images = images
        view.navigator = navigator
        view.load(slice.rows)
        view.delegate = self
    }

    /// The rows as edited, back at their depth in the note.
    var rowsInNote: [Row] {
        Row.unfold(view.rows).map { row in
            var row = row
            row.depth += slice.depth
            return row
        }
    }

    func textDidChange(_ notification: Notification) {
        if !highlight.isEmpty { markHighlights() }
        onResize?()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onEdit?(self)
            }
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        flush()
        onLeave?()
    }

    /// Writes now what is waiting to be written.
    func flush() {
        guard let timer, timer.isValid else { return }
        timer.invalidate()
        onEdit?(self)
    }

    func height(width: CGFloat) -> CGFloat {
        guard let layout = view.layoutManager, let container = view.textContainer else { return 0 }
        if abs(container.size.width - width) > 0.5 {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).height
        if layout.extraLineFragmentTextContainer != nil { height -= layout.extraLineFragmentRect.height }
        return ceil(max(height, view.metrics.fontSize * 1.4))
    }
}

/// The path to tasks, over them, as focusing shows it: the note, then
/// each item they are under. Clicked, the note opens on its own.
final class TaskPath: NSView {
    var onClick: ((_ newColumn: Bool) -> Void)?
    private let label = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    init(steps: [String], face: Typeface, size: CGFloat) {
        super.init(frame: .zero)
        let text = NSMutableAttributedString()
        let font = face.font(size: round(size * 0.8), weight: .medium)
        for (i, step) in steps.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "  ›  ", attributes: [.font: font, .foregroundColor: Ink.faint])) }
            text.append(NSAttributedString(string: step, attributes: [.font: font, .foregroundColor: Ink.secondary]))
        }
        label.attributedStringValue = text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        toolTip = "Open “\(steps.first ?? "")” (⌘-click: in the column beside; ⇧⌘-click: in a new one)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { ceil(label.intrinsicContentSize.height) + 2 }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 1, width: bounds.width, height: ceil(label.intrinsicContentSize.height))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?(event.modifierFlags.contains(.command)) }
}

/// A group of the tasks — Current, Overdue, Upcoming, or a note's — under
/// its name: its tasks under the paths to them, those at the same place
/// together, each just the task and what is under it.
final class TaskGroupBlock: NSView, ColumnBlock {
    let group: TaskGroup
    private let kicker = NSTextField(labelWithString: "")
    private var headerLink: NoteHeaderLink?
    /// Each run of tasks at the same place: the path to them, and them.
    private var runs: [(path: TaskPath?, editors: [TaskEditor])] = []
    private let metrics: OutlineMetrics
    private let card = CardSurface()

    override var isFlipped: Bool { true }

    var editors: [TaskEditor] { runs.flatMap(\.editors) }

    /// `runs`: each place, the path to it, and the tasks there.
    init(group: TaskGroup, runs: [(steps: [String], slices: [TaskSlice])], metrics: OutlineMetrics, face: Typeface,
         images: ImageStore, navigator: OutlineTextViewNavigator,
         onEdit: @escaping (TaskEditor) -> Void, onResize: @escaping () -> Void, onLeave: @escaping () -> Void,
         onOpen: @escaping (String, Bool) -> Void) {
        self.group = group
        self.metrics = metrics
        super.init(frame: .zero)
        card.fill = Ink.card
        addSubview(card)
        let typography = metrics.typography
        kicker.attributedStringValue = NSAttributedString(string: group.label.uppercased(), attributes: [
            .font: Typography.font(typography.headingFamily, face: typography.headingFace, size: round(metrics.fontSize * 0.7),
                                   weight: .semibold),
            .foregroundColor: group.kind == .overdue ? NSColor.systemRed : Ink.secondary, .kern: 1.0,
        ])
        kicker.lineBreakMode = .byTruncatingTail
        addSubview(kicker)
        // A note's own group: its name, a way to the note.
        if let path = group.notePath {
            let link = NoteHeaderLink()
            link.onClick = { newColumn in onOpen(path, newColumn) }
            link.toolTip = "Open “\(group.label)” (⌘-click: in the column beside; ⇧⌘-click: in a new one)"
            addSubview(link)
            headerLink = link
        }
        for run in runs {
            let notePath = run.slices[0].path
            let path: TaskPath? = run.steps.isEmpty ? nil : {
                let path = TaskPath(steps: run.steps, face: face, size: metrics.fontSize)
                path.onClick = { newColumn in onOpen(notePath, newColumn) }
                addSubview(path)
                return path
            }()
            let editors = run.slices.map { slice -> TaskEditor in
                let editor = TaskEditor(slice: slice, metrics: metrics, images: images, navigator: navigator)
                editor.onEdit = onEdit
                editor.onResize = onResize
                editor.view.onRestyle = onResize
                editor.onLeave = onLeave
                addSubview(editor.view)
                return editor
            }
            self.runs.append((path, editors))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func column(_ width: CGFloat) -> NSRect {
        let column = min(metrics.columnWidth, width - 48)
        return NSRect(x: ((width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    private var top: CGFloat { round(metrics.fontSize * 1.5) }
    private var gap: CGFloat { round(metrics.fontSize * 0.55) }

    /// Lays its parts out down a width, or only measures them.
    @discardableResult
    private func place(width: CGFloat, laying: Bool) -> CGFloat {
        let column = column(width)
        if laying { card.frame = CardSurface.frame(column: column, in: bounds) }
        let x = column.minX + metrics.indent - 2
        var y = top
        let kickerHeight = ceil(kicker.intrinsicContentSize.height)
        if laying {
            kicker.frame = NSRect(x: x, y: y, width: column.maxX - x, height: kickerHeight)
            let width = min(column.maxX - x, ceil(kicker.attributedStringValue.size().width) + 6)
            headerLink?.frame = NSRect(x: x, y: y - 3, width: width, height: kickerHeight + 6)
        }
        y += kickerHeight + gap
        for run in runs {
            if let path = run.path {
                if laying { path.frame = NSRect(x: x, y: y, width: column.maxX - x, height: path.height) }
                y += path.height + 2
            }
            for editor in run.editors {
                let height = editor.height(width: column.width)
                if laying { editor.view.frame = NSRect(x: column.minX, y: y, width: column.width, height: height) }
                y += height
            }
            y += gap
        }
        return y + CardSurface.spacing + 4
    }

    func desiredHeight(width: CGFloat) -> CGFloat { place(width: width, laying: false) }

    var stickyTitle: (title: String, when: String?, today: Bool)? {
        (group.label, "\(group.tasks.count) \(group.tasks.count == 1 ? "task" : "tasks")", false)
    }

    override func layout() {
        super.layout()
        place(width: bounds.width, laying: true)
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] {
        var marks = [ScrubMark(y: top, title: group.label, detail: "\(group.tasks.count) \(group.tasks.count == 1 ? "task" : "tasks")",
                               rank: 3)]
        for run in runs {
            guard let path = run.path, let first = run.editors.first else { continue }
            marks.append(ScrubMark(y: path.frame.minY, title: InlineMarkup.plainText(first.slice.task?.text ?? ""),
                                   detail: first.slice.task?.noteTitle, rank: 2))
        }
        return marks
    }
}

/// The head of a search: the words looked for, to change, and how many
/// notes have them.
final class SearchHeader: NSView, ColumnBlock, NSTextFieldDelegate {
    private let kicker: ColumnLabel
    let field = NSTextField()
    private let metrics: OutlineMetrics
    /// The words were changed: looked for again, a moment after typing stops.
    var onQuery: ((String) -> Void)?
    /// Matches — the rows found, under each note's name — or the notes
    /// found, whole, one after another: a timeline of one's own making.
    private let shows = NSSegmentedControl(labels: ["Matches", "Notes"], trackingMode: .selectOne, target: nil, action: nil)
    var onShowNotes: ((Bool) -> Void)?
    private var timer: Timer?

    override var isFlipped: Bool { true }

    init(query: String, metrics: OutlineMetrics) {
        self.metrics = metrics
        kicker = ColumnLabel("Search", metrics: metrics)
        super.init(frame: .zero)
        let typography = metrics.typography
        let font = typography.headingFont(size: round(metrics.fontSize * 1.9), weight: .bold)
        field.font = font
        field.stringValue = query
        field.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [.font: font, .foregroundColor: Ink.faint])
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Ink.text
        field.delegate = self
        field.lineBreakMode = .byTruncatingTail
        addSubview(kicker)
        addSubview(field)
        shows.controlSize = .small
        shows.selectedSegment = Column.searchShowsNotes ? 1 : 0
        shows.target = self
        shows.action = #selector(showsChanged)
        shows.toolTip = "Show the rows that match, or each note found, whole"
        addSubview(shows)
        show(count: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func showsChanged() {
        let notes = shows.selectedSegment == 1
        Column.searchShowsNotes = notes
        onShowNotes?(notes)
    }

    /// How many notes were found: nil while looking.
    func show(count: Int?) {
        kicker.count = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? nil : count
    }

    /// ↩ looks at once.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        timer?.invalidate()
        onQuery?(field.stringValue)
        return true
    }

    func controlTextDidChange(_ obj: Notification) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onQuery?(self.field.stringValue)
            }
        }
    }

    private var column: NSRect {
        let column = min(metrics.columnWidth, bounds.width - 48)
        return NSRect(x: ((bounds.width - column) / 2).rounded(), y: 0, width: column, height: 0)
    }

    func desiredHeight(width: CGFloat) -> CGFloat {
        round(metrics.fontSize * 1.2) + ceil(kicker.intrinsicContentSize.height) + 4 + ceil(field.intrinsicContentSize.height)
            + round(metrics.fontSize * 0.6)
    }

    override func layout() {
        super.layout()
        let x = column.minX + metrics.indent - 2
        var y = round(metrics.fontSize * 1.2)
        let kickerHeight = ceil(kicker.intrinsicContentSize.height)
        kicker.frame = NSRect(x: x, y: y, width: column.maxX - x, height: kickerHeight)
        y += kickerHeight + 4
        let showsSize = shows.intrinsicContentSize
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        shows.frame = NSRect(x: column.maxX - showsSize.width, y: (y + (fieldHeight - showsSize.height) / 2).rounded(),
                             width: showsSize.width, height: showsSize.height)
        field.frame = NSRect(x: x - 2, y: y, width: max(40, shows.frame.minX - 12 - x), height: fieldHeight)
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }
}
