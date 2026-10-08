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
    var editor: OutlineEditor {
        if let editorStorage { return editorStorage }
        let editor = makeEditor()
        editorStorage = editor
        return editor
    }
    private var editorStorage: OutlineEditor?
    /// Its editor, when it is shown whole and edited where it is.
    var liveEditor: OutlineEditor? { mode == .full && isLive ? editorStorage : nil }
    private var storedMetrics: PhoneMetrics
    private let header = UIButton(type: .system)
    /// The card it is drawn on, and when it is, at its top right.
    private let card = CardBackground()
    private let metaLabel = UILabel()
    /// How far along its to-dos are, in the margin before its name.
    private let ringView = UIImageView()
    /// How the card shows the note: whole, short, or its name alone.
    private(set) var mode: CardMode = .full
    private var summaryView: CardSummaryView?
    private let cardTap = UITapGestureRecognizer()
    nonisolated(unsafe) private var modeObserver: NSObjectProtocol?
    /// A button at the header's end: the inbox's Done.
    private(set) var accessory: UIButton?
    /// The note's own menu — pin, inbox, copy link — at the header's end.
    private let menuButton = UIButton(type: .system)
    /// What the ⋯ shows, asked for each time it opens.
    var noteMenu: (() -> UIMenu?)? {
        didSet { setNeedsLayout() }
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
        addSubview(card)
        Card.styleMeta(metaLabel, size: metrics.size)
        addSubview(metaLabel)
        ringView.isHidden = true
        addSubview(ringView)
        // Listed, a note shows as it was last asked to; alone, whole.
        if showsHeader {
            mode = CardModes.mode(ref.path)
            modeObserver = NotificationCenter.default.addObserver(forName: CardModes.changed, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, note.object as? String == self.ref.path else { return }
                    self.setMode(CardModes.mode(self.ref.path))
                }
            }
        }
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
        // Not whole: the card tapped anywhere opens the note.
        cardTap.addTarget(self, action: #selector(cardTapped))
        cardTap.isEnabled = false
        addGestureRecognizer(cardTap)
        // Held: the note's menu, on any card — its ⋯ shows only on the one typed in.
        header.addInteraction(UIContextMenuInteraction(delegate: self))
        addSubview(header)
        if live && mode == .full {
            goLive()
        } else {
            savedText = store.text(ref.path)
            styleHeader()
            updateSummary()
        }
    }

    deinit {
        if let modeObserver { NotificationCenter.default.removeObserver(modeObserver) }
    }

    // MARK: Showing as

    /// Shows the note whole, short, or by its name alone: what is typed
    /// in it written first, its editor let go when not whole.
    func setMode(_ new: CardMode) {
        guard new != mode else { return }
        if mode == .full, isLive, let editor = editorStorage {
            if editor.isFirstResponder { _ = editor.resignFirstResponder() }
            save()
            editor.removeFromSuperview()
            editorStorage = nil
            isLive = false
        }
        mode = new
        estimate = nil
        ahead = nil
        updateSummary()
        styleHeader()
        if new == .full, !isHidden, bounds.width > Self.minimumWidth { goLive() }
        setNeedsLayout()
        onHeightChange?()
    }

    @objc private func cardTapped() { onOpen?() }

    /// The short form, made or let go as the mode says, from what is on disk.
    private func updateSummary() {
        cardTap.isEnabled = mode != .full
        guard mode == .summary else {
            summaryView?.removeFromSuperview()
            summaryView = nil
            return
        }
        let view = summaryView ?? {
            let view = CardSummaryView(metrics: storedMetrics)
            view.onResize = { [weak self] in
                self?.setNeedsLayout()
                self?.onHeightChange?()
            }
            view.isUserInteractionEnabled = false
            addSubview(view)
            summaryView = view
            return view
        }()
        view.show(NoteSummary.of(savedText, title: name))
    }

    private func makeEditor() -> OutlineEditor {
        let editor = OutlineEditor(metrics: storedMetrics)
        editor.day = ref.day
        addSubview(editor)
        editor.onChange = { [weak self] in self?.edited() }
        editor.onOpenLink = { [weak self] link in self?.onLink?(link) }
        editor.onCaretMove = { [weak self] in self?.onCaretMove?() }
        editor.onHeightChange = { [weak self] in
            self?.setNeedsLayout()
            self?.onHeightChange?()
        }
        editor.onFocusChange = { [weak self] focused in
            self?.setNeedsLayout()
            guard !focused else { return }
            self?.save()
            self?.onEditingEnd?()
        }
        return editor
    }

    /// Building ahead, off the main thread: under way.
    private(set) var preparing = false
    private static let building = DispatchQueue(label: "prism.build", qos: .userInitiated)

    /// Its text read, parsed, styled and laid out off the main thread, and
    /// kept — for a note coming near, before it is in sight — to be put in
    /// the editor once it is: cheap then, and drawn as seen. (A text view
    /// first laid out out of sight draws its whole text as one picture: a
    /// long day, a hundred megabytes.) Its height known exactly meanwhile.
    func prepareLive(width: CGFloat) {
        guard mode == .full, !isLive, !preparing, store != nil, width > Self.minimumWidth else { return }
        if let ahead, ahead.text == savedText, ahead.metrics == storedMetrics, abs(ahead.width - width) < 0.5 { return }
        preparing = true
        build(width: width) { [weak self] text, shell, prepared, metrics in
            guard let self else { return }
            self.preparing = false
            if !self.isLive, let prepared, text == self.savedText, metrics == self.storedMetrics {
                self.ahead = Ahead(text: text, shell: shell, prepared: prepared, width: width, metrics: metrics)
                self.estimate = (width, prepared.rows)
            }
            // Its height as built, or the sheet to ask again and build it
            // the plain way if in sight.
            if !self.isLive { self.onHeightChange?() }
        }
    }

    /// A note built ahead, not yet put in its editor.
    private struct Ahead {
        var text: String
        var shell: Outline
        var prepared: OutlineEditor.Prepared
        var width: CGFloat
        var metrics: PhoneMetrics
    }
    private var ahead: Ahead?

    /// The note read, parsed, styled and laid out at a width on the build
    /// queue; what came of it handed back on the main thread — no editor
    /// when it holds a conflict, which is shown another way.
    private func build(width: CGFloat, done: @escaping @MainActor (String, Outline, OutlineEditor.Prepared?, PhoneMetrics) -> Void) {
        let path = ref.path, isDay = ref.day != nil, metrics = storedMetrics, graph = store?.graph, showsHeader = showsHeader
        let editorWidth = width - 2 * Self.side + metrics.indent
        Self.building.async {
            let text = graph?.read(path: path) ?? ""
            let shell = OutlineMarkdown.parse(text)
            var rows = shell.rows
            if rows.isEmpty || isDay && rows.allSatisfy({ $0.text.isEmpty && $0.kind != .code }) {
                rows = rows.isEmpty ? [.blank] : rows
            }
            let folds = PhoneState.folds(path)
            if !folds.isEmpty { rows = OutlineFolds.apply(folds, to: rows) }
            let prepared = ConflictMarkers.detect(text) ? nil
                : OutlineEditor.prepare(rows, metrics: metrics, width: editorWidth,
                                        hidesTitle: Self.hidesTitle(path: path, text: text, showsHeader: showsHeader))
            DispatchQueue.main.async { MainActor.assumeIsolated { done(text, shell, prepared, metrics) } }
        }
    }

    /// Text built ahead put in the editor.
    private func put(_ prepared: OutlineEditor.Prepared, shell: Outline, width: CGFloat) {
        self.shell = shell
        // At its width first: an editor at none lays the text out again at
        // a guess, then again at its width, on this thread.
        placeEditor(width: width, height: prepared.fit)
        editor.install(prepared)
        dirty = false
        styleHeader()
        setNeedsLayout()
        onHeightChange?()
    }

    /// Far from sight again: its editor let go — and the room its text
    /// took drawn — standing as tall as it was till it comes near again.
    /// Not while typed in, nor with writing not yet saved.
    func sleep() {
        guard isLive, !preparing, let editor = editorStorage, !editor.isFirstResponder, conflict == nil,
              bounds.width > Self.minimumWidth else { return }
        save()
        guard !dirty else { return }
        let width = bounds.width, editorWidth = width - 2 * Self.side + storedMetrics.indent
        let rows = editor.rowsHeight(width: editorWidth)
        // Its text kept as built, to be put back in a moment when it comes near.
        ahead = Ahead(text: savedText, shell: shell,
                      prepared: .init(text: NSAttributedString(attributedString: editor.textStorage), width: editorWidth,
                                      fit: editor.fittingHeight(width: editorWidth), rows: rows, hidesTitle: editor.hidesTitle),
                      width: width, metrics: storedMetrics)
        estimate = (width, rows)
        editor.removeFromSuperview()
        editorStorage = nil
        isLive = false
    }

    /// Its text into the editor, to be seen and typed in.
    func goLive() {
        guard mode == .full, !isLive else { return }
        isLive = true
        // Built ahead, and still as it was built: put in, not built again.
        if let ahead, ahead.text == savedText, ahead.metrics == storedMetrics, abs(ahead.width - bounds.width) < 0.5 {
            self.ahead = nil
            put(ahead.prepared, shell: ahead.shell, width: ahead.width)
            return
        }
        ahead = nil
        if bounds.width > Self.minimumWidth { placeEditor(width: bounds.width, height: editor.frame.height) }
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
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: round(storedMetrics.size * 0.88), weight: .regular)), for: .normal)
        button.tintColor = Ink.secondary
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        addSubview(button)
        accessory = button
        // The margin the Done's now: the ring after the name.
        styleHeader()
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
        editor.hidesTitle = Self.hidesTitle(path: ref.path, text: text, showsHeader: showsHeader)
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
                ahead = nil
                updateSummary()
                styleHeader()
                onHeightChange?()
            }
            return
        }
        let text = store?.text(ref.path) ?? ""
        guard text != savedText else { return }
        // Written here and not saved: saved now, merged with what came in.
        guard !dirty else { return save() }
        // Out of sight: let go, to be built again as it comes near — not
        // laid out where it is not seen.
        if isHidden, let editor = editorStorage, !editor.isFirstResponder, conflict == nil {
            editor.removeFromSuperview()
            editorStorage = nil
            isLive = false
            savedText = text
            estimate = nil
            ahead = nil
            onHeightChange?()
            return
        }
        // Not being typed in, and plain: built again off the main thread —
        // a sync bringing in changes to the notes in sight, no stutter.
        if !editor.isFirstResponder, conflict == nil, !ConflictMarkers.detect(text), bounds.width > Self.minimumWidth {
            let width = bounds.width
            savedText = text
            reloading += 1
            let generation = reloading
            build(width: width) { [weak self] built, shell, prepared, metrics in
                guard let self, generation == self.reloading else { return }
                // Typed in meanwhile: the typing kept, as when it came first.
                guard !self.dirty else { return }
                // Changed again, being typed in, or not plain after all: the plain way.
                guard let prepared, built == self.savedText, !self.editor.isFirstResponder,
                      metrics == self.storedMetrics, abs(self.bounds.width - width) < 0.5 else {
                    let caret = self.editor.caret, editing = self.editor.isFirstResponder
                    self.load()
                    if editing { self.editor.setCaret(caret) }
                    return
                }
                self.put(prepared, shell: shell, width: width)
            }
            return
        }
        let caret = editor.caret
        load()
        if editor.isFirstResponder { editor.setCaret(caret) }
    }

    /// Each reload built off the main thread, counted: only the last put in.
    private var reloading = 0

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
        // Changed on disk since it was read — a sync brought another
        // device's writing in — merged, not written over: both kept, and
        // where both changed the same lines, both between markers.
        let disk = store.text(ref.path)
        let merged = disk == savedText || disk == text ? TextMerge.Result(text: text, conflicted: false)
            : TextMerge.merge(base: savedText, ours: text, theirs: disk)
        savedText = merged.text
        store.write(merged.text, path: ref.path)
        if merged.text != text {
            // What came in shown too, the caret where it was.
            let caret = editor.caret, editing = editor.isFirstResponder && !merged.conflicted
            load()
            if editing { editor.setCaret(caret) }
        }
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
        let title = NSMutableAttributedString(attributedString: Card.header(name: name, meta: nil, size: storedMetrics.size))
        metaLabel.text = Card.meta(for: ref.path, store: store)
        metaLabel.sizeToFit()
        // Its to-dos, how far along, at the end of its name.
        let text = isLive ? nil : savedText
        let progress = text.map { Checkboxes.progress(in: $0) } ?? {
            let all = Checkboxes.progress(of: editor.rows)
            return all.isEmpty ? nil : all
        }()
        // How far along, in the margin where the rows' bullets are — the
        // name in line with the text under it. With the inbox's Done there,
        // after the name instead.
        ringView.isHidden = true
        if let progress {
            let side = round(storedMetrics.size * 0.85)
            let image = ProgressRing.image(progress, side: side)
            if accessory == nil {
                ringView.image = image
                ringView.isHidden = false
                ringView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            } else {
                let ring = NSTextAttachment(image: image)
                let cap = Typeface.current.heading(storedMetrics.size, weight: .bold).capHeight
                ring.bounds = CGRect(x: 0, y: ((cap - side) / 2).rounded(), width: side, height: side)
                title.append(NSAttributedString(string: "  "))
                title.append(NSAttributedString(attachment: ring))
            }
        }
        header.setAttributedTitle(title, for: .normal)
        // The note's name, whole: in a card, the only place it shows.
        header.titleLabel?.numberOfLines = 0
        header.titleLabel?.lineBreakMode = .byWordWrapping
        // Alone, a note whose first heading is its name needs no other.
        header.isHidden = !showsHeader && titleIsHeading
        metaLabel.isHidden = header.isHidden
        headerMeasure = nil
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

    static let side: CGFloat = 38
    /// Narrower than this, nothing is laid out: text at no width never ends.
    static let minimumWidth: CGFloat = 300

    private func headerHeight(width: CGFloat) -> CGFloat {
        header.isHidden ? 0 : ceil(headerSize(width: width).height) + Card.gap
    }

    /// The header's size at a block's width — the room left of the ⋯ —
    /// kept: measuring its text is not free, and a sheet asks every note
    /// its height often.
    private func headerSize(width: CGFloat) -> CGSize {
        if let headerMeasure, abs(headerMeasure.width - width) < 0.5 { return headerMeasure.size }
        let room = width - 2 * Self.side - max(36, ceil(metaLabel.bounds.width) + 12)
        let bounds = header.attributedTitle(for: .normal)?.boundingRect(with: CGSize(width: room, height: .greatestFiniteMagnitude),
                                                                         options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil) ?? .zero
        // A little over: the label wraps what only just fits, a ring at its end.
        let size = CGSize(width: min(ceil(bounds.width) + 4, room), height: ceil(bounds.height))
        headerMeasure = (width, size)
        return size
    }
    private var headerMeasure: (width: CGFloat, size: CGSize)?

    /// Whether a card hides a note's title row: its header says it — a note
    /// named by its first heading, in a list. Any thread.
    nonisolated static func hidesTitle(path: String, text: String, showsHeader: Bool) -> Bool {
        showsHeader && GraphPaths.day(fromDailyPath: path) == nil && GraphPaths.week(fromWeeklyPath: path) == nil
            && NoteIndex.entry(path: path, source: text).titleIsHeading
    }

    /// What its lines are guessed to take, before it is laid out.
    private var estimate: (width: CGFloat, height: CGFloat)?

    private func estimatedHeight(width: CGFloat) -> CGFloat {
        if let estimate, abs(estimate.width - width) < 0.5 { return estimate.height }
        let metrics = storedMetrics
        let line = round(metrics.lineHeight * metrics.size) + metrics.rowGap
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
        switch mode {
        case .collapsed:
            return Card.top + headerHeight(width: width) - Card.gap + Card.bottom
        case .summary:
            let summary = summaryView?.height(width: width - 2 * Self.side) ?? 0
            return Card.top + headerHeight(width: width) + (summary > 0 ? summary + 4 : -Card.gap) + Card.bottom
        case .full, .view:
            break
        }
        guard isLive else { return Card.top + headerHeight(width: width) + estimatedHeight(width: width) + Card.bottom }
        let editorWidth = width - 2 * Self.side + storedMetrics.indent
        let editorHeight = conflict.map { $0.height(width: width - 2 * Self.side) + 8 } ?? editor.rowsHeight(width: editorWidth)
        return Card.top + headerHeight(width: width) + editorHeight + Card.bottom
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > Self.minimumWidth else { return }
        card.frame = Card.frame(in: bounds)
        let indent = storedMetrics.indent
        var y: CGFloat = Card.top
        if !header.isHidden {
            let size = headerSize(width: bounds.width)
            header.frame = CGRect(x: Self.side, y: y, width: size.width, height: size.height)
            y += headerHeight(width: bounds.width)
        }
        // The ⋯ at the header's end, on its first line's middle; the inbox's
        // Done hanging in the margin before the name, as a task's box does.
        let firstLine = Card.top + ceil(Typeface.current.heading(storedMetrics.size, weight: .bold).lineHeight) / 2
        // The ⋯ only on the card being typed in; held, any card's header has it.
        menuButton.isHidden = noteMenu == nil || header.isHidden || !(isLive && editor.isFirstResponder)
        menuButton.frame = CGRect(x: bounds.width - Self.side - 8, y: firstLine - 18, width: 36, height: 36)
        // When, at the top right; the ⋯ in its place while typed in.
        let metaSize = metaLabel.bounds.size
        metaLabel.frame = CGRect(x: bounds.width - Self.side - metaSize.width, y: (firstLine - metaSize.height / 2).rounded(),
                                 width: metaSize.width, height: metaSize.height)
        metaLabel.alpha = menuButton.isHidden ? 1 : 0
        if let summaryView {
            let inner = bounds.width - 2 * Self.side
            summaryView.frame = CGRect(x: Self.side, y: y + 4, width: inner, height: summaryView.height(width: inner))
        }
        accessory?.frame = CGRect(x: Self.side - 28, y: firstLine - 16, width: 32, height: 32)
        // On the bullets' line down the margin, and the name's middle.
        ringView.center = CGPoint(x: Self.side - storedMetrics.indent / 2, y: firstLine)
        ringView.isHidden = ringView.image == nil || header.isHidden || ringView.isHidden
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
        let frame = CGRect(x: Self.side - indent, y: y, width: width, height: height)
        if editor.frame != frame { editor.frame = frame }
    }

    /// The editor set at the width the block's is at, before text goes in.
    private func placeEditor(width: CGFloat, height: CGFloat) {
        let indent = storedMetrics.indent
        editor.frame = CGRect(x: Self.side - indent, y: editor.frame.minY, width: width - 2 * Self.side + indent, height: max(height, 1))
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
    /// A card's edge, in from its block's sides; the room above and below
    /// it, half the space between two cards.
    static let inset: CGFloat = 10
    static let spacing: CGFloat = 6
    static let radius: CGFloat = 18
    /// A block's margins: above its header, between header and text, below
    /// — the card's own and the space outside it.
    static let top: CGFloat = spacing + 16
    static let gap: CGFloat = 6
    static let bottom: CGFloat = 14 + spacing

    /// Where a block's card is, in it.
    static func frame(in bounds: CGRect) -> CGRect {
        CGRect(x: inset, y: spacing, width: max(0, bounds.width - 2 * inset), height: max(0, bounds.height - 2 * spacing))
    }

    /// When, at a card's top right, in the font set's face.
    static func styleMeta(_ label: UILabel, size: CGFloat) {
        label.font = Typeface.current.body(round(size * 0.88))
        label.textColor = Ink.secondary
        label.textAlignment = .right
    }

    /// The name in the font set's heading face, as on the Mac.
    static func header(name: String, meta: String?, size: CGFloat) -> NSAttributedString {
        let face = Typeface.current
        let text = NSMutableAttributedString(string: name, attributes: [
            .font: face.heading(size, weight: .bold), .foregroundColor: Ink.text,
        ])
        if let meta, !meta.isEmpty {
            text.append(NSAttributedString(string: "  " + meta, attributes: [
                .font: face.body(size), .foregroundColor: Ink.secondary,
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

extension NoteBlock: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = noteMenu?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
