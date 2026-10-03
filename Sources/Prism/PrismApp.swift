import AppKit
import ReflectCore
import ReflectUI

/// Prism: the same notes as Reflect Mac, set for reading and writing and
/// little else. It writes notes, but leaves syncing to Reflect.
@MainActor
final class PrismApp: NSObject, NSApplicationDelegate {
    private var controller: PrismWindowController?
    private var settings: SettingsWindowController?

    /// View ▸ Appearance: light, dark, or as the system is.
    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let appearance = (sender.representedObject as? String).flatMap(Appearance.init(rawValue:)) else { return }
        Appearance.current = appearance
    }

    /// Prism ▸ Settings: the typography window.
    @objc func showSettings(_ sender: Any?) {
        guard let controller else { return }
        let settings = settings ?? SettingsWindowController(prism: controller)
        self.settings = settings
        settings.showWindow(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Where its notes were left, kept apart from Reflect Mac's.
        SessionState.folder = "Prism"
        Appearance.current.apply()
        Typeface.registerBundled()
        NSApp.mainMenu = Self.menu()
        guard let root = graphRoot() else { return NSApp.terminate(nil) }
        let controller = PrismWindowController(graph: Graph(root: root, git: nil))
        self.controller = controller
        let environment = ProcessInfo.processInfo.environment
        if environment["PRISM_SNAP"] != nil {
            runScript(controller, environment)
            return
        }
        controller.showWindow(nil)
        NSApp.activate()
    }

    /// The graph: `PRISM_GRAPH`, or `-GraphPath`, or the one Prism last
    /// opened, or Reflect Mac's; else asked for.
    private func graphRoot() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["PRISM_GRAPH"],
            UserDefaults.standard.string(forKey: "GraphPath"),
            UserDefaults(suiteName: "com.mariusae.ReflectMac")?.string(forKey: "GraphPath"),
        ]
        if let path = candidates.compactMap({ $0 }).first {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose the folder your Reflect graph is checked out in."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: "GraphPath")
        return url
    }

    /// `PRISM_SNAP=<png>`: draws the window, without showing it, to a
    /// picture, then quits. `PRISM_NOTE` is the note to go to (a graph
    /// path), `PRISM_FACE`, `PRISM_SIZE` and `PRISM_LINE` (line height, in ems) the type, `PRISM_DARK=1` the
    /// dark appearance; `PRISM_TYPE` text typed at the note's end (a newline
    /// for Return), `PRISM_FOLLOW` `[[titles]]` followed
    /// as plain clicks (`|` between), `PRISM_HEADER` a note whose header in the timeline is clicked, `PRISM_BACK=1` Back, `PRISM_SWITCH` ⌘E's cards
    /// opened and moved so many, `PRISM_SHEETS=1` the stacks printed, `PRISM_DRAG`
    /// and `PRISM_DRAGSHOW` (`column:index|top:fraction`) a sheet dragged there, `PRISM_COLLAPSE` a note
    /// whose rows are all collapsed, `PRISM_COLUMN` a `[[title]]` opened in a column of its
    /// own, `PRISM_MOVE` a note whose first item is moved to the end of the
    /// last column's, `PRISM_BACKLINKS` a note whose backlinks get a column,
    /// `PRISM_TIMELINE=1` a timeline column opened, `PRISM_INBOX_ADD` a note
    /// put in the inbox (or taken out) as from the Note menu, `PRISM_INBOX_REMOVE`
    /// one taken out as by its ×, `PRISM_INBOX=1` an inbox column opened; `PRISM_FIND` a query for the finder (`PRISM_FIND_COLUMN=1`: its first
    /// result chosen with ⌘↩), `PRISM_HOVER` a
    /// place down the scrubber (0 to 1) hovered, `PRISM_SCROLL` steps of
    /// scrolling, up for under 0, `PRISM_SETTINGS_SNAP` where to draw the Settings
    /// window, `PRISM_SIDEBAR=1` the
    /// sidebar out.
    private func runScript(_ controller: PrismWindowController, _ environment: [String: String]) {
        if environment["PRISM_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if environment["PRISM_DARK"] == "0" { NSApp.appearance = NSAppearance(named: .aqua) }
        controller.window?.setFrame(NSRect(x: -4000, y: 0, width: Double(environment["PRISM_WIDTH"] ?? "") ?? 1040, height: 760),
                                    display: false)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        if let face = environment["PRISM_FACE"].flatMap(Typeface.init(rawValue:)) { controller.face = face }
        if let size = environment["PRISM_SIZE"].flatMap(Double.init) { controller.size = CGFloat(size) }
        if let line = environment["PRISM_LINE"].flatMap(Double.init) {
            var settings = controller.face.settings
            settings.lineHeight = line
            controller.face.settings = settings
            controller.typographyChanged()
        }
        if let note = environment["PRISM_NOTE"] { controller.open(note) }
        if let text = environment["PRISM_TYPE"] {
            controller.typeForScript(text, in: environment["PRISM_NOTE"] ?? GraphPaths.dailyPath(for: .today))
        }
        if let path = environment["PRISM_COLLAPSE"] { controller.collapseAllForScript(in: path) }
        for title in (environment["PRISM_FOLLOW"] ?? "").split(separator: "|") { controller.followForScript(String(title)) }
        if let path = environment["PRISM_HEADER"] { controller.openAloneForScript(path) }
        if environment["PRISM_BACK"] == "1" { controller.goBack(nil) }
        // `column:index|top:fraction`: a sheet dragged there, and let go — or, for DRAGSHOW, shown on the way.
        for (key, perform) in [("PRISM_DRAG", true), ("PRISM_DRAGSHOW", false)] {
            let parts = (environment[key] ?? "").split(separator: ":")
            guard parts.count == 3, let column = Int(parts[0]), let fraction = Double(parts[2]) else { continue }
            controller.dragForScript(column: column, index: Int(parts[1]), at: CGFloat(fraction), perform: perform)
        }
        if environment["PRISM_FOLLOW"] != nil || environment["PRISM_BACK"] != nil || environment["PRISM_SHEETS"] != nil
            || environment["PRISM_HEADER"] != nil
            || environment["PRISM_DRAG"] != nil {
            print(controller.sheetsForScript)
        }
        if let moves = environment["PRISM_SWITCH"].flatMap(Int.init) { controller.switchForScript(moves: moves) }
        for title in (environment["PRISM_COLUMN"] ?? "").split(separator: "|") { controller.openInColumnForScript(String(title)) }
        if environment["PRISM_COLUMN"] != nil { print(controller.sheetsForScript) }
        if let path = environment["PRISM_MOVE"] { controller.moveRowForScript(from: path) }
        if environment["PRISM_TIMELINE"] == "1" { controller.showTimeline(nil) }
        if let path = environment["PRISM_INBOX_ADD"] { controller.toggleInboxForScript(path) }
        if let path = environment["PRISM_INBOX_REMOVE"] { controller.removeFromInboxForScript(path) }
        if environment["PRISM_INBOX"] == "1" { controller.showInbox(nil) }
        if environment["PRISM_TASKS"] == "1" { controller.showTasks(nil) }
        if environment["PRISM_KEY"] == "1" { controller.becomeKeyForScript() }
        if let query = environment["PRISM_SEARCH"] { controller.searchForScript(query) }
        if let words = environment["PRISM_SEARCH_TYPE"] {
            controller.typeSearchForScript(words, enter: environment["PRISM_ENTER"] == "1")
        }
        if environment["PRISM_WEEK"] == "1" { controller.goThisWeek(nil) }
        if let title = environment["PRISM_CARD"] { print("card:", LinkCard.noteSource?(title)?.ref.path ?? "no note") }
        if environment["PRISM_INBOX_SHEET"] == "1" { controller.showInboxSheet(nil) }
        if environment["PRISM_TICK"] == "1" { controller.tickFirstTaskForScript() }
        if let path = environment["PRISM_BACKLINKS"] { controller.showBacklinksForScript(path) }
        if let text = environment["PRISM_TYPE_BACKLINK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { controller.typeInBacklinkForScript(text) }
        }
        if environment["PRISM_FOLD"] == "1" {
            // Once the backlinks are found, in the background.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { controller.foldFirstBacklinkForScript() }
        }
        if let hover = environment["PRISM_HOVER"].flatMap(Double.init) { controller.hoverScrubberForScript(CGFloat(hover)) }
        if environment["PRISM_SIDEBAR"] == "1" { controller.showSidebarForScript() }
        if let query = environment["PRISM_FIND"] {
            controller.showFinder(query: query)
            if environment["PRISM_FIND_COLUMN"] == "1" { controller.chooseInNewColumnForScript() }
        }
        controller.window?.orderBack(nil)
        if let path = environment["PRISM_SETTINGS_SNAP"] {
            let settings = SettingsWindowController(prism: controller)
            self.settings = settings
            settings.window?.setFrameOrigin(NSPoint(x: -4000, y: 0))
            settings.window?.orderBack(nil)
            settings.window?.display()
            // The system's controls draw in layers, which caching the view
            // misses: the window's own frame view, rendered, has them.
            if let view = settings.window?.contentView?.superview {
                view.wantsLayer = true
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let scale = settings.window?.backingScaleFactor ?? 2
                let size = view.bounds.size
                if let layer = view.layer,
                   let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.scaleBy(x: scale, y: scale)
                    NSColor.windowBackgroundColor.setFill()
                    context.setFillColor(NSColor.windowBackgroundColor.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    layer.render(in: context)
                    if let image = context.makeImage() {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                }
            }
        }
        let steps = environment["PRISM_SCROLL"].flatMap(Int.init) ?? 0
        controller.scrollForScript(steps: steps) {
            if steps != 0 { print(controller.timelineForScript) }
            // `PRISM_WAIT`: seconds to stay up first, for changes made meanwhile.
            let wait = environment["PRISM_WAIT"].flatMap(Double.init) ?? 0.6
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                if environment["PRISM_DEBUG"] != nil { print(controller.scrollsForScript) }
                controller.snapshot(to: URL(fileURLWithPath: environment["PRISM_SNAP"]!))
                controller.save()
                exit(0)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.save() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func menu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Prism", [
            item("About Prism", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Settings…", #selector(PrismApp.showSettings(_:)), ","),
            .separator(),
            item("Hide Prism", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            .separator(),
            item("Quit Prism", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let find = item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f")
        find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            EditorMenus.selection(),
            .separator(),
            find,
        ])
        main.addItem(EditorMenus.format())
        main.addItem(EditorMenus.outline())
        let appearances = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        appearances.submenu = NSMenu(title: "Appearance")
        for appearance in Appearance.allCases {
            let choice = item(appearance.title, #selector(PrismApp.chooseAppearance(_:)))
            choice.representedObject = appearance.rawValue
            appearances.submenu?.addItem(choice)
        }
        let faces = NSMenuItem(title: "Typeface", action: nil, keyEquivalent: "")
        faces.submenu = NSMenu(title: "Typeface")
        for face in Typeface.available {
            let choice = item(face.title, #selector(PrismWindowController.chooseTypeface(_:)))
            choice.representedObject = face.rawValue
            faces.submenu?.addItem(choice)
        }
        submenu("View", [
            item("Show Sidebar", #selector(PrismWindowController.toggleSidebar(_:)), "s", [.command, .control]),
            .separator(),
            appearances,
            faces,
            item("Bigger", #selector(PrismWindowController.biggerText(_:)), "+"),
            item("Smaller", #selector(PrismWindowController.smallerText(_:)), "-"),
            item("Actual Size", #selector(PrismWindowController.actualSizeText(_:))),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        submenu("Note", [
            item("Add to Inbox", #selector(PrismWindowController.toggleInbox(_:)), "i", [.command, .shift]),
            item("Pin", #selector(PrismWindowController.togglePinned(_:)), "p", [.command, .shift]),
            item("Topic", #selector(PrismWindowController.toggleTopic(_:))),
            item("Private", #selector(PrismWindowController.togglePrivate(_:))),
            .separator(),
            item("Copy Link", #selector(PrismWindowController.copyNoteLink(_:))),
            item("Show in Finder", #selector(PrismWindowController.revealNoteInFinder(_:))),
        ])
        submenu("Column", [
            item("Timeline", #selector(PrismWindowController.showTimeline(_:)), "t", [.command, .option]),
            item("Backlinks", #selector(PrismWindowController.showBacklinks(_:)), "b", [.command, .option]),
            item("Inbox", #selector(PrismWindowController.showInbox(_:)), "i", [.command, .option]),
            item("Tasks", #selector(PrismWindowController.showTasks(_:)), "k", [.command, .option]),
            item("Search", #selector(PrismWindowController.showSearch(_:)), "f", [.command, .option]),
            .separator(),
            // The same, ⇧ held: in a new column, whatever is to the right.
            item("Timeline in New Column", #selector(PrismWindowController.showTimeline(_:)), "t", [.command, .option, .shift]),
            item("Backlinks in New Column", #selector(PrismWindowController.showBacklinks(_:)), "b", [.command, .option, .shift]),
            item("Inbox in New Column", #selector(PrismWindowController.showInbox(_:)), "i", [.command, .option, .shift]),
            item("Tasks in New Column", #selector(PrismWindowController.showTasks(_:)), "k", [.command, .option, .shift]),
            item("Search in New Column", #selector(PrismWindowController.showSearch(_:)), "f", [.command, .option, .shift]),
            .separator(),
            item("Timeline Here", #selector(PrismWindowController.showTimelineSheet(_:)), "t", [.command, .option, .control]),
            item("Backlinks Here", #selector(PrismWindowController.showBacklinksSheet(_:)), "b", [.command, .option, .control]),
            item("Inbox Here", #selector(PrismWindowController.showInboxSheet(_:)), "i", [.command, .option, .control]),
            item("Tasks Here", #selector(PrismWindowController.showTasksSheet(_:)), "k", [.command, .option, .control]),
            item("Search Here", #selector(PrismWindowController.showSearchSheet(_:)), "f", [.command, .option, .control]),
            .separator(),
            item("Switch Sheets", #selector(PrismWindowController.switchSheets(_:)), "e"),
            item("Switch Sheets Backward", #selector(PrismWindowController.switchSheetsBackward(_:)), "e", [.command, .shift]),
            .separator(),
            item("Close Column", #selector(PrismWindowController.closeColumn(_:)), "w"),
        ])
        submenu("Go", [
            item("Go to Note…", #selector(PrismWindowController.findNote(_:)), "o"),
            item("Today", #selector(PrismWindowController.goToday(_:)), "d"),
            item("This Week", #selector(PrismWindowController.goThisWeek(_:)), "y"),
            .separator(),
            item("Back", #selector(PrismWindowController.goBack(_:)), "["),
        ])
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        window.submenu = NSMenu(title: "Window")
        window.submenu?.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.submenu?.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}

extension PrismApp: NSMenuItemValidation {
    /// View ▸ Appearance: the one chosen, checked.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseAppearance(_:)) {
            item.state = item.representedObject as? String == Appearance.current.rawValue ? .on : .off
        }
        return true
    }
}
