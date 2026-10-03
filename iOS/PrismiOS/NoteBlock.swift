import UIKit
import ReflectCore
import PrismCore

/// A note in a sheet: its name over it — a day's date, a week's number, a
/// note's title when its first heading is not that — and its outline,
/// edited where it is, written a moment after typing stops.
final class NoteBlock: UIView {
    let ref: NoteRef
    let editor: OutlineEditor
    private let header = UIButton(type: .system)
    private let badge = UILabel()
    /// A button at the header's end: the inbox's Done.
    private(set) var accessory: UIButton?
    private weak var store: PrismStore?
    /// What the note is beside its rows: frontmatter, a trailing gap.
    private var shell = Outline(rows: [])
    /// What is on disk, as last read or written.
    private(set) var savedText = ""
    private var saveTimer: Timer?
    private var dirty = false
    /// Told when the header is tapped: the note, to open on its own.
    var onOpen: (() -> Void)?
    /// Told when a link is tapped in it.
    var onLink: ((String) -> Void)?
    /// Told when the caret in it moved.
    var onCaretMove: (() -> Void)?
    /// Told when it wants another height.
    var onHeightChange: (() -> Void)?
    /// Whether its name shows over it: in a list of notes, yes; alone, only
    /// when its first heading does not say it.
    var showsHeader: Bool

    init(ref: NoteRef, store: PrismStore, metrics: PhoneMetrics, showsHeader: Bool) {
        self.ref = ref
        self.store = store
        self.showsHeader = showsHeader
        editor = OutlineEditor(metrics: metrics)
        super.init(frame: .zero)
        header.contentHorizontalAlignment = .leading
        header.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        badge.textColor = Ink.secondary
        addSubview(header)
        addSubview(badge)
        addSubview(editor)
        editor.onChange = { [weak self] in self?.edited() }
        editor.onOpenLink = { [weak self] link in self?.onLink?(link) }
        editor.onCaretMove = { [weak self] in self?.onCaretMove?() }
        editor.onHeightChange = { [weak self] in
            self?.setNeedsLayout()
            self?.onHeightChange?()
        }
        editor.onFocusChange = { [weak self] focused in if !focused { self?.save() } }
        load()
        styleHeader()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var metrics: PhoneMetrics {
        get { editor.metrics }
        set {
            editor.metrics = newValue
            styleHeader()
        }
    }

    func setAccessory(symbol: String, label: String, action: @escaping () -> Void) {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)), for: .normal)
        button.tintColor = Ink.secondary
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        addSubview(button)
        accessory = button
        setNeedsLayout()
    }

    // MARK: Reading and writing

    func load() {
        let text = store?.text(ref.path) ?? ""
        savedText = text
        shell = OutlineMarkdown.parse(text)
        var rows = shell.rows
        // A note that is its title alone gets a row to write in.
        if rows.isEmpty || ref.day != nil && rows.allSatisfy({ $0.text.isEmpty && $0.kind != .code }) {
            rows = rows.isEmpty ? [.blank] : rows
        }
        let folds = PhoneState.folds(ref.path)
        editor.load(folds.isEmpty ? rows : OutlineFolds.apply(folds, to: rows))
        dirty = false
        styleHeader()
    }

    /// The note as changed on disk, unless there is writing here not yet saved.
    func reloadIfChanged() {
        guard !dirty, (store?.text(ref.path) ?? "") != savedText else { return }
        let caret = editor.caret
        load()
        if editor.isFirstResponder { editor.setCaret(caret) }
    }

    private func edited() {
        dirty = true
        PhoneState.setFolds(ref.path, OutlineFolds.marks(editor.rows))
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Writes the note, when it changed: a day not written in, left blank, stays unwritten.
    func save() {
        saveTimer?.invalidate()
        guard dirty, let store else { return }
        dirty = false
        var outline = shell
        outline.rows = Row.unfold(editor.rows)
        let text = outline.isBlank && savedText.isEmpty ? "" : OutlineMarkdown.serialize(outline)
        guard text != savedText, !(text.isEmpty && savedText.isEmpty) else { return }
        savedText = text
        store.write(text, path: ref.path)
        styleHeader()
    }

    // MARK: Showing

    private var name: String {
        if let day = ref.day { return Self.dayTitle(day) }
        if let week = GraphPaths.week(fromWeeklyPath: ref.path) { return "Week \(week.week)" }
        return store?.index?.entry(ref.path)?.title ?? (ref.path as NSString).lastPathComponent
    }

    /// Whether its first row is its name: a top heading — even one not yet
    /// typed in, as a new note's is.
    private var titleIsHeading: Bool {
        guard ref.day == nil, let first = editor.rows.first, case .heading(1) = first.kind else { return false }
        return true
    }

    private func styleHeader() {
        let metrics = editor.metrics
        let today = ref.day == .today
        // Among others, a note whose heading says its name has it quietly
        // over it, as pieces of notes do: there to tap, not to read twice.
        let quiet = showsHeader && titleIsHeading
        header.setAttributedTitle(NSAttributedString(string: name, attributes: [
            .font: quiet ? metrics.face.heading(round(metrics.size * 0.95), weight: .semibold)
                : metrics.face.heading(round(metrics.face.size(metrics.size) * 1.3), weight: .bold),
            .foregroundColor: today ? Ink.accent : quiet ? Ink.secondary : Ink.text,
        ]), for: .normal)
        var notes: [String] = []
        if today { notes.append("Today") }
        if let week = GraphPaths.week(fromWeeklyPath: ref.path), let monday = week.monday, let sunday = week.sunday {
            notes.append(Self.span(monday, sunday))
        }
        badge.text = notes.joined(separator: " · ")
        badge.font = metrics.face.body(round(metrics.size * 0.85), weight: .medium)
        // Alone, a note whose first heading is its name needs no other.
        header.isHidden = !showsHeader && titleIsHeading
        badge.isHidden = header.isHidden || notes.isEmpty
        setNeedsLayout()
    }

    static func dayTitle(_ day: Day) -> String {
        guard let date = day.date else { return day.description }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(day.year == Day.today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
        return formatter.string(from: date)
    }

    static func span(_ from: Day, _ to: Day) -> String {
        guard let a = from.date, let b = to.date else { return "" }
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = "MMMd"
        return formatter.string(from: a, to: b)
    }

    // MARK: Layout

    static let side: CGFloat = 36
    /// Narrower than this, nothing is laid out: text at no width never ends.
    static let minimumWidth: CGFloat = 300

    private var headerHeight: CGFloat {
        header.isHidden ? 0 : ceil(header.intrinsicContentSize.height) + 6
    }

    func height(width: CGFloat) -> CGFloat {
        guard width > Self.minimumWidth else { return 0 }
        let editorWidth = width - 2 * Self.side + editor.metrics.indent
        let editorHeight = editor.rowsHeight(width: editorWidth)
        return 18 + headerHeight + editorHeight + 22
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > Self.minimumWidth else { return }
        let indent = editor.metrics.indent
        var y: CGFloat = 18
        if !header.isHidden {
            let size = header.intrinsicContentSize
            header.frame = CGRect(x: Self.side, y: y, width: min(size.width, bounds.width - 2 * Self.side - (accessory == nil ? 0 : 40)), height: ceil(size.height))
            let badgeSize = badge.intrinsicContentSize
            badge.frame = CGRect(x: header.frame.maxX + 8, y: header.frame.maxY - badgeSize.height - 4,
                                 width: min(badgeSize.width, bounds.width - header.frame.maxX - 8 - Self.side), height: badgeSize.height)
            y += headerHeight
        }
        accessory?.frame = CGRect(x: bounds.width - Self.side - 30, y: 18, width: 44, height: max(32, headerHeight - 6))
        // The text in line with the name; the markers hang in the margin.
        let width = bounds.width - 2 * Self.side + indent
        // The empty line after the last row hangs below the block: a text
        // view squeezed shorter than its text lays out forever.
        let height = editor.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        editor.frame = CGRect(x: Self.side - indent, y: y, width: width, height: height)
    }
}

/// How notes were left on this phone: their folds, and where each column was.
enum PhoneState {
    static func folds(_ path: String) -> [OutlineFolds.Mark] {
        guard let data = UserDefaults.standard.data(forKey: "Folds." + path),
              let marks = try? JSONDecoder().decode([OutlineFolds.Mark].self, from: data) else { return [] }
        return marks
    }

    static func setFolds(_ path: String, _ marks: [OutlineFolds.Mark]) {
        if marks.isEmpty {
            UserDefaults.standard.removeObject(forKey: "Folds." + path)
        } else if let data = try? JSONEncoder().encode(marks) {
            UserDefaults.standard.set(data, forKey: "Folds." + path)
        }
    }
}
