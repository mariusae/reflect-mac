import AppKit
import ReflectCore

/// Finishing a `[[link` as it is typed: the chooser's own search, in a list
/// under the caret, of what the words after `[[` name — a note, a day, or a
/// note yet to be made.
///
/// The list never takes the keyboard: typing goes on in the note, and the
/// list follows it. ↑ and ↓ choose, Return or Tab puts the link in, Escape
/// puts the list away, and so does the caret leaving the link.
@MainActor
final class LinkCompletion: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Where to look; the window sets it to where the chooser looks.
    static var sources: SearchSources?

    private weak var textView: OutlineTextView?
    /// Where the link's words start: just after `[[`.
    private(set) var start: Int
    private var items: [OpenQuickly.Item] = []
    private let panel: NSPanel
    /// Searches in the background, so typing never waits on it.
    private let runner: SearchRunner?
    private let table = NSTableView()
    private let scroll = NSScrollView()

    private static let width: CGFloat = 420
    private static let rowHeight: CGFloat = 40
    private static let visibleRows = 7

    init(textView: OutlineTextView, start: Int) {
        self.textView = textView
        self.start = start
        runner = Self.sources.map(SearchRunner.init)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        panel.contentView = background

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.style = .inset
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
    }

    /// What has been typed after `[[`, or nil when the caret has left it.
    var query: String? {
        guard let textView, let storage = textView.textStorage else { return nil }
        let caret = textView.selectedRange()
        let text = storage.string as NSString
        guard caret.length == 0, caret.location >= start, start >= 2, start <= text.length,
              text.substring(with: NSRange(location: start - 2, length: 2)) == "[[" else { return nil }
        let typed = text.substring(with: NSRange(location: start, length: caret.location - start))
        guard !typed.contains("]"), !typed.contains("\n"), !typed.contains("\u{2028}"), typed.count <= 120 else { return nil }
        return typed
    }

    /// Finds again for what is typed — in the background, the list filling
    /// in as results come — and moves the list to the caret; or says,
    /// returning false, that the link is no longer being typed.
    func refresh() -> Bool {
        guard let query, textView?.window != nil else { return false }
        var first = true
        runner?.run(query) { [weak self] found, _ in
            self?.show(found, keepingSelection: !first)
            first = false
        }
        place()
        return true
    }

    private func show(_ found: [OpenQuickly.Item], keepingSelection: Bool) {
        let chosen = keepingSelection && table.selectedRow > 0 && table.selectedRow < items.count ? "\(items[table.selectedRow].target)" : nil
        items = found
        table.reloadData()
        if let chosen, let row = items.firstIndex(where: { "\($0.target)" == chosen }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !items.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        place()
    }

    /// Sizes the list to what it holds, under the link being typed.
    private func place() {
        guard let textView, let window = textView.window else { return }
        let rows = min(max(items.count, 1), Self.visibleRows)
        let height = CGFloat(rows) * (Self.rowHeight + 3) + 10
        scroll.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        let caret = textView.firstRect(forCharacterRange: NSRange(location: start - 2, length: 0), actualRange: nil)
        var origin = NSPoint(x: caret.minX - 20, y: caret.minY - height - 4)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = caret.maxY + 4
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func close() {
        runner?.cancel()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), items.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Puts the chosen link in: `[[Title]]`, closing the brackets unless
    /// they are there already.
    func accept() {
        // Results for what was typed before the last keystroke name the wrong
        // thing: the first of what is typed now, found here — quickly.
        if let query, let runner, runner.shownQuery != query {
            show(StagedSearch(query: query, sources: runner.sources).first(), keepingSelection: false)
        }
        guard let textView, let storage = textView.textStorage, table.selectedRow >= 0, table.selectedRow < items.count else { return }
        let name = items[table.selectedRow].name
        let caret = textView.selectedRange().location
        let text = storage.string as NSString
        let closing = caret + 2 <= text.length && text.substring(with: NSRange(location: caret, length: 2)) == "]]"
        let range = NSRange(location: start, length: caret - start + (closing ? 2 : 0))
        textView.insertText(name + "]]", replacementRange: range)
    }

    @objc private func clicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
        textView?.acceptLinkCompletion()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ChooserCell.identifier, owner: nil) as? ChooserCell ?? ChooserCell()
        cell.show(items[row])
        return cell
    }
}
