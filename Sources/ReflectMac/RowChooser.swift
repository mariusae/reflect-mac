import AppKit
import ReflectCore
import ReflectUI

/// Go to Row (⌘J): the rows of the note the keyboard is in, found by what
/// they say and where they are — `proj alph` finds Alpha, in Projects — in
/// a panel like Open's.
///
/// ↩ goes to the row; ⌥↩ focuses on it; ⌘↩ goes to it in the split view.
/// ⌥→ goes into the chosen row, to find among what is in it, and ⌥← back
/// out. With nothing typed, the rows of a level are listed: the panel is
/// the outline, to walk.
final class RowChooser: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Action { case go, focus, split }

    /// Told the row chosen — its place among the note's rows, unfolded —
    /// and what to do there.
    var onChoose: ((_ index: Int, Action) -> Void)?
    /// Told a row of another note chosen, and what to do there.
    var onChooseElsewhere: ((RowIndex.Found, Action) -> Void)?
    /// Finds rows across the other notes; asked off the main thread.
    var searchElsewhere: (@Sendable (String) -> [RowIndex.Found])?

    /// What a line of the list is: a row of this note, the heading over the
    /// rest, or a row of another note.
    private enum Line {
        case here(OutlineFind.Entry)
        case heading(String)
        case elsewhere(RowIndex.Found)
    }

    private var entries: [OutlineFind.Entry] = []
    private var shown: [OutlineFind.Entry] = []
    private var others: [RowIndex.Found] = []
    private var lines: [Line] = []
    private var generation = 0
    /// The row whose rows are being looked among, when one is.
    private var scope: Int?
    /// The note's title heading, when it holds the whole note: the note
    /// itself, and so left out of every path.
    private var title: Int?
    private var noteName = ""

    private let panel = ChooserPanel(contentRect: NSRect(x: 0, y: 0, width: RowChooser.width, height: RowChooser.fieldHeight),
                                     styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
    private let field = NSTextField()
    private let place = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let hint = NSTextField(labelWithString: "")

    private static let width: CGFloat = 620
    private static let fieldHeight: CGFloat = 70
    private static let rowHeight: CGFloat = 42
    private static let visibleRows = 10

    override init() {
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
        panel.onCommandReturn = { [weak self] in self?.choose(.split) }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        place.font = .systemFont(ofSize: 11, weight: .medium)
        place.textColor = .secondaryLabelColor
        place.lineBreakMode = .byTruncatingHead
        background.addSubview(place)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        background.addSubview(field)

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .inset
        table.addTableColumn(NSTableColumn(identifier: .init("row")))
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
        hint.stringValue = "↩ Go    ⌥↩ Focus    ⌘↩ Split View    ⌥→ Into    ⌥← Out    ⎋ Close"
        hint.alignment = .right
        background.addSubview(hint)
    }

    // MARK: Showing

    /// Shows the rows of a note, over a window.
    func show(_ rows: [Row], in note: String, over window: NSWindow?) {
        entries = OutlineFind.entries(rows)
        noteName = note
        let top = entries.filter { $0.ancestors.isEmpty && !$0.text.isEmpty }
        title = top.count == 1 && top[0].children > 0 ? top[0].index : nil
        scope = nil
        field.stringValue = ""
        refresh()
        if let window {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.width / 2, y: frame.maxY - frame.height * 0.18 - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        panel.orderOut(nil)
    }

    private func refresh() {
        // Not the note's title, found: that is the note, which Open finds.
        shown = OutlineFind.find(field.stringValue, in: entries, within: scope).filter { $0.index != title }
        // The other notes, for a query, while not inside a row of this one:
        // found in the background, and shown under this note's once found.
        generation += 1
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        if scope != nil || query.isEmpty {
            others = []
        } else if let search = searchElsewhere {
            let generation = generation
            DispatchQueue.global(qos: .userInitiated).async {
                let found = search(query)
                DispatchQueue.main.async { [weak self] in
                    guard let self, generation == self.generation else { return }
                    others = found
                    relist(keepingSelection: true)
                }
            }
        }
        relist(keepingSelection: false)
    }

    /// The list, from this note's rows and the others'.
    private func relist(keepingSelection: Bool) {
        let previous = keepingSelection ? table.selectedRow : -1
        lines = shown.map(Line.here) + (others.isEmpty ? [] : [.heading("Other Notes")] + others.map(Line.elsewhere))
        let scopeEntry = scope.flatMap { scope in entries.first { $0.index == scope } }
        place.stringValue = ([noteName] + (scopeEntry.map { path(of: $0) + [$0.text] } ?? []))
            .filter { !$0.isEmpty }.joined(separator: "  ›  ")
        field.placeholderString = scopeEntry.map { "Find in “\($0.text)”…" } ?? "Go to a row, here or in any note…"
        table.reloadData()
        let first = lines.firstIndex { if case .heading = $0 { false } else { true } }
        if previous >= 0, previous < lines.count {
            table.selectRowIndexes([previous], byExtendingSelection: false)
        } else if let first {
            table.selectRowIndexes([first], byExtendingSelection: false)
        }
        layout()
    }

    /// Sizes the panel to its results, keeping its top where it is.
    private func layout() {
        let rows = min(lines.count, Self.visibleRows)
        let listHeight = rows == 0 ? 0 : CGFloat(rows) * (Self.rowHeight + 2) + 12
        let hintHeight: CGFloat = 24
        let height = Self.fieldHeight + listHeight + hintHeight
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
        place.frame = NSRect(x: 20, y: height - 26, width: Self.width - 40, height: 16)
        field.frame = NSRect(x: 18, y: height - Self.fieldHeight + 8, width: Self.width - 36, height: 28)
        scroll.frame = NSRect(x: 0, y: hintHeight, width: Self.width, height: listHeight)
        hint.frame = NSRect(x: 16, y: 4, width: Self.width - 32, height: 16)
    }

    func controlTextDidChange(_ notification: Notification) { refresh() }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            move(-1)
        case #selector(NSResponder.moveDown(_:)):
            move(1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            choose(NSApp.currentEvent?.modifierFlags.contains(.option) == true ? .focus : .go)
        case #selector(NSResponder.moveWordRight(_:)):
            into()
        case #selector(NSResponder.moveWordLeft(_:)):
            out()
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    /// Where a row is, the note's title left out: it is the note.
    private func path(of entry: OutlineFind.Entry) -> [String] {
        zip(entry.ancestors, entry.path).filter { $0.0 != title }.map(\.1)
    }

    /// The row of this note chosen, when it is one.
    private var selected: OutlineFind.Entry? {
        let row = table.selectedRow
        guard row >= 0, row < lines.count, case .here(let entry) = lines[row] else { return nil }
        return entry
    }

    private func move(_ by: Int) {
        guard !lines.isEmpty else { return }
        var row = min(max(table.selectedRow + by, 0), lines.count - 1)
        // Over the heading, not onto it.
        if case .heading = lines[row] { row = min(max(row + (by > 0 ? 1 : -1), 0), lines.count - 1) }
        if case .heading = lines[row] { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Into the chosen row: its rows, to find among.
    private func into() {
        guard let entry = selected else { NSSound.beep(); return }
        guard entry.children > 0 else { NSSound.beep(); return }
        scope = entry.index
        field.stringValue = ""
        refresh()
    }

    /// Back out a level: to the row the one looked in is in, or the note.
    private func out() {
        guard let current = scope else { NSSound.beep(); return }
        let entry = entries.first { $0.index == current }
        scope = entry?.ancestors.last
        // A note's title holds all of it: out of what is under it is the note.
        if let scope, entries.first(where: { $0.index == scope })?.ancestors.isEmpty == true,
           entries.filter({ $0.ancestors.isEmpty && !$0.text.isEmpty }).count == 1 {
            self.scope = nil
        }
        field.stringValue = ""
        refresh()
        // The row come out of, chosen.
        if let row = shown.firstIndex(where: { $0.index == current }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
    }

    private func choose(_ action: Action) {
        let row = table.selectedRow
        guard row >= 0, row < lines.count else { NSSound.beep(); return }
        switch lines[row] {
        case .here(let entry):
            close()
            onChoose?(entry.index, action)
        case .elsewhere(let found):
            close()
            onChooseElsewhere?(found, action)
        case .heading:
            NSSound.beep()
        }
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        choose(flags.contains(.command) ? .split : flags.contains(.option) ? .focus : .go)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .heading = lines[row] { return 26 }
        return Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .heading = lines[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .heading(let title):
            let label = NSTextField(labelWithString: title.uppercased())
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .tertiaryLabelColor
            let cell = NSTableCellView()
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
            ])
            return cell
        case .here(let entry):
            let cell = tableView.makeView(withIdentifier: RowChooserCell.identifier, owner: nil) as? RowChooserCell ?? RowChooserCell()
            // Only where it is below where the panel is looking.
            let scopeEntry = scope.flatMap { scope in entries.first { $0.index == scope } }
            let above = scopeEntry.map { path(of: $0).count + 1 } ?? 0
            cell.show(entry, path: Array(path(of: entry).dropFirst(above)))
            return cell
        case .elsewhere(let found):
            let cell = tableView.makeView(withIdentifier: RowChooserCell.identifier, owner: nil) as? RowChooserCell ?? RowChooserCell()
            // Its note first, then where in it — its title heading being the note.
            cell.show(found.entry, path: [found.noteTitle] + found.entry.path.filter { $0 != found.noteTitle })
            return cell
        }
    }
}

/// A row found: its kind, its words, and where it is.
private final class RowChooserCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("RowChooserCell")
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    /// The title's top: lower when there is no path under it.
    private var titleTop: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        symbol.symbolConfiguration = .init(pointSize: 13, weight: .regular)
        symbol.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14, weight: .medium)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        count.textColor = .tertiaryLabelColor
        for field in [title, detail] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.usesSingleLineMode = true
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for view in [symbol, title, detail, count] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 4)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbol.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            titleTop,
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ entry: OutlineFind.Entry, path: [String]) {
        let name = Self.symbol(for: entry.row)
        // A bullet a small dot, as in the notes; other kinds their symbol.
        symbol.symbolConfiguration = .init(pointSize: name == "circle.fill" ? 6 : 13, weight: .regular)
        symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        title.stringValue = entry.text
        let path = path.filter { !$0.isEmpty }
        detail.stringValue = path.joined(separator: " › ")
        detail.isHidden = path.isEmpty
        titleTop.constant = path.isEmpty ? 11 : 4
        count.stringValue = entry.children > 0 ? "\(entry.children) ›" : ""
    }

    static func symbol(for row: Row) -> String {
        if let task = row.task {
            let round = row.marker == "+"
            return task.isDone ? (round ? "checkmark.circle" : "checkmark.square") : (round ? "circle" : "square")
        }
        switch row.kind {
        case .heading: return "number"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .quote: return "text.quote"
        case .ordered: return "list.number"
        default: return "circle.fill"
        }
    }
}

extension RowChooser {
    /// What is listed: each row's words and where it is. For scripts.
    var listed: [String] {
        lines.map { line in
            switch line {
            case .here(let entry): entry.text + (entry.path.isEmpty ? "" : "  (" + entry.path.joined(separator: " › ") + ")")
            case .heading(let title): "— \(title) —"
            case .elsewhere(let found): found.entry.text + "  [" + found.noteTitle + "]"
            }
        }
    }

    /// As the keys would: a query typed, into, out, or a choice. For scripts.
    func script(_ command: String, _ argument: String) {
        switch command {
        case "type":
            field.stringValue = argument
            refresh()
        case "down": move(1)
        case "select":
            // select <n>: the nth line chosen, as clicked.
            if let row = Int(argument), row < lines.count { table.selectRowIndexes([row], byExtendingSelection: false) }
        case "into": into()
        case "out": out()
        case "go": choose(.go)
        case "focus": choose(.focus)
        case "split": choose(.split)
        case "snap":
            guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: argument))
        default: break
        }
    }
}
