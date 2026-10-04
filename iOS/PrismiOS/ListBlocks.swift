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
    /// Whether it is built: far from sight, a block may stand unbuilt,
    /// as tall as it guesses, till it comes near.
    var isLive: Bool { get }
    func goLive()
    /// Built ahead, off the main thread, when it can be.
    func prepareLive(width: CGFloat)
}

extension SheetBlock {
    func prepareLive(width: CGFloat) {}
}

extension HeadBlock {
    var isLive: Bool { true }
    func goLive() {}
}

extension GapBlock {
    var isLive: Bool { true }
    func goLive() {}
}

extension NoteBlock: SheetBlock {
    var editors: [OutlineEditor] { isLive ? [editor] : [] }

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

    private let editable: Bool
    private(set) var isLive = false

    init(path: String, slices: [NoteSlice], editable: Bool, store: PrismStore, metrics: PhoneMetrics) {
        self.editable = editable
        self.path = path
        self.slices = slices
        self.store = store
        self.metrics = metrics
        savedText = store.text(path)
        super.init(frame: .zero)
        title.contentHorizontalAlignment = .leading
        title.setAttributedTitle(Card.header(name: Self.name(path, store: store), meta: Card.meta(for: path, store: store), size: metrics.size),
                                 for: .normal)
        title.titleLabel?.lineBreakMode = .byTruncatingMiddle
        title.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        addSubview(title)
    }

    /// Its pieces' editors made, to be seen and typed in.
    func goLive() {
        guard !isLive else { return }
        isLive = true
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
            // A note mid-conflict is settled whole, on its own, not piece by piece.
            editor.isEditable = editable && !ConflictMarkers.detect(savedText)
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
        setNeedsLayout()
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
        guard isLive else {
            savedText = store.text(path)
            return
        }
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

    /// The name's size and the crumbs' heights, measured once — at a width,
    /// for the crumbs — not each time the sheet asks every block its height.
    private lazy var titleSize = title.intrinsicContentSize
    private var titleHeight: CGFloat { ceil(titleSize.height) }
    private var crumbHeights: (width: CGFloat, heights: [CGFloat])?

    private func crumbHeight(_ i: Int, inner: CGFloat) -> CGFloat? {
        guard let label = crumbLabels[i] else { return nil }
        if crumbHeights?.width != inner || crumbHeights?.heights.count != crumbLabels.count {
            crumbHeights = (inner, crumbLabels.map { label in
                label.map { ceil($0.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height) } ?? 0
            })
        }
        return crumbHeights?.heights[i] ?? ceil(label.sizeThatFits(CGSize(width: inner, height: .greatestFiniteMagnitude)).height)
    }

    func height(width: CGFloat) -> CGFloat {
        guard width > NoteBlock.minimumWidth else { return 0 }
        let inner = width - 2 * NoteBlock.side
        var height: CGFloat = Card.top + titleHeight + Card.gap
        guard isLive else {
            // A guess from its rows: a line each, more for long ones.
            let line = round(metrics.face.lineHeight * metrics.size) + round(metrics.size * 0.32)
            let perLine = max(20, inner / (metrics.size * 0.52))
            let lines = slices.reduce(0.0) { sum, slice in
                sum + slice.rows.reduce(0.0) { $0 + max(1, ceil(Double($1.text.count) / perLine)) } + (slice.crumbs.isEmpty ? 0 : 1)
            }
            return height + CGFloat(lines) * line + 4 * CGFloat(slices.count) + Card.bottom
        }
        for (i, editor) in editors.enumerated() {
            if let crumb = crumbHeight(i, inner: inner) { height += crumb + 2 }
            height += editor.rowsHeight(width: inner + metrics.indent) + 4
        }
        return height + Card.bottom - 4
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Not yet as wide as it will be: text laid out at no width never ends.
        guard bounds.width > NoteBlock.minimumWidth else { return }
        let inner = bounds.width - 2 * NoteBlock.side
        var y: CGFloat = Card.top
        title.frame = CGRect(x: NoteBlock.side, y: y, width: min(titleSize.width, inner), height: titleHeight)
        y += titleHeight + Card.gap
        for (i, editor) in editors.enumerated() {
            if let label = crumbLabels[i], let height = crumbHeight(i, inner: inner) {
                label.frame = CGRect(x: NoteBlock.side, y: y, width: inner, height: height)
                y += height + 2
            }
            let width = inner + metrics.indent
            // Its frame holds the empty line after the last row too — a text
            // view squeezed shorter than its text lays out forever — but
            // what comes next goes right under the rows.
            let full = editor.fittingHeight(width: width)
            editor.frame = CGRect(x: NoteBlock.side - metrics.indent, y: y, width: width, height: full)
            y += editor.rowsHeight(width: width) + 4
        }
    }
}

/// Days in the timeline with no note: a `⋯` and the dates it stands for,
/// tapped to show the last few of them, empty, to write in.
final class GapBlock: UIView, SheetBlock {
    let gap: TimelineGap
    private let button = UIButton(type: .system)
    var onReveal: ((TimelineGap) -> Void)?
    var onHeightChange: (() -> Void)?
    var onCaretMove: (() -> Void)?
    var editors: [OutlineEditor] { [] }

    init(gap: TimelineGap, metrics: PhoneMetrics) {
        self.gap = gap
        super.init(frame: .zero)
        let title = NSMutableAttributedString(string: "⋯  ", attributes: [
            .font: UIFont.systemFont(ofSize: round(metrics.size * 1.2), weight: .bold), .foregroundColor: Ink.secondary,
        ])
        title.append(NSAttributedString(string: Self.describe(gap), attributes: [
            .font: metrics.face.heading(round(metrics.size * 0.78), weight: .medium), .foregroundColor: Ink.faint,
        ]))
        button.setAttributedTitle(title, for: .normal)
        button.contentHorizontalAlignment = .leading
        button.accessibilityLabel = "Show " + Self.describe(gap)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onReveal?(self.gap)
        }, for: .touchUpInside)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `Sep 21 – 25 · 5 days`, or the one day it is.
    static func describe(_ gap: TimelineGap) -> String {
        guard let from = gap.from.date, let to = gap.to.date else { return "" }
        if gap.count == 1 { return Formats.date("EEEMMMd").string(from: from) }
        return Formats.interval(gap.from.year == gap.to.year ? "MMMd" : "MMMdyyyy").string(from: from, to: to) + " · \(gap.count) days"
    }

    func height(width: CGFloat) -> CGFloat { 52 }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = CGRect(x: NoteBlock.side, y: 4, width: bounds.width - 2 * NoteBlock.side, height: bounds.height - 8)
    }

    func save() {}
    func notesChanged(_ paths: Set<String>) {}
}
