import UIKit
import ReflectCore
import PrismCore

/// A note in a sheet: its name over it — a day's date, a week's number, a
/// note's title when its first heading is not that — and its outline,
/// edited where it is, written a moment after typing stops.
final class NoteBlock: UIView {
    let ref: NoteRef
    /// Its editor: made when it is built — a text view is not cheap, and a
    /// sheet has dozens of notes not yet near.
    private(set) lazy var editor: OutlineEditor = makeEditor()
    private var storedMetrics: PhoneMetrics
    private let header = UIButton(type: .system)
    /// A button at the header's end: the inbox's Done.
    private(set) var accessory: UIButton?
    /// The note's own menu — pin, inbox, copy link — at the header's end.
    private let menuButton = UIButton(type: .system)
    /// What the ⋯ shows, asked for each time it opens.
    var noteMenu: (() -> UIMenu?)? {
        didSet { menuButton.isHidden = noteMenu == nil || header.isHidden; setNeedsLayout() }
    }
    /// In the editor's place while the note holds a sync conflict.
    private var conflict: ConflictView?
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
    /// Told when typing in it stopped.
    var onEditingEnd: (() -> Void)?
    /// Told when it wants another height.
    var onHeightChange: (() -> Void)?
    /// Whether its name shows over it: in a list of notes, yes; alone, only
    /// when its first heading does not say it.
    var showsHeader: Bool

    /// Whether its text is in the editor. Far from sight, a note is only
    /// read, and stands as tall as its lines guess: parsing, styling and
    /// laying out a note is what is dear, and a sheet has dozens.
    private(set) var isLive = false

    init(ref: NoteRef, store: PrismStore, metrics: PhoneMetrics, showsHeader: Bool, live: Bool = true) {
        self.ref = ref
        self.store = store
        self.showsHeader = showsHeader
        storedMetrics = metrics
        super.init(frame: .zero)
        header.contentHorizontalAlignment = .leading
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)), for: .normal)
        menuButton.tintColor = Ink.secondary
        menuButton.accessibilityLabel = "Note Menu"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.noteMenu?()?.children ?? [])
        }])
        menuButton.isHidden = true
        addSubview(menuButton)
        header.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        addSubview(header)
        if live {
            goLive()
        } else {
            savedText = store.text(ref.path)
            styleHeader()
        }
    }

    private func makeEditor() -> OutlineEditor {
        let editor = OutlineEditor(metrics: storedMetrics)
        addSubview(editor)
        editor.onChange = { [weak self] in self?.edited() }
        editor.onOpenLink = { [weak self] link in self?.onLink?(link) }
        editor.onCaretMove = { [weak self] in self?.onCaretMove?() }
        editor.onHeightChange = { [weak self] in
            self?.setNeedsLayout()
            self?.onHeightChange?()
        }
        editor.onFocusChange = { [weak self] focused in
            guard !focused else { return }
            self?.save()
            self?.onEditingEnd?()
        }
        return editor
    }

    /// Its text into the editor, to be seen and typed in.
    func goLive() {
        guard !isLive else { return }
        isLive = true
        load()
        styleHeader()
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var metrics: PhoneMetrics {
        get { storedMetrics }
        set {
            storedMetrics = newValue
            if isLive { editor.metrics = newValue }
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
        showConflict(in: text)
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
        guard isLive else {
            let text = store?.text(ref.path) ?? ""
            if text != savedText {
                savedText = text
                estimate = nil
                onHeightChange?()
            }
            return
        }
        guard !dirty, (store?.text(ref.path) ?? "") != savedText else { return }
        let caret = editor.caret
        load()
        if editor.isFirstResponder { editor.setCaret(caret) }
    }

    private func edited() {
        dirty = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    // MARK: Conflicts

    /// A note two devices wrote at once: both sides shown, to choose from,
    /// and the editor put away till then.
    private func showConflict(in text: String) {
        let conflicted = ConflictMarkers.detect(text)
        if conflicted {
            conflict?.removeFromSuperview()
            let view = ConflictView(source: text, metrics: storedMetrics) { [weak self] keep in self?.resolve(keeping: keep) }
            addSubview(view)
            conflict = view
        } else {
            conflict?.removeFromSuperview()
            conflict = nil
        }
        editor.isHidden = conflicted
        if conflicted, editor.isFirstResponder { editor.resignFirstResponder() }
        setNeedsLayout()
        onHeightChange?()
    }

    var hasConflict: Bool { conflict != nil }

    /// One side of every conflict in the note kept, or both: the file's
    /// text spliced, the markers never passing through the editor.
    private func resolve(keeping keep: ConflictMarkers.Resolution) {
        guard let store else { return }
        let source = store.text(ref.path)
        store.write(ConflictMarkers.resolve(source, keeping: keep), path: ref.path)
        load()
    }

    /// Writes the note, when it changed: a day not written in, left blank, stays unwritten.
    func save() {
        saveTimer?.invalidate()
        guard isLive else { return }
        guard dirty, let store, conflict == nil else { return }
        dirty = false
        // The folds with the note: kept as it is written, not each keystroke.
        let rows = editor.rows
        PhoneState.setFolds(ref.path, OutlineFolds.marks(rows))
        var outline = shell
        outline.rows = Row.unfold(rows)
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
        guard ref.day == nil else { return false }
        guard isLive else { return NoteIndex.entry(path: ref.path, source: savedText).titleIsHeading }
        guard let first = editor.firstRow, case .heading(1) = first.kind else { return false }
        return true
    }

    private func styleHeader() {
        header.setAttributedTitle(Card.header(name: name, meta: Card.meta(for: ref.path, store: store), size: storedMetrics.size), for: .normal)
        header.titleLabel?.lineBreakMode = .byTruncatingMiddle
        // Alone, a note whose first heading is its name needs no other.
        header.isHidden = !showsHeader && titleIsHeading
        setNeedsLayout()
    }

    static func dayTitle(_ day: Day) -> String {
        guard let date = day.date else { return day.description }
        return Formats.date(day.year == Day.today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy").string(from: date)
    }

    static func span(_ from: Day, _ to: Day) -> String {
        guard let a = from.date, let b = to.date else { return "" }
        return Formats.interval("MMMd").string(from: a, to: b)
    }

    // MARK: Layout

    static let side: CGFloat = 36
    /// Narrower than this, nothing is laid out: text at no width never ends.
    static let minimumWidth: CGFloat = 300

    private var headerHeight: CGFloat {
        header.isHidden ? 0 : ceil(header.intrinsicContentSize.height) + Card.gap
    }

    /// What its lines are guessed to take, before it is laid out.
    private var estimate: (width: CGFloat, height: CGFloat)?

    private func estimatedHeight(width: CGFloat) -> CGFloat {
        if let estimate, abs(estimate.width - width) < 0.5 { return estimate.height }
        let metrics = storedMetrics
        let line = round(metrics.face.lineHeight * metrics.size) + round(metrics.size * 0.32)
        let perLine = max(20, (width - 2 * Self.side) / (metrics.size * 0.52))
        var lines = 0.0
        var inFrontmatter = savedText.hasPrefix("---\n")
        for (i, text) in savedText.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if inFrontmatter {
                if i > 0 && text == "---" { inFrontmatter = false }
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("![") { lines += 8; continue }
            lines += max(1, ceil(Double(trimmed.count) / perLine))
        }
        let height = max(line, CGFloat(lines) * line)
        estimate = (width, height)
        return height
    }

    func height(width: CGFloat) -> CGFloat {
        guard width > Self.minimumWidth else { return 0 }
        guard isLive else { return Card.top + headerHeight + estimatedHeight(width: width) + Card.bottom }
        let editorWidth = width - 2 * Self.side + storedMetrics.indent
        let editorHeight = conflict.map { $0.height(width: width - 2 * Self.side) + 8 } ?? editor.rowsHeight(width: editorWidth)
        return Card.top + headerHeight + editorHeight + Card.bottom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > Self.minimumWidth else { return }
        let indent = storedMetrics.indent
        var y: CGFloat = Card.top
        if !header.isHidden {
            let size = header.intrinsicContentSize
            header.frame = CGRect(x: Self.side, y: y, width: min(size.width, bounds.width - 2 * Self.side - (accessory == nil ? 0 : 40) - 36), height: ceil(size.height))
            y += headerHeight
        }
        // The ⋯ at the header's end, on its middle; the inbox's Done before it.
        menuButton.isHidden = noteMenu == nil || header.isHidden
        let menuWidth: CGFloat = menuButton.isHidden ? 0 : 36
        menuButton.frame = CGRect(x: bounds.width - Self.side - 8, y: header.frame.midY - 18, width: 36, height: 36)
        accessory?.frame = CGRect(x: bounds.width - Self.side - 30 - menuWidth, y: Card.top - 6, width: 44, height: max(32, headerHeight - 6))
        // The text in line with the name; the markers hang in the margin.
        let width = bounds.width - 2 * Self.side + indent
        // The empty line after the last row hangs below the block: a text
        // view squeezed shorter than its text lays out forever.
        if let conflict {
            let inner = bounds.width - 2 * Self.side
            conflict.frame = CGRect(x: Self.side, y: y + 4, width: inner, height: conflict.height(width: inner))
            return
        }
        guard isLive else { return }
        let height = editor.fittingHeight(width: width)
        editor.frame = CGRect(x: Self.side - indent, y: y, width: width, height: height)
    }
}

/// How notes were left on this phone: their folds, and where each column was.
enum PhoneState {
    /// Where a note was left: how far into it, from its top, it was read,
    /// where the caret was, and whether it was being typed in — to open it
    /// there again, wherever it is opened from.
    struct NotePlace: Codable {
        var offset: CGFloat
        var caret: Int
        var editing: Bool
        var touched: Date
    }

    private static let placesKey = "NotePlaces"
    private static var places: [String: NotePlace] = {
        UserDefaults.standard.data(forKey: placesKey).flatMap { try? JSONDecoder().decode([String: NotePlace].self, from: $0) } ?? [:]
    }()
    private static var placesSaving = false

    static func place(_ path: String) -> NotePlace? { places[path] }

    static func setPlace(_ path: String, offset: CGFloat? = nil, caret: Int? = nil, editing: Bool? = nil) {
        var place = places[path] ?? NotePlace(offset: 0, caret: 0, editing: false, touched: Date())
        if let offset { place.offset = offset }
        if let caret { place.caret = caret }
        if let editing { place.editing = editing }
        place.touched = Date()
        places[path] = place
        // Written a moment later, once for many changes; the oldest let go.
        guard !placesSaving else { return }
        placesSaving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            placesSaving = false
            if places.count > 500 {
                for (path, _) in places.sorted(by: { $0.value.touched < $1.value.touched }).prefix(places.count - 500) { places[path] = nil }
            }
            if let data = try? JSONEncoder().encode(places) { UserDefaults.standard.set(data, forKey: placesKey) }
        }
    }

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

/// Date formatters, made once each: making one is slow, and a sheet names
/// dozens of days.
@MainActor
enum Formats {
    private static var dates: [String: DateFormatter] = [:]
    private static var intervals: [String: DateIntervalFormatter] = [:]

    static func date(_ template: String) -> DateFormatter {
        if let formatter = dates[template] { return formatter }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        dates[template] = formatter
        return formatter
    }

    static func interval(_ template: String) -> DateIntervalFormatter {
        if let formatter = intervals[template] { return formatter }
        let formatter = DateIntervalFormatter()
        formatter.dateTemplate = template
        intervals[template] = formatter
        return formatter
    }
}

/// A note's card, wherever notes are listed — the days, the inbox, the
/// pinned, the tasks, what a search found — headed as a post is in Threads:
/// its name in bold at the text's size, and beside it, in grey, when: a
/// day's distance from today, any other note's last change.
@MainActor
enum Card {
    /// A card's margins: above its header, between header and text, below.
    static let top: CGFloat = 16
    static let gap: CGFloat = 2
    static let bottom: CGFloat = 16

    static func header(name: String, meta: String?, size: CGFloat) -> NSAttributedString {
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: Ink.text,
        ])
        if let meta, !meta.isEmpty {
            text.append(NSAttributedString(string: "  " + meta, attributes: [
                .font: UIFont.systemFont(ofSize: size, weight: .regular), .foregroundColor: Ink.secondary,
            ]))
        }
        return text
    }

    /// When a note is: a day by how far it is from today, a week by its
    /// days, any other by when it last changed.
    static func meta(for path: String, store: PrismStore?) -> String? {
        if let day = GraphPaths.day(fromDailyPath: path) { return relative(day) }
        if let week = GraphPaths.week(fromWeeklyPath: path), let monday = week.monday, let sunday = week.sunday {
            return NoteBlock.span(monday, sunday)
        }
        return store?.index?.entry(path).map { ago($0.modified) }
    }

    /// `Today`, `Yesterday`, `Tomorrow`, `3d`, `in 3d`, `2w`, `5mo`, `2y`.
    static func relative(_ day: Day, today: Day = .today) -> String {
        guard let a = today.date, let b = day.date else { return "" }
        let days = Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0
        switch days {
        case 0: return "Today"
        case -1: return "Yesterday"
        case 1: return "Tomorrow"
        default:
            let n = abs(days)
            let amount = n < 14 ? "\(n)d" : n < 60 ? "\(n / 7)w" : n < 365 ? "\(n / 30)mo" : "\(n / 365)y"
            return days < 0 ? amount : "in " + amount
        }
    }

    /// `now`, `5m`, `22h`, `3d`, then the date: `Sep 28`, `Sep 28, 2024`.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            return Formats.date(sameYear ? "MMMd" : "MMMdyyyy").string(from: date)
        }
    }
}
