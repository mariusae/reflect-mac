import AppKit
import ReflectCore
import PrismCore
import ReflectUI

/// Prism in the menu bar, whatever is in front: a Quick Note, today, its
/// open tasks — each opening its note — and a sync, without the window.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var session: Session?
    private let quickNote: () -> Void

    init(session: Session, quickNote: @escaping () -> Void) {
        self.session = session
        self.quickNote = quickNote
        super.init()
        item.button?.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Prism")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Made as it opens: today's tasks as they are then.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let note = ClosureMenuItem(title: "Quick Note…") { [weak self] in self?.quickNote() }
        note.keyEquivalent = " "
        note.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(note)
        menu.addItem(ClosureMenuItem(title: "Open Today") { [weak self] in self?.open(GraphPaths.dailyPath(for: .today)) })
        guard let session else { return }
        let today = Day.today
        let open = session.index.tasks().filter { !$0.done && ($0.day == today || $0.dueDate == today) }
        if !open.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Today’s Tasks", action: nil, keyEquivalent: "")
            heading.isEnabled = false
            menu.addItem(heading)
            for task in open.prefix(12) {
                let row = ClosureMenuItem(title: InlineMarkup.plainText(task.text)) { [weak self] in self?.open(task.notePath) }
                row.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
                menu.addItem(row)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Sync Now") { [weak self] in self?.session?.syncNow() })
    }

    /// A note, in the window — one made again, if none is open.
    private func open(_ path: String) {
        guard let session else { return }
        if session.windows.isEmpty { session.restoreWindows() }
        guard let window = session.windows.first else { return }
        window.showWindow(nil)
        window.open(path)
        NSApp.activate()
    }
}
