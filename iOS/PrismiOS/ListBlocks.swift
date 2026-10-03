import UIKit
import ReflectCore
import PrismCore

/// What a sheet is made of: blocks one under another, each as tall as it
/// says at the sheet's width — a day, a note, a note's slices, a heading.
@MainActor
protocol SheetBlock: UIView {
    func height(width: CGFloat) -> CGFloat
    /// What is typed in it, written.
    func save()
    /// Notes changed on disk: those it shows read again, unless typed in.
    func notesChanged(_ paths: Set<String>)
    /// Its editors, to find the caret and the headings in.
    var editors: [OutlineEditor] { get }
    var onHeightChange: (() -> Void)? { get set }
    var onCaretMove: (() -> Void)? { get set }
}

extension NoteBlock: SheetBlock {
    var editors: [OutlineEditor] { [editor] }

    func notesChanged(_ paths: Set<String>) {
        if paths.isEmpty || paths.contains(ref.path) { reloadIfChanged() }
    }
}

/// The head of a sheet of many — the inbox, the tasks, what links to a
/// note: a small line saying how many over its name.
final class HeadBlock: UIView, SheetBlock {
    private let kicker = UILabel()
    private let title = UILabel()
    var onHeightChange: (() -> Void)?
    var onCaretMove: (() -> Void)?
    var editors: [OutlineEditor] { [] }
    private let metrics: PhoneMetrics
    /// Smaller: a group's name within the sheet — Current, Overdue.
    private let isGroup: Bool

    init(title: String, kicker: String?, metrics: PhoneMetrics, isGroup: Bool = false) {
        self.metrics = metrics
        self.isGroup = isGroup
        super.init(frame: .zero)
        self.title.text = title
        self.title.numberOfLines = 0
        self.title.textColor = isGroup ? Ink.secondary : Ink.text
        self.title.font = isGroup ? metrics.face.heading(round(metrics.size * 0.8), weight: .semibold)
            : metrics.face.heading(round(metrics.size * 1.8), weight: .bold)
        self.kicker.text = kicker?.uppercased()
        self.kicker.textColor = Ink.secondary
        self.kicker.font = metrics.face.heading(round(metrics.size * 0.68), weight: .semibold)
        if isGroup { self.title.text = title.uppercased() }
        addSubview(self.kicker)
        addSubview(self.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var kickerText: String? {
        get { kicker.text }
        set {
            kicker.text = newValue?.uppercased()
            setNeedsLayout()
        }
    }

    func height(width: CGFloat) -> CGFloat {
        let inner = width - 2 * NoteBlock.side
        var height: CGFloat = isGroup ? 22 : 12
        if kicker.text?.isEmpty == false { height += ceil(kicker.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height) + 4 }
        height += ceil(title.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
        return height + (isGroup ? 2 : 6)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inner = bounds.width - 2 * NoteBlock.side
        var y: CGFloat = isGroup ? 22 : 12
        if kicker.text?.isEmpty == false {
            let height = ceil(kicker.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
            kicker.frame = CGRect(x: NoteBlock.side, y: y, width: inner, height: height)
            y += height + 4
        } else {
            kicker.frame = .zero
        }
        title.frame = CGRect(x: NoteBlock.side, y: y, width: inner, height: ceil(title.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height))
    }

    func save() {}
    func notesChanged(_ paths: Set<String>) {}
}

/// Pieces of one note shown away from it — the tasks in it, the rows that
/// link to a note, the rows a search found — under the note's name, each
/// editable where it is and written back into its place in the note.
final class SliceBlock: UIView, SheetBlock {
    let path: String
    private(set) var slices: [NoteSlice]
    private(set) var editors: [OutlineEditor] = []
    private var crumbLabels: [UILabel?] = []
    private let title = UIButton(type: .system)
    private weak var store: PrismStore?
    private let metrics: PhoneMetrics
    /// What is on disk, as last read or written.
    private var savedText: String
    /// The slices typed in since last written.
    private var dirty: Set<Int> = []
    private var saveTimer: Timer?
    var onOpen: (() -> Void)?
    var onLink: ((String) -> Void)?
    var onHeightChange: (() -> Void)?
    var onCaretMove: (() -> Void)?

    init(path: String, slices: [NoteSlice], editable: Bool, store: PrismStore, metrics: PhoneMetrics) {
        self.path = path
        self.slices = slices
        self.store = store
        self.metrics = metrics
        savedText = store.text(path)
        super.init(frame: .zero)
        title.contentHorizontalAlignment = .leading
        title.setAttributedTitle(NSAttributedString(string: Self.name(path, store: store), attributes: [
            .font: metrics.face.heading(round(metrics.size * 0.95), weight: .semibold),
            .foregroundColor: Ink.secondary,
        ]), for: .normal)
        title.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        addSubview(title)
        var previous: [String]?
        for (i, slice) in slices.enumerated() {
            // The rows it is under, when they are not the last one's.
            if !slice.crumbs.isEmpty, slice.crumbs != previous {
                let label = UILabel()
                label.numberOfLines = 2
                label.textColor = Ink.faint
                label.font = metrics.face.body(round(metrics.size * 0.78), weight: .regular)
                label.text = slice.crumbs.joined(separator: "  ›  ")
                addSubview(label)
                crumbLabels.append(label)
            } else {
                crumbLabels.append(nil)
            }
            previous = slice.crumbs
            let editor = OutlineEditor(metrics: metrics)
            editor.load(slice.rows)
            editor.isEditable = editable
            editor.onChange = { [weak self] in self?.edited(i) }
            editor.onOpenLink = { [weak self] link in self?.onLink?(link) }
            editor.onHeightChange = { [weak self] in
                self?.setNeedsLayout()
                self?.onHeightChange?()
            }
            editor.onCaretMove = { [weak self] in self?.onCaretMove?() }
            editor.onFocusChange = { [weak self] focused in if !focused { self?.save() } }
            addSubview(editor)
            editors.append(editor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What a note is called over its pieces: a day by its date.
    static func name(_ path: String, store: PrismStore) -> String {
        if let day = GraphPaths.day(fromDailyPath: path) { return NoteBlock.dayTitle(day) }
        if let week = GraphPaths.week(fromWeeklyPath: path) { return "Week \(week.week)" }
        return store.index?.entry(path)?.title ?? (path as NSString).lastPathComponent
    }

    var isTyping: Bool { editors.contains(where: \.isFirstResponder) }

    // MARK: Writing

    private func edited(_ i: Int) {
        dirty.insert(i)
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Each piece typed in, put back in its place in the note; those after
    /// it in the note moved along by as many rows as it grew.
    func save() {
        saveTimer?.invalidate()
        guard !dirty.isEmpty, let store else { return }
        var source = store.text(path)
        for i in dirty.sorted() {
            let slice = slices[i]
            let rows = Row.unfold(editors[i].rows).map { row -> Row in
                var row = row
                row.depth += slice.depth
                return row
            }
            guard let written = slice.writing(rows, into: source) else { continue }
            source = written
            let delta = rows.count - slice.count
            slices[i].count = rows.count
            for j in slices.indices where j != i && slices[j].start > slice.start { slices[j].start += delta }
        }
        dirty = []
        guard source != savedText else { return }
        savedText = source
        store.write(source, path: path)
    }

    /// Changed on disk: when not typed in here, the pieces read again from
    /// what the note says now — those the same left as they are.
    func notesChanged(_ paths: Set<String>) {
        guard paths.isEmpty || paths.contains(path), let store, dirty.isEmpty, !isTyping else { return }
        let text = store.text(path)
        guard text != savedText else { return }
        savedText = text
        let rows = OutlineMarkdown.parse(text).rows
        for (i, slice) in slices.enumerated() where slice.start + slice.count <= rows.count {
            let fresh = rows[slice.start..<(slice.start + slice.count)].map { row -> Row in
                var row = row
                row.depth -= slice.depth
                return row
            }
            if fresh != Row.unfold(editors[i].rows) { editors[i].load(fresh) }
        }
    }

    // MARK: Layout

    private var titleHeight: CGFloat { ceil(title.intrinsicContentSize.height) }

    func height(width: CGFloat) -> CGFloat {
        guard width > NoteBlock.minimumWidth else { return 0 }
        let inner = width - 2 * NoteBlock.side
        var height: CGFloat = 14 + titleHeight + 2
        for (i, editor) in editors.enumerated() {
            if let label = crumbLabels[i] { height += ceil(label.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height) + 2 }
            height += editor.rowsHeight(width: inner + metrics.indent) + 4
        }
        return height + 10
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Not yet as wide as it will be: text laid out at no width never ends.
        guard bounds.width > NoteBlock.minimumWidth else { return }
        let inner = bounds.width - 2 * NoteBlock.side
        var y: CGFloat = 14
        title.frame = CGRect(x: NoteBlock.side, y: y, width: min(title.intrinsicContentSize.width, inner), height: titleHeight)
        y += titleHeight + 2
        for (i, editor) in editors.enumerated() {
            if let label = crumbLabels[i] {
                let height = ceil(label.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
                label.frame = CGRect(x: NoteBlock.side, y: y, width: inner, height: height)
                y += height + 2
            }
            let width = inner + metrics.indent
            // Its frame holds the empty line after the last row too — a text
            // view squeezed shorter than its text lays out forever — but
            // what comes next goes right under the rows.
            let full = editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            editor.frame = CGRect(x: NoteBlock.side - metrics.indent, y: y, width: width, height: full)
            y += editor.rowsHeight(width: width) + 4
        }
    }
}
