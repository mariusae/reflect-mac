import AppKit
import ReflectCore

/// The window's left column, as a Mac source list, in one of three modes —
/// as Drafter has Inbox, Archive and Timeline: the pinned notes, in
/// Reflect's order; a search of every note, whose results stay listed until
/// it is cleared, and are there again next time; and the graph's tags, each
/// a search for its notes.
@MainActor
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
    NSMenuDelegate {
    enum Mode: Int, CaseIterable {
        case pinned, search, tags

        var title: String { ["Pinned", "Search", "Tags"][rawValue] }
    }

    /// A row: something to open, or words in place of rows.
    enum Row {
        case pinned(NoteEntry)
        case result(OpenQuickly.Item)
        case tag(name: String, count: Int)
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

    private(set) var mode: Mode = .pinned
    private let modes = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let field = NSSearchField()
    private let table = SidebarTableView()
    private let scroll = NSScrollView()
    private var rows: [Row] = []
    /// The table's top: under the search field in Search, else under the modes.
    private var underField: NSLayoutConstraint!
    private var underModes: NSLayoutConstraint!

    private static let modeKey = "SidebarMode"

    init(index: NoteIndex, search: ReflectSearchIndex?, pictures: ImageTextIndex?, root: URL) {
        self.index = index
        self.search = search
        self.pictures = pictures
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))

        modes.target = self
        modes.action = #selector(modeChanged(_:))
        modes.segmentDistribution = .fillEqually
        modes.controlSize = .large
        for mode in Mode.allCases { modes.setToolTip("\(mode.title) (⌘\(mode.rawValue + 1))", forSegment: mode.rawValue) }
        modes.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(modes)

        field.placeholderString = "Search All Notes"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

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
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.onReturn = { [weak self] in self?.openSelected(inSplit: NSApp.currentEvent?.modifierFlags.contains(.option) == true) }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        underField = scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6)
        underModes = scroll.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 8)
        NSLayoutConstraint.activate([
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
        show(Mode(rawValue: UserDefaults.standard.integer(forKey: Self.modeKey)) ?? .pinned)
    }

    // MARK: Modes

    @objc private func modeChanged(_ sender: Any?) {
        show(Mode(rawValue: modes.selectedSegment) ?? .pinned)
    }

    /// Shows a mode: its rows, and in Search, the field.
    func show(_ mode: Mode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        modes.selectedSegment = mode.rawValue
        let searching = mode == .search
        field.isHidden = !searching
        underModes.isActive = !searching
        underField.isActive = searching
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
        case .pinned:
            let pinned = index.pinned.map(Row.pinned)
            rows = pinned.isEmpty ? [.hint("No pinned notes. Pin one with ⇧⌘P.")] : pinned
        case .search:
            rows = results(for: query)
        case .tags:
            let tags = index.tags.map { Row.tag(name: $0.name, count: $0.count) }
            rows = tags.isEmpty ? [.hint("No #tags in any note")] : tags
        }
        table.reloadData()
        if let selected, let row = rows.firstIndex(where: { key($0) == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    private var query: String { field.stringValue.trimmingCharacters(in: .whitespaces) }

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
        let items = OpenQuickly.items(for: query, index: index, search: search, pictures: pictures)
            .filter { if case .create = $0.target { false } else { true } }
        return items.isEmpty ? [.hint("No results")] : items.map(Row.result)
    }

    @objc private func searchChanged(_ sender: Any?) {
        SessionState.shared.update(root) { $0.search = query.isEmpty ? nil : query }
        if mode == .search { reload() }
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
            case .pinned(let entry): "pin " + entry.title
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
            case .pinned(let entry): title = entry.title
            case .result(let item): title = item.title
            case .tag(let name, _): title = "#" + name
            case .hint: continue
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
        open(rows[table.clickedRow], inSplit: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    private func openSelected(inSplit: Bool) {
        guard table.selectedRow >= 0, table.selectedRow < rows.count else { return }
        open(rows[table.selectedRow], inSplit: inSplit)
    }

    private func open(_ row: Row, inSplit: Bool) {
        switch row {
        case .pinned(let entry):
            onOpen?(entry.day.map { .day($0) } ?? .note(entry.path), inSplit, nil)
        case .result(let item):
            onOpen?(item.target, inSplit, item.found)
        case .tag(let name, _):
            show(tag: name)
        case .hint:
            break
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, table.clickedRow < rows.count else { return }
        let row = rows[table.clickedRow]
        let path: String?
        switch row {
        case .pinned(let entry): path = entry.path
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
        menu.addItem(.separator())
        let isPinned = index.entry(path)?.pin != nil
        menu.addItem(ClosureMenuItem(title: isPinned ? "Unpin" : "Pin") { [weak self] in self?.onPin?(path, !isPinned) })
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .hint = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .pinned(let entry):
            let cell = tableView.makeView(withIdentifier: RowCell.identifier, owner: nil) as? RowCell ?? RowCell()
            cell.show(title: entry.day.map(OpenQuickly.dayTitle) ?? entry.title, detail: nil,
                      symbol: entry.day == nil ? "pin" : "calendar", badge: nil)
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

    /// What a row is, to find it again after reloading.
    private func key(_ row: Row) -> String? {
        switch row {
        case .pinned(let entry): "pin:" + entry.path
        case .result(let item): "result:\(item.target)"
        case .tag(let name, _): "tag:" + name
        case .hint: nil
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
