import AppKit
import ReflectCore

/// The window's left column, as a Mac source list, in one of three modes —
/// as Drafter has Inbox, Archive and Timeline: the notes — the pinned, in
/// Reflect's order, then the rest as they were last edited; a search of every note, whose results stay listed until
/// it is cleared, and are there again next time; and the graph's tags, each
/// a search for its notes.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate {
    enum Mode: Int, CaseIterable {
        case notes, search, tags, backlinks

        var title: String { ["Notes", "Search", "Tags", "Backlinks"][rawValue] }
        /// What its segment says: short, so four fit the narrowest sidebar.
        var label: String { ["Notes", "Search", "Tags", "Links"][rawValue] }
    }

    /// A row: something to open, a section's heading, or words in place of rows.
    enum Row {
        case header(String)
        case pinned(NoteEntry)
        /// A note lately edited.
        case recent(NoteEntry)
        case result(OpenQuickly.Item)
        case tag(name: String, count: Int)
        /// A note linking to the one shown, and a link's context in it.
        case source(NoteEntry)
        case backlink(path: String, BacklinkContext)
        case hint(String)
    }

    let index: NoteIndex
    private let search: ReflectSearchIndex?
    private let pictures: ImageTextIndex?
    private let root: URL

    /// Told what to open, whether in the split view, and what was found there.
    var onOpen: ((OpenQuickly.Target, _ inSplit: Bool, _ found: OutlineTextView.Found?) -> Void)?
    /// Told to pin a note, or take its pin away.
    var onPin: ((_ path: String, _ pinned: Bool) -> Void)?
    /// Told to open a note in a window of its own.
    var onOpenInWindow: ((String) -> Void)?
    /// Told to move a note to the Trash, once asked.
    var onTrash: ((String) -> Void)?
    /// Told to give pinned notes new numbers, to put the shelf in a new order.
    var onReorder: (([PinOrder.Pin]) -> Void)?

    /// How the tags are listed.
    enum TagOrder: Int, CaseIterable {
        case name, count

        var title: String { ["Name", "Number of Notes"][rawValue] }
    }

    private(set) var mode: Mode = .notes
    /// How many of the notes lately edited Notes lists.
    private static let recentCount = 60
    private(set) var tagOrder: TagOrder = TagOrder(rawValue: UserDefaults.standard.integer(forKey: SidebarViewController.tagOrderKey)) ?? .name
    private let tagSort = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modes = NSSegmentedControl(labels: Mode.allCases.map(\.label), trackingMode: .selectOne, target: nil, action: nil)
    private let field = NSSearchField()
    private let table = SidebarTableView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    /// The search's results so far, found in the background.
    private var found: [Row] = []
    private var runner: SearchRunner!
    /// The table's top: under the search field in Search, else under the modes.
    private var underField: NSLayoutConstraint!
    private var underModes: NSLayoutConstraint!

    private static let modeKey = "SidebarMode"
    /// The note whose backlinks are shown, and what was found for it.
    private(set) var linked: String?
    private var backlinks: [Row] = []
    private var backlinkGeneration = 0
    fileprivate static let tagOrderKey = "SidebarTagOrder"
    /// The table's top in Tags: under the sort.
    private var underSort: NSLayoutConstraint!

    init(index: NoteIndex, search: ReflectSearchIndex?, pictures: ImageTextIndex?, root: URL) {
        self.index = index
        self.search = search
        self.pictures = pictures
        self.root = root
        super.init(nibName: nil, bundle: nil)
        runner = SearchRunner(sources: SearchSources(index: index, search: search, pictures: pictures))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        modes.target = self
        modes.action = #selector(modeChanged(_:))
        modes.segmentDistribution = .fillEqually
        modes.controlSize = .regular
        for mode in Mode.allCases { modes.setToolTip("\(mode.title) (⌘\(mode.rawValue + 1))", forSegment: mode.rawValue) }
        modes.translatesAutoresizingMaskIntoConstraints = false
        // It fits the sidebar, and never widens it past its divider.
        modes.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        container.addSubview(modes)

        field.placeholderString = "Search All Notes"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        tagSort.controlSize = .small
        tagSort.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tagSort.isBordered = false
        for order in TagOrder.allCases {
            tagSort.addItem(withTitle: "Sort by " + order.title)
            tagSort.lastItem?.tag = order.rawValue
        }
        tagSort.selectItem(withTag: tagOrder.rawValue)
        tagSort.target = self
        tagSort.action = #selector(tagSortChanged(_:))
        tagSort.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tagSort)

        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.usesAutomaticRowHeights = true
        table.allowsTypeSelect = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        // Double-clicked, as in Mail or the Finder: a window of its own.
        table.doubleAction = #selector(doubleClicked(_:))
        table.registerForDraggedTypes([Self.pinType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.onReturn = { [weak self] in self?.openSelected(inSplit: NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        underField = scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6)
        underModes = scroll.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 8)
        underSort = scroll.topAnchor.constraint(equalTo: tagSort.bottomAnchor, constant: 2)
        NSLayoutConstraint.activate([
            tagSort.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 6),
            tagSort.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            modes.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            modes.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            modes.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container

        field.stringValue = SessionState.shared.graph(root).search ?? ""
        found = results(for: "")
        show(Mode(rawValue: UserDefaults.standard.integer(forKey: Self.modeKey)) ?? .notes)
        research()
    }

    // MARK: Modes

    @objc private func modeChanged(_ sender: Any?) {
        show(Mode(rawValue: modes.selectedSegment) ?? .notes)
    }

    /// Shows a mode: its rows, and in Search, the field.
    func show(_ mode: Mode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        modes.selectedSegment = mode.rawValue
        let searching = mode == .search, tagging = mode == .tags
        field.isHidden = !searching
        tagSort.isHidden = !tagging
        underModes.isActive = false
        underField.isActive = false
        underSort.isActive = false
        (searching ? underField : tagging ? underSort : underModes).isActive = true
        reload()
        table.scrollRowToVisible(0)
    }

    // MARK: What is shown

    /// Reads the mode's rows again: pins and tags as they are now, and the
    /// search run again.
    func reload() {
        guard isViewLoaded else { return }
        let selected = table.selectedRow >= 0 && table.selectedRow < rows.count ? key(rows[table.selectedRow]) : nil
        switch mode {
        case .notes:
            let pinned = index.pinned
            let pinnedPaths = Set(pinned.map(\.path))
            let recent = index.all.filter { !pinnedPaths.contains($0.path) }
                .sorted { $0.modified > $1.modified }.prefix(Self.recentCount)
            rows = [.header("Pinned")] + (pinned.isEmpty ? [.hint("Pin a note with ⇧⌘P")] : pinned.map(Row.pinned))
                + [.header("Recent")] + recent.map(Row.recent)
        case .search:
            rows = found
        case .backlinks:
            rows = backlinks
        case .tags:
            var tags = index.tags
            if tagOrder == .count {
                // Most used first; the same count, by name.
                tags.sort { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            let rows = tags.map { Row.tag(name: $0.name, count: $0.count) }
            self.rows = rows.isEmpty ? [.hint("No #tags in any note")] : rows
        }
        table.reloadData()
        if let selected, let row = rows.firstIndex(where: { key($0) == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

    // MARK: Backlinks

    /// Shows the backlinks of a note — the one the keyboard is in — found in
    /// the background; the last found stay until the new ones come.
    func follow(_ path: String?, force: Bool = false) {
        guard force || path != linked else { return }
        linked = path
        backlinkGeneration += 1
        let generation = backlinkGeneration
        guard let path else {
            backlinks = [.hint("Backlinks of the note you are in show here")]
            if mode == .backlinks { reload() }
            return
        }
        let index = index
        DispatchQueue.global(qos: .userInitiated).async {
            let sources = index.backlinks(to: path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == backlinkGeneration else { return }
                    let title = index.entry(path).map { $0.day.map(OpenQuickly.dayTitle) ?? $0.title }
                        ?? GraphPaths.day(fromDailyPath: path).map(OpenQuickly.dayTitle) ?? path
                    var rows: [Row] = [.header("Linked to \(title)")]
                    if sources.isEmpty { rows.append(.hint("No notes link here")) }
                    for source in sources {
                        let entry = index.entry(source.path) ?? NoteIndex.entry(path: source.path, source: "")
                        rows.append(.source(entry))
                        rows += source.contexts.map { .backlink(path: source.path, $0) }
                    }
                    backlinks = rows
                    if mode == .backlinks { reload() }
                }
            }
        }
    }

    /// Looks again for what the field holds: a `#tag`'s notes at once,
    /// anything else in the background, shown as it comes.
    private func research() {
        let query = query
        guard !query.isEmpty, !(query.hasPrefix("#") && !query.contains(" ") && query.count > 1) else {
            runner.cancel()
            found = results(for: query)
            if mode == .search { reload() }
            return
        }
        runner.run(query) { [weak self] items, done in
            guard let self else { return }
            let results = items.filter { if case .create = $0.target { false } else { true } }
            found = results.isEmpty ? [.hint(done ? "No results" : "Searching…")] : results.map(Row.result)
            if mode == .search { reload() }
        }
    }

    private func results(for query: String) -> [Row] {
        guard !query.isEmpty else { return [.hint("Results stay here until the search is cleared")] }
        // `#tag`, alone: the notes with that tag.
        if query.hasPrefix("#"), !query.contains(" "), query.count > 1 {
            let notes = index.notes(tagged: String(query.dropFirst()))
            guard !notes.isEmpty else { return [.hint("No notes tagged \(query)")] }
            return notes.map { entry in
                let target: OpenQuickly.Target = entry.day.map { .day($0) } ?? .note(entry.path)
                let title = entry.day.map(OpenQuickly.dayTitle) ?? entry.title
                return .result(OpenQuickly.Item(target: target, title: title, detail: nil,
                                                symbol: entry.day == nil ? "doc.text" : "calendar", found: .words([query])))
            }
        }
        return []
    }

    @objc private func tagSortChanged(_ sender: NSPopUpButton) {
        sort(tagsBy: TagOrder(rawValue: sender.selectedTag()) ?? .name)
    }

    /// Lists the tags by name, or by how many notes have them.
    func sort(tagsBy order: TagOrder) {
        tagOrder = order
        UserDefaults.standard.set(order.rawValue, forKey: Self.tagOrderKey)
        tagSort.selectItem(withTag: order.rawValue)
        if mode == .tags {
            reload()
            table.scrollRowToVisible(0)
        }
    }

    @objc private func searchChanged(_ sender: Any?) {
        SessionState.shared.update(root) { $0.search = query.isEmpty ? nil : query }
        research()
    }

    /// Searches again — the notes have changed — keeping the results shown
    /// until the new ones come.
    func refreshSearch() {
        research()
    }

    /// Search, with the keyboard in the field.
    func focusSearch() {
        if mode != .search { show(.search) }
        view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    /// Searches for something, as if typed.
    func search(for text: String) {
        field.stringValue = text
        searchChanged(nil)
        if mode != .search { show(.search) }
    }

    /// Search, for a tag's notes.
    func show(tag: String) {
        search(for: "#" + tag)
    }

    /// The rows shown, for scripts.
    var shownRows: [String] {
        ["[\(mode.title)]"] + rows.map { row in
            switch row {
            case .header(let title): "[\(title)]"
            case .pinned(let entry): "pin " + entry.title
            case .source(let entry): "source " + entry.title
            case .backlink(_, let context): "  " + context.rows.map(\.text).joined(separator: " / ")
            case .recent(let entry): "recent " + entry.title
            case .result(let item): "result " + item.title + (item.detail.map { " — " + $0.string.prefix(40) } ?? "")
            case .tag(let name, let count): "#\(name) \(count)"
            case .hint(let text): "(\(text))"
            }
        }
    }

    /// Opens a row as a click would, by what it says. For scripts.
    func openRow(containing text: String, inSplit: Bool = false) {
        for (index, row) in rows.enumerated() {
            let title: String
            switch row {
            case .pinned(let entry), .recent(let entry), .source(let entry): title = entry.title
            case .backlink(_, let context): title = context.rows.map(\.text).joined(separator: " ")
            case .result(let item): title = item.title
            case .tag(let name, _): title = "#" + name
            case .hint, .header: continue
            }
            if title.contains(text) {
                table.selectRowIndexes([index], byExtendingSelection: false)
                open(row, inSplit: inSplit)
                return
            }
        }
        print("script: no sidebar row with \(text)")
    }

    // MARK: Opening

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        open(rows[table.clickedRow], inSplit: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard table.clickedRow >= 0, table.clickedRow < rows.count, let path = path(of: rows[table.clickedRow]) else { return }
        onOpenInWindow?(path)
    }

    /// The note a row is of, if any.
    private func path(of row: Row) -> String? {
        switch row {
        case .pinned(let entry), .recent(let entry), .source(let entry): return entry.path
        case .backlink(let source, _): return source
        case .result(let item):
            switch item.target {
            case .note(let note): return note
            case .day(let day): return GraphPaths.dailyPath(for: day)
            case .create: return nil
            }
        default: return nil
        }
    }

    private func openSelected(inSplit: Bool) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        open(rows[table.selectedRow], inSplit: inSplit)
    }

    private func open(_ row: Row, inSplit: Bool) {
        switch row {
        case .pinned(let entry), .recent(let entry), .source(let entry):
            onOpen?(entry.day.map { .day($0) } ?? .note(entry.path), inSplit, nil)
        case .backlink(let path, let context):
            // To the note, at the link.
            onOpen?(OpenQuickly.target(for: path), inSplit, .words([context.link]))
        case .result(let item):
            onOpen?(item.target, inSplit, item.found)
        case .tag(let name, _):
            show(tag: name)
        case .hint, .header:
            break
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if mode == .tags {
            for order in TagOrder.allCases {
                let item = ClosureMenuItem(title: "Sort by " + order.title) { [weak self] in self?.sort(tagsBy: order) }
                item.state = order == tagOrder ? .on : .off
                menu.addItem(item)
            }
            return
        }
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        let row = rows[table.clickedRow]
        let path: String?
        switch row {
        case .pinned(let entry), .recent(let entry), .source(let entry): path = entry.path
        case .backlink(let source, _): path = source
        case .result(let item):
            switch item.target {
            case .note(let note): path = note
            case .day(let day): path = GraphPaths.dailyPath(for: day)
            case .create: path = nil
            }
        default: path = nil
        }
        guard let path else { return }
        menu.addItem(ClosureMenuItem(title: "Open") { [weak self] in self?.open(row, inSplit: false) })
        menu.addItem(ClosureMenuItem(title: "Open in Split View") { [weak self] in self?.open(row, inSplit: true) })
        menu.addItem(ClosureMenuItem(title: "Open in New Window") { [weak self] in self?.onOpenInWindow?(path) })
        menu.addItem(.separator())
        let isPinned = index.entry(path)?.pin != nil
        menu.addItem(ClosureMenuItem(title: isPinned ? "Unpin" : "Pin") { [weak self] in self?.onPin?(path, !isPinned) })
        if GraphPaths.day(fromDailyPath: path) == nil {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Move to Trash…") { [weak self] in self?.onTrash?(path) })
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .hint, .header: false
        default: true
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let cell = tableView.makeView(withIdentifier: HeaderCell.identifier, owner: nil) as? HeaderCell ?? HeaderCell()
            cell.textField?.stringValue = title
            return cell
        case .pinned(let entry):
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(title: entry.day.map(OpenQuickly.dayTitle) ?? entry.title, detail: nil,
                      symbol: entry.day == nil ? "pin" : "calendar", badge: nil)
            return cell
        case .source(let entry):
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(title: entry.day.map(OpenQuickly.dayTitle) ?? entry.title, detail: nil,
                      symbol: entry.day == nil ? "doc.text" : "calendar", badge: nil)
            return cell
        case .backlink(_, let context):
            let cell = tableView.makeView(withIdentifier: ContextCell.identifier, owner: nil) as? ContextCell ?? ContextCell()
            cell.show(BacklinkText.attributed(context))
            return cell
        case .recent(let entry):
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(title: entry.day.map(OpenQuickly.dayTitle) ?? entry.title,
                      detail: OpenQuickly.plain(OpenQuickly.relative(entry.modified)),
                      symbol: entry.day == nil ? "doc.text" : "calendar", badge: nil)
            return cell
        case .result(let item):
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(title: item.title, detail: item.detail, symbol: item.symbol, badge: nil)
            return cell
        case .tag(let name, let count):
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(title: name, detail: nil, symbol: "number", badge: "\(count)")
            return cell
        case .hint(let text):
            let cell = tableView.makeView(withIdentifier: .init("hint"), owner: nil) as? HintCell ?? HintCell()
            cell.textField?.stringValue = text
            return cell
        }
    }

    // MARK: Dragging the pinned into a new order

    private static let pinType = NSPasteboard.PasteboardType("com.mariusae.reflect.pinned-row")

    /// The rows the pinned notes are in.
    private var pinnedRows: Range<Int> {
        guard mode == .notes, let first = rows.firstIndex(where: { if case .pinned = $0 { true } else { false } }) else { return 0..<0 }
        var end = first
        while end < rows.count, case .pinned = rows[end] { end += 1 }
        return first..<end
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard pinnedRows.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.pinType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        let pinned = pinnedRows
        // Only among the pinned: between them, or just after the last.
        guard info.draggingSource as? NSTableView === table, row >= pinned.lowerBound, row <= pinned.upperBound else { return [] }
        if operation == .on { tableView.setDropRow(row, dropOperation: .above) }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let pinned = pinnedRows
        guard let fromRow = info.draggingPasteboard.pasteboardItems?.first?.string(forType: Self.pinType).flatMap(Int.init),
              pinned.contains(fromRow) else { return false }
        let shelf = rows[pinned].compactMap { row -> PinOrder.Pin? in
            guard case .pinned(let entry) = row else { return nil }
            return PinOrder.Pin(path: entry.path, order: PinOrder.order(entry.pin))
        }
        // Dropped above a row: past itself, one fewer is in the way.
        let toRow = min(row > fromRow ? row - 1 : row, pinned.upperBound - 1)
        let changed = PinOrder.move(shelf, from: fromRow - pinned.lowerBound, to: toRow - pinned.lowerBound)
        guard !changed.isEmpty else { return false }
        // Shown in the new order at once; the notes are written after.
        let movedRow = rows.remove(at: fromRow)
        rows.insert(movedRow, at: toRow)
        tableView.moveRow(at: fromRow, to: toRow)
        onReorder?(changed)
        return true
    }

    /// Moves a pinned note on the shelf, as a drag would. For scripts.
    func movePinned(from: Int, to: Int) {
        let shelf = rows.compactMap { row -> PinOrder.Pin? in
            guard case .pinned(let entry) = row else { return nil }
            return PinOrder.Pin(path: entry.path, order: PinOrder.order(entry.pin))
        }
        let changed = PinOrder.move(shelf, from: from, to: to)
        print("reorder: " + changed.map { "\($0.path)=\($0.order ?? -1)" }.joined(separator: " "))
        onReorder?(changed)
    }

    /// What a row is, to find it again after reloading.
    private func key(_ row: Row) -> String? {
        switch row {
        case .pinned(let entry): "pin:" + entry.path
        case .recent(let entry): "recent:" + entry.path
        case .source(let entry): "source:" + entry.path
        case .backlink(let path, let context): "backlink:" + path + ":" + context.link + ":\(context.rows.first?.text ?? "")"
        case .result(let item): "result:\(item.target)"
        case .tag(let name, _): "tag:" + name
        case .hint, .header: nil
        }
    }
}

/// Return opens the selected row.
final class SidebarTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A link's context: a little outline, read-only, under its note.
private final class ContextCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("context")
    private let label = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.isSelectable = false
        label.maximumNumberOfLines = 14
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 26),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: NSAttributedString) {
        label.attributedStringValue = text
    }

    override func layout() {
        super.layout()
        // Wraps to the column as it is now.
        label.preferredMaxLayoutWidth = max(0, bounds.width - 34)
    }
}

/// A section's heading, as a source list has them.
private final class HeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("header")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Words in place of rows, when there are none.
private final class HintCell: NSTableCellView {
    init() {
        super.init(frame: .zero)
        identifier = .init("hint")
        let label = NSTextField(labelWithString: "")
        label.textColor = .tertiaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// A note, a result or a tag: a symbol, a title, maybe a line of what was
/// found under it, maybe a count.
private final class RowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("row")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private var detailShown: NSLayoutConstraint!
    private var detailHidden: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = title
        icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        detail.cell?.wraps = true
        badge.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .right
        for view in [icon, title, detail, badge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        detailShown = detail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        detailHidden = title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(title text: String, detail found: NSAttributedString?, symbol: String, badge count: String?) {
        title.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        badge.stringValue = count ?? ""
        badge.isHidden = count == nil
        if let found, found.length > 0 {
            // Small, as a sidebar's second line is, with what was found still bold.
            let shown = NSMutableAttributedString(attributedString: found)
            let size = NSFont.smallSystemFontSize
            found.enumerateAttribute(.font, in: NSRange(location: 0, length: found.length)) { value, range, _ in
                let bold = (value as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
                shown.addAttribute(.font, value: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), range: range)
            }
            shown.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: shown.length))
            detail.attributedStringValue = shown
            detail.isHidden = false
            detailHidden.isActive = false
            detailShown.isActive = true
        } else {
            detail.isHidden = true
            detailShown.isActive = false
            detailHidden.isActive = true
        }
    }
}
