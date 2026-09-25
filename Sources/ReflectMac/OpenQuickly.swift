import AppKit
import ReflectCore

/// File ▸ Open (⌘O): one field that finds anything — a note by its title
/// or any of its names, a day by its date ("friday", "sep 24",
/// "2026-09-24"), a note by words in it — and a note to make, when none
/// has the name typed.
///
/// Return opens what is chosen; Option-Return, or an Option-click, opens it
/// in the split view.
@MainActor
final class OpenQuickly: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Target {
        case note(String)
        case day(Day)
        case create(String)
    }

    struct Item {
        var target: Target
        var title: String
        var detail: NSAttributedString?
        var symbol: String
        /// What a `[[link]]` to it says.
        var name: String = ""
    }

    let index: NoteIndex
    private let search: ReflectSearchIndex?
    /// Told what to open, and whether in the split view.
    var onOpen: ((Target, _ inSplit: Bool) -> Void)?

    private let panel: ChooserPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")
    private var items: [Item] = []
    private var pending: DispatchWorkItem?

    private static let width: CGFloat = 640
    private static let fieldHeight: CGFloat = 56
    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 9

    init(index: NoteIndex, search: ReflectSearchIndex?) {
        self.index = index
        self.search = search
        panel = ChooserPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.fieldHeight),
                             styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        super.init()
        build()
    }

    private func build() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.onResign = { [weak self] in self?.close() }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        let glass = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))!)
        glass.contentTintColor = .secondaryLabelColor
        glass.frame = NSRect(x: 18, y: 0, width: 24, height: Self.fieldHeight)
        glass.autoresizingMask = [.minYMargin]
        background.addSubview(glass)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.placeholderString = "Open a note or a day, or search…"
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        background.addSubview(field)

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("item")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        background.addSubview(scroll)

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.stringValue = "↩ Open    ⌥↩ Open in Split View    ⌘↩ New Note    ⎋ Close"
        hint.alignment = .right
        background.addSubview(hint)
    }

    // MARK: Showing

    func show(over window: NSWindow?) {
        field.stringValue = ""
        refresh()
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        layout()
    }

    func close() {
        pending?.cancel()
        panel.orderOut(nil)
    }

    /// Sizes the panel to its results, keeping its top where it is.
    private func layout() {
        let rows = min(items.count, Self.visibleRows)
        let listHeight = rows == 0 ? 0 : CGFloat(rows) * (Self.rowHeight + 2) + 12
        let hintHeight: CGFloat = rows == 0 ? 0 : 24
        let height = Self.fieldHeight + listHeight + hintHeight
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        field.frame = NSRect(x: 52, y: height - Self.fieldHeight + 13, width: Self.width - 70, height: 30)
        scroll.frame = NSRect(x: 0, y: hintHeight, width: Self.width, height: listHeight)
        hint.frame = NSRect(x: 16, y: 4, width: Self.width - 32, height: 16)
        hint.isHidden = rows == 0
        panel.contentView?.subviews.first { $0 is NSImageView }?.frame.origin.y = height - Self.fieldHeight
    }

    // MARK: Finding

    func controlTextDidChange(_ notification: Notification) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func refresh() {
        items = Self.items(for: field.stringValue, index: index, search: search)
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
        layout()
    }

    static func items(for query: String, index: NoteIndex, search: ReflectSearchIndex?) -> [Item] {
        let query = query.trimmingCharacters(in: .whitespaces)
        var items: [Item] = []
        var seen = Set<String>()
        func add(_ item: Item, path: String) {
            guard seen.insert(path).inserted else { return }
            var item = item
            switch item.target {
            case .day(let day): item.name = day.description
            case .note(let path): item.name = index.entry(path)?.title ?? item.title
            case .create(let title): item.name = title
            }
            items.append(item)
        }

        if query.isEmpty {
            let today = Day.today
            add(Item(target: .day(today), title: "Today", detail: plain(dayTitle(today)), symbol: "calendar"),
                path: GraphPaths.dailyPath(for: today))
            for match in index.matches("", limit: 12) {
                add(Item(target: .note(match.entry.path), title: match.entry.title, detail: plain(relative(match.entry.modified)),
                         symbol: "doc.text"), path: match.entry.path)
            }
            return items
        }

        if let day = day(from: query) {
            add(Item(target: .day(day), title: dayTitle(day), detail: plain(day == .today ? "Today" : day.description),
                     symbol: "calendar"), path: GraphPaths.dailyPath(for: day))
        }
        let named = index.matches(query, limit: 20)
        for match in named {
            let detail = match.alias.map { plain("also “\($0)”") } ?? plain(relative(match.entry.modified))
            add(Item(target: .note(match.entry.path), title: match.entry.title, detail: detail, symbol: "doc.text"),
                path: match.entry.path)
        }
        let key = NoteIndex.foldKey(query)
        let exists = named.contains { NoteIndex.foldKey($0.entry.title) == key || $0.entry.aliases.contains { NoteIndex.foldKey($0) == key } }
        // Then words in notes: from Reflect's index when there is one.
        if let search {
            for hit in search.search(query, limit: 25) {
                let entry = index.entry(hit.path)
                let title = entry?.day.map(dayTitle) ?? entry?.title ?? hit.title
                add(Item(target: target(for: hit.path), title: title, detail: highlighted(hit.snippet),
                         symbol: entry?.day == nil ? "text.magnifyingglass" : "calendar"), path: hit.path)
            }
        } else {
            for hit in index.containing(query, limit: 25) {
                let entry = index.entry(hit.path)
                let title = entry?.day.map(dayTitle) ?? entry?.title ?? hit.path
                add(Item(target: target(for: hit.path), title: title, detail: plain(hit.snippet),
                         symbol: entry?.day == nil ? "text.magnifyingglass" : "calendar"), path: hit.path)
            }
        }
        // Last, so Return never makes a note by chance; ⌘Return makes one
        // from whatever is typed.
        if !exists {
            items.append(Item(target: .create(query), title: "New Note “\(query)”", detail: plain("⌘↩ Make a note with this title"),
                              symbol: "square.and.pencil", name: query))
        }
        return items
    }

    private static func target(for path: String) -> Target {
        GraphPaths.day(fromDailyPath: path).map(Target.day) ?? .note(path)
    }

    /// A day a query names: a date written out, or said — "today", "next
    /// friday", "sep 24".
    static func day(from query: String) -> Day? {
        if let day = Day(query) { return day }
        let lowered = query.lowercased()
        if ["today", "yesterday", "tomorrow"].contains(lowered) {
            return Day.today.adding(lowered == "yesterday" ? -1 : lowered == "tomorrow" ? 1 : 0)
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: query, range: NSRange(location: 0, length: (query as NSString).length)),
              match.range.length >= (query as NSString).length - 1, let date = match.date else { return nil }
        return Day(date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
        return formatter
    }()

    static func dayTitle(_ day: Day) -> String { dayFormatter.string(from: day.date ?? Date()) }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        date == .distantPast ? "" : "Edited " + relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: 12)])
    }

    /// A snippet with the words found in it set in bold.
    private static func highlighted(_ snippet: String) -> NSAttributedString {
        let text = NSMutableAttributedString()
        var bold = false
        var current = ""
        for character in snippet.replacingOccurrences(of: "\n", with: " ") {
            if character == "\u{1}" || character == "\u{2}" {
                text.append(NSAttributedString(string: current, attributes: [
                    .foregroundColor: bold ? NSColor.labelColor : NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
                ]))
                current = ""
                bold = character == "\u{1}"
            } else {
                current.append(character)
            }
        }
        text.append(NSAttributedString(string: current, attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                                                                      .font: NSFont.systemFont(ofSize: 12)]))
        return text
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            let query = field.stringValue.trimmingCharacters(in: .whitespaces)
            if flags.contains(.command), !query.isEmpty {
                // ⌘Return: a note by the name typed — the one there is, or a new one.
                let key = NoteIndex.foldKey(query)
                let target = index.matches(query, limit: 1).first
                    .flatMap { NoteIndex.foldKey($0.entry.title) == key ? Target.note($0.entry.path) : nil } ?? .create(query)
                close()
                onOpen?(target, flags.contains(.option))
            } else {
                openSelected(inSplit: flags.contains(.option))
            }
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    private func move(_ by: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        openSelected(inSplit: NSApp.currentEvent?.modifierFlags.contains(.option) == true)
    }

    private func openSelected(inSplit: Bool) {
        guard table.selectedRow >= 0, table.selectedRow < items.count else { return }
        let target = items[table.selectedRow].target
        close()
        onOpen?(target, inSplit)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChooserCell.identifier, owner: nil) as? ChooserCell ?? ChooserCell()
        cell.show(items[row])
        return cell
    }
}

/// A result: its kind's symbol, its name, and a line more.
final class ChooserCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ChooserCell")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        for field in [title, detail] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [symbol, title, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: OpenQuickly.Item) {
        symbol.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        title.stringValue = item.title
        detail.attributedStringValue = item.detail ?? NSAttributedString()
        detail.isHidden = item.detail == nil || item.detail!.length == 0
    }
}

/// The chooser's window: floating, with no title bar to speak of, that can
/// take the keyboard and gives it back when it loses it.
final class ChooserPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}
