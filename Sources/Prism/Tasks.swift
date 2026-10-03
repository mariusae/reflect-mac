import AppKit
import ReflectCore
import ReflectUI

/// A piece of a note shown away from it — a task, or the row a link is in
/// — editable there: its row and the rows under it, as focusing on it shows
/// them, and where they are in the note, to write them back to.
struct TaskSlice {
    var path: String
    /// The task it is, in the tasks column.
    var task: NoteTask?
    /// The rows it is under, outermost first, as they read.
    var crumbs: [String] = []
    /// The first of its rows among the note's, and how many it has there.
    var start: Int
    var count: Int
    /// How deep the task is in its note: its rows are shown from the left.
    var depth: Int
    var rows: [Row]

    /// The tasks of a note, each with what is under it, from its text.
    static func slices(of tasks: [NoteTask], in source: String) -> [TaskSlice] {
        let rows = OutlineMarkdown.parse(source).rows
        var starts: [Int] = []
        for (i, row) in rows.enumerated() where Tasks.isTask(row) { starts.append(i) }
        return tasks.compactMap { task in
            guard starts.indices.contains(task.ordinal) else { return nil }
            let start = starts[task.ordinal]
            let block = OutlineEditing.block(rows, start..<(start + 1))
            let depth = rows[start].depth
            let shown = rows[block].map { row -> Row in
                var row = row
                row.depth -= depth
                return row
            }
            return TaskSlice(path: task.notePath, task: task, start: block.lowerBound, count: block.count, depth: depth, rows: shown)
        }
    }

    /// The rows of a note holding any of some links, each with what is
    /// under it: one slice for rows one inside another.
    static func slices(holding links: [String], path: String, in source: String) -> [TaskSlice] {
        let links = Set(links.filter { !$0.isEmpty })
        return slices(path: path, in: source) { text in links.contains(where: text.contains) }
    }

    /// The rows of a note with any of some words in them — regardless of
    /// case and accents — each with what is under it.
    static func slices(finding words: [String], path: String, in source: String) -> [TaskSlice] {
        slices(path: path, in: source) { text in
            words.contains { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The rows of a note whose text says so, each with what is under it.
    static func slices(path: String, in source: String, where wanted: (String) -> Bool) -> [TaskSlice] {
        let rows = OutlineMarkdown.parse(source).rows
        var slices: [TaskSlice] = []
        var covered = 0..<0
        var ancestors: [(depth: Int, text: String)] = []
        for (i, row) in rows.enumerated() {
            while let last = ancestors.last, last.depth >= row.depth { ancestors.removeLast() }
            defer { if row.kind.isListItem { ancestors.append((row.depth, InlineMarkup.plainText(row.text))) } }
            guard !covered.contains(i), wanted(row.text) else { continue }
            // A heading alone, not the section under it; and a note's title
            // heading not at all — its name says it already.
            var block = OutlineEditing.block(rows, i..<(i + 1))
            if case .heading(let level) = row.kind {
                if level == 1, rows[..<i].allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
                block = i..<(i + 1)
            }
            covered = block
            let depth = row.depth
            let shown = rows[block].map { row -> Row in
                var row = row
                row.depth -= depth
                return row
            }
            slices.append(TaskSlice(path: path, crumbs: ancestors.map(\.text).filter { !$0.isEmpty },
                                    start: block.lowerBound, count: block.count, depth: depth, rows: shown))
        }
        return slices
    }
}

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
        return y
    }

    func desiredHeight(width: CGFloat) -> CGFloat { place(width: width, laying: false) }

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
    private let kicker = NSTextField(labelWithString: "")
    let field = NSTextField()
    private let metrics: OutlineMetrics
    /// The words were changed: looked for again, a moment after typing stops.
    var onQuery: ((String) -> Void)?
    private var timer: Timer?

    override var isFlipped: Bool { true }

    init(query: String, metrics: OutlineMetrics) {
        self.metrics = metrics
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
        show(count: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// How many notes were found: nil while looking.
    func show(count: Int?) {
        let words = field.stringValue.trimmingCharacters(in: .whitespaces)
        let text = words.isEmpty ? "Type to search every note"
            : count.map { $0 == 0 ? "No notes have it" : "\($0) \($0 == 1 ? "note has it" : "notes have it")" } ?? "Looking…"
        let typography = metrics.typography
        kicker.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: Typography.font(typography.headingFamily, face: typography.headingFace, size: round(metrics.fontSize * 0.68),
                                   weight: .semibold),
            .foregroundColor: Ink.secondary, .kern: 1.0,
        ])
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
        field.frame = NSRect(x: x - 2, y: y, width: column.maxX - x, height: ceil(field.intrinsicContentSize.height))
    }

    func scrubMarks(listed: Bool) -> [ScrubMark] { [] }
}
