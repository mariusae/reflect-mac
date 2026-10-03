import AppKit
import ReflectCore
import ReflectUI

/// The window's left column, as a Mac source list, in one of three modes —
/// as Drafter has Inbox, Archive and Timeline: the notes — the pinned, in
/// Reflect's order, then the rest as they were last edited; a search of every note, whose results stay listed until
/// it is cleared, and are there again next time; and the graph's tags, each
/// a search for its notes.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate {
    enum Mode: Int, CaseIterable {
        case notes, search, tags, backlinks, tasks, outline

        var title: String { ["Notes", "Search", "Tags", "Backlinks", "Tasks", "Outline"][rawValue] }
        /// What its segment shows: a symbol, so six fit the narrowest sidebar.
        var symbol: String { ["doc.text", "magnifyingglass", "number", "link", "checklist", "list.bullet.indent"][rawValue] }
        var label: String { ["Notes", "Search", "Tags", "Links", "Tasks", "Outline"][rawValue] }

        /// The order they are shown in — the segments, the menu and its
        /// ⌘-numbers. Not their raw values, which are kept as the mode left.
        static let shown: [Mode] = [.notes, .outline, .search, .tags, .backlinks, .tasks]
        var position: Int { Self.shown.firstIndex(of: self) ?? 0 }
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
        /// A run of tasks' parents, and a task.
        case taskContext([String])
        case task(NoteTask)
        /// A heading of the note the keyboard is in — or, in a note with
        /// none, a row at its top level: its row, and how far it is in.
        case heading(text: String, row: Int, level: Int)
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
    private let modes: NSSegmentedControl = {
        let control = NSSegmentedControl(images: Mode.shown.map { mode in
            NSImage(systemSymbolName: mode.symbol, accessibilityDescription: mode.title) ?? NSImage()
        }, trackingMode: .selectOne, target: nil, action: nil)
        return control
    }()
    /// The note the keyboard is in, as it is now — typed but not yet saved
    /// too — and the row the caret is in. Set by the window.
    var currentNote: (() -> (path: String, rows: [ReflectCore.Row], caretRow: Int)?)?
    /// Told to go to a row of the note the keyboard is in.
    var onJump: ((_ path: String, _ row: Int) -> Void)?
    private var outlineRows: [Row] = []
    private var outlinePath: String?

    /// Told to tick a task, or untick it, in its note.
    var onSetTask: ((NoteTask, _ done: Bool) -> Void)?
    /// The tasks as last found, and what of them is shown.
    private var taskRows: [Row] = []
    private var taskGeneration = 0
    /// Tasks ticked here: shown, struck, until the mode is left.
    private var justDone: Set<String> = []
    private let taskFilter = NSPopUpButton(frame: .zero, pullsDown: true)
    private static let hiddenGroupsKey = "SidebarHiddenTaskGroups"
    private var hiddenGroups: Set<String> = Set(UserDefaults.standard.stringArray(forKey: SidebarViewController.hiddenGroupsKey) ?? ["completed"])
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
        for mode in Mode.shown { modes.setToolTip("\(mode.title) (⌘\(mode.position + 1))", forSegment: mode.position) }
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

        taskFilter.controlSize = .small
        taskFilter.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        taskFilter.isBordered = false
        taskFilter.menu?.delegate = self
        taskFilter.addItem(withTitle: "Task Filters")
        taskFilter.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(taskFilter)

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
            taskFilter.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 6),
            taskFilter.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
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
        show(Mode.shown.indices.contains(modes.selectedSegment) ? Mode.shown[modes.selectedSegment] : .notes)
    }

    /// Shows a mode: its rows, and in Search, the field.
    /// Told when the mode is changed here, or the search: another sidebar
    /// — the peeking one — keeps to the same.
    var onModeChange: ((Mode) -> Void)?
    var onSearchChange: ((String) -> Void)?

    func show(_ mode: Mode) {
        let changed = mode != self.mode
        self.mode = mode
        if changed { onModeChange?(mode) }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        modes.selectedSegment = mode.position
        let searching = mode == .search, tagging = mode == .tags || mode == .tasks
        taskFilter.isHidden = mode != .tasks
        if mode != .tasks { justDone.removeAll() }
        field.isHidden = !searching
        tagSort.isHidden = mode != .tags
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
        case .outline:
            refreshOutline(reloading: false)
            rows = outlineRows
        case .tasks:
            rows = taskRows
            refreshTasks()
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
    /// What the search field holds.
    var currentQuery: String { field.stringValue }

    // MARK: Tasks

    /// The groups the filters can hide, as Reflect's Task filters name them.
    private static let taskGroups: [(key: String, title: String)] = [
        ("current", "Current Tasks"), ("overdue", "Overdue Tasks"), ("upcoming", "Upcoming Tasks"), ("other", "Other Tasks"),
    ]

    nonisolated private static func key(_ task: NoteTask) -> String { "\(task.notePath)#\(task.ordinal)" }

    /// Finds the graph's tasks again, in the background, and shows them —
    /// grouped as Reflect's Tasks view groups them.
    func refreshTasks() {
        taskGeneration += 1
        let generation = taskGeneration
        let index = index
        let showDone = !hiddenGroups.contains("completed")
        let justDone = justDone
        let hidden = hiddenGroups
        DispatchQueue.global(qos: .userInitiated).async {
            let tasks = index.tasks(includingDone: true).filter { !$0.done || showDone || justDone.contains(Self.key($0)) }
            let groups = Tasks.group(tasks, today: .today)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == taskGeneration else { return }
                    var rows: [Row] = []
                    for group in groups {
                        let key = switch group.kind {
                        case .current: "current"
                        case .overdue: "overdue"
                        case .upcoming: "upcoming"
                        case .note: "other"
                        }
                        guard !hidden.contains(key) else { continue }
                        let title = group.kind == .note ? (group.notePath.flatMap { index.entry($0) }.map { $0.day.map(OpenQuickly.dayTitle) ?? $0.title } ?? group.label) : group.label
                        rows.append(.header("\(title)  \(group.tasks.filter { !$0.done }.count)"))
                        var context: [String]?
                        for task in group.tasks {
                            let crumbs = Tasks.visibleBreadcrumbs(task.breadcrumbs)
                            if crumbs != context {
                                if !crumbs.isEmpty { rows.append(.taskContext(crumbs)) }
                                context = crumbs
                            }
                            rows.append(.task(task))
                        }
                    }
                    taskRows = rows.isEmpty ? [.hint(hidden.isEmpty ? "No tasks. Make one with ⇧⌘Return." : "No tasks to show")] : rows
                    if mode == .tasks {
                        self.rows = taskRows
                        let selected = table.selectedRow
                        table.reloadData()
                        if selected >= 0, selected < self.rows.count { table.selectRowIndexes([selected], byExtendingSelection: false) }
                    }
                }
            }
        }
    }

    /// A task's checkbox clicked: ticked in its note — and, ticked, kept in
    /// sight, struck, until the mode is left.
    fileprivate func toggle(_ task: NoteTask) {
        if !task.done { justDone.insert(Self.key(task)) }
        onSetTask?(task, !task.done)
    }

    /// Ticks a task shown, by what it says. For scripts.
    func tickTask(containing text: String) {
        for case .task(let task) in rows where task.text.contains(text) {
            toggle(task)
            return
        }
        print("script: no task with \(text)")
    }

    private func filterMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Task Filters", action: nil, keyEquivalent: "")
        for group in Self.taskGroups {
            let item = ClosureMenuItem(title: group.title) { [weak self] in self?.flip(group.key) }
            item.state = hiddenGroups.contains(group.key) ? .off : .on
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let done = ClosureMenuItem(title: "Show Completed Tasks") { [weak self] in self?.flip("completed") }
        done.state = hiddenGroups.contains("completed") ? .off : .on
        menu.addItem(done)
    }

    private func flip(_ key: String) {
        if hiddenGroups.contains(key) { hiddenGroups.remove(key) } else { hiddenGroups.insert(key) }
        UserDefaults.standard.set(Array(hiddenGroups).sorted(), forKey: Self.hiddenGroupsKey)
        refreshTasks()
    }

    // MARK: Outline

    /// The outline of the note the keyboard is in: its headings, each as far
    /// in as its level — or, in a note with none, its top-level rows — and
    /// the one the caret is under chosen.
    func refreshOutline(reloading: Bool = true) {
        guard let note = currentNote?() else {
            outlineRows = [.hint("The outline of the note you are in shows here")]
            outlinePath = nil
            if reloading, mode == .outline { rows = outlineRows; table.reloadData() }
            return
        }
        var entries = Self.outline(note.rows, path: note.path)
        if entries.isEmpty { entries = [.hint("Nothing to outline yet")] }
        let title = index.entry(note.path).map { $0.day.map(OpenQuickly.dayTitle) ?? $0.title }
            ?? GraphPaths.day(fromDailyPath: note.path).map(OpenQuickly.dayTitle) ?? note.path
        let next: [Row] = [.header(title)] + entries
        let changed = note.path != outlinePath || next.map(Self.outlineKey) != outlineRows.map(Self.outlineKey)
        outlinePath = note.path
        outlineRows = next
        guard reloading, mode == .outline else { return }
        if changed {
            rows = outlineRows
            table.reloadData()
        }
        // The section the caret is in.
        let current = rows.lastIndex { row in
            if case .heading(_, let at, _) = row { return at <= note.caretRow }
            return false
        }
        if let current, table.selectedRow != current {
            table.selectRowIndexes([current], byExtendingSelection: false)
            table.scrollRowToVisible(current)
        } else if current == nil {
            table.deselectAll(nil)
        }
    }

    /// A note's headings — its title's left out, being the note's name —
    /// or, with none, its top-level rows.
    static func outline(_ rows: [ReflectCore.Row], path: String) -> [Row] {
        var headings: [(text: String, row: Int, level: Int)] = []
        for (index, row) in rows.enumerated() {
            guard case .heading(let level) = row.kind else { continue }
            let text = InlineMarkup.plainText(row.text)
            // A note's first heading, at the top, is its title.
            if index == 0, level == 1, GraphPaths.day(fromDailyPath: path) == nil { continue }
            if !text.isEmpty { headings.append((text, index, level)) }
        }
        if !headings.isEmpty {
            let top = headings.map(\.level).min() ?? 1
            return headings.map { .heading(text: $0.text, row: $0.row, level: $0.level - top) }
        }
        return rows.enumerated().compactMap { index, row in
            guard row.depth == 0, row.kind != .rule, row.kind != .code else { return nil }
            if index == 0, case .heading = row.kind { return nil }
            let text = InlineMarkup.plainText(row.text).components(separatedBy: "\n").first ?? ""
            return text.isEmpty ? nil : .heading(text: text, row: index, level: 0)
        }
    }

    private static func outlineKey(_ row: Row) -> String {
        switch row {
        case .heading(let text, let at, let level): "\(at):\(level):\(text)"
        case .header(let title): "#" + title
        case .hint(let text): "?" + text
        default: ""
        }
    }

    // MARK: Backlinks

    /// Shows the backlinks of a note — the one the keyboard is in — found in
    /// the background; the last found stay until the new ones come.
    func follow(_ path: String?, force: Bool = false) {
        if mode == .outline { refreshOutline() }
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
        onSearchChange?(field.stringValue)
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

    /// Searches for something, as if typed — and shows Search, unless not.
    func search(for text: String, switching: Bool = true) {
        _ = view
        guard field.stringValue != text || switching else { return }
        field.stringValue = text
        searchChanged(nil)
        if switching, mode != .search { show(.search) }
    }

    /// Search, for a tag's notes.
    func show(tag: String) {
        search(for: "#" + tag)
    }

    /// The heights the table gives its rows, for scripts.
    var tableRowHeights: [Int] { (0..<table.numberOfRows).map { Int(table.rect(ofRow: $0).height) } }

    /// The rows shown, for scripts.
    var shownRows: [String] {
        ["[\(mode.title)]"] + rows.map { row in
            switch row {
            case .header(let title): "[\(title)]"
            case .pinned(let entry): "pin " + entry.title
            case .source(let entry): "source " + entry.title
            case .taskContext(let crumbs): "  (" + crumbs.joined(separator: " › ") + ")"
            case .task(let task): "task \(task.done ? "[x]" : "[ ]") " + task.text
            case .heading(let text, let row, let level): String(repeating: "  ", count: level) + "§ \(text) @\(row)"
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
            case .task(let task): title = task.text
            case .heading(let text, _, _): title = text
            case .taskContext: continue
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
        case .task(let task): return task.notePath
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
        case .task(let task):
            onOpen?(OpenQuickly.target(for: task.notePath), inSplit, .words([task.text]))
        case .taskContext:
            break
        case .heading(_, let row, _):
            if let path = outlinePath { onJump?(path, row) }
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
        if menu === taskFilter.menu {
            filterMenu(menu)
            return
        }
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
        case .task(let task): path = task.notePath
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
        case .hint, .header, .taskContext: false
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
        case .taskContext(let crumbs):
            let cell = tableView.makeView(withIdentifier: .init("hint"), owner: nil) as? HintCell ?? HintCell()
            cell.textField?.stringValue = crumbs.joined(separator: " › ")
            return cell
        case .task(let task):
            let cell = tableView.makeView(withIdentifier: TaskCell.identifier, owner: nil) as? TaskCell ?? TaskCell()
            let struck = task.done || justDone.contains(Self.key(task))
            let group = rows[..<row].last { if case .header = $0 { true } else { false } }
            let inNoteGroup = group.map { if case .header(let label) = $0 { !["Current", "Overdue", "Upcoming"].contains { label.hasPrefix($0 + "  ") } } else { false } } ?? false
            // Where it is, when the group does not say: its day, or its note.
            var detail = inNoteGroup ? "" : (task.day.map(OpenQuickly.dayTitle) ?? task.noteTitle)
            if let due = task.dueDate, due != task.day { detail += (detail.isEmpty ? "" : " · ") + "due " + OpenQuickly.dayTitle(due) }
            cell.show(task, done: struck, detail: detail) { [weak self] in self?.toggle(task) }
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
        case .heading(let text, _, let level):
            let cell = tableView.makeView(withIdentifier: OutlineCell.identifier, owner: nil) as? OutlineCell ?? OutlineCell()
            cell.show(text, level: level)
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
        case .task(let task): "task:" + Self.key(task)
        case .heading(let text, let row, _): "heading:\(row):" + text
        case .taskContext: nil
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

/// A task: its round checkbox, to tick, and what it says — and where it is.
private final class TaskCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("task")
    private let box = NSButton()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let where_ = NSTextField(labelWithString: "")
    private var onToggle: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        box.isBordered = false
        box.setButtonType(.momentaryChange)
        box.target = self
        box.action = #selector(ticked(_:))
        label.isSelectable = false
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        where_.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        where_.textColor = .tertiaryLabelColor
        where_.lineBreakMode = .byTruncatingTail
        for view in [box, label, where_] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            box.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            box.widthAnchor.constraint(equalToConstant: 18),
            box.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            where_.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            where_.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            where_.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            where_.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ task: NoteTask, done: Bool, detail: String, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        box.image = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : "circle", accessibilityDescription: done ? "Done" : "To do")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)
                .applying(.init(paletteColors: done ? [.white, .controlAccentColor] : [.secondaryLabelColor])))
        let context = BacklinkContext(rows: [Row(kind: .paragraph, text: task.text)], link: "")
        let text = NSMutableAttributedString(attributedString: BacklinkText.attributed(context, size: NSFont.systemFontSize))
        if done {
            text.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor],
                               range: NSRange(location: 0, length: text.length))
        }
        label.attributedStringValue = text
        where_.stringValue = detail
        where_.isHidden = detail.isEmpty
    }

    override func layout() {
        super.layout()
        label.preferredMaxLayoutWidth = max(0, bounds.width - 36)
    }

    @objc private func ticked(_ sender: Any?) { onToggle?() }
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

/// A heading in the outline: its words, as far in as its level; the
/// outermost a little heavier.
private final class OutlineCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("outline")
    private let label = NSTextField(labelWithString: "")
    private var indent: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        indent = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6)
        NSLayoutConstraint.activate([
            indent,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, level: Int) {
        label.stringValue = text
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: level == 0 ? .medium : .regular)
        label.textColor = level == 0 ? .labelColor : .secondaryLabelColor
        indent.constant = 6 + CGFloat(min(level, 5)) * 14
    }
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
