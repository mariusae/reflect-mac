import AppKit
import ReflectCore
import PrismCore
import ReflectUI
import ReflectGit2

/// Prism: the same notes as Reflect Mac, set for reading and writing and
/// little else. It keeps its own copy of the graph in step with GitHub, as
/// the iPhone does; or opens a folder another app keeps, syncing it when
/// asked (⌘R).
@MainActor
final class PrismApp: NSObject, NSApplicationDelegate {
    private var session: Session?
    private var settings: SettingsWindowController?
    /// Where the Prism browser extension sends the pages it captures.
    private var captureServer: CaptureServer?
    /// Signing in to GitHub, and choosing the graph.
    private var gitHub: GitHubWindowController?
    /// Told by the sync relay of pushes to Prism's own clone's repository.
    private var relay: SyncRelayListener?

    /// View ▸ Appearance: light, dark, or as the system is.
    @objc func chooseAppearance(_ sender: NSMenuItem) {
        guard let appearance = (sender.representedObject as? String).flatMap(Appearance.init(rawValue:)) else { return }
        Appearance.current = appearance
    }

    /// View ▸ Typeface.
    @objc func chooseTypeface(_ sender: NSMenuItem) {
        guard let face = Typeface(rawValue: sender.representedObject as? String ?? "") else { return }
        session?.face = face
    }

    @objc func biggerText(_ sender: Any?) { session.map { $0.size = min(26, $0.size + 1) } }
    @objc func smallerText(_ sender: Any?) { session.map { $0.size = max(11, $0.size - 1) } }
    @objc func actualSizeText(_ sender: Any?) { session.map { $0.size = CGFloat($0.face.defaults.size) } }

    /// File ▸ New Window (⇧⌘N): another window on the graph, on today.
    @objc func newWindow(_ sender: Any?) {
        guard let session else { return }
        session.newWindow().showWindow(nil)
        session.writeWindows()
    }

    /// File ▸ Open New Reader (⌥⇧⌘N): the inbox's links, one at a time,
    /// the oldest first, in a window of their own — the one open brought forward.
    @objc func openReadingQueue(_ sender: Any?) {
        session?.openReadingQueue().showWindow(nil)
    }

    /// Prism ▸ Settings: the typography window.
    @objc func showSettings(_ sender: Any?) {
        guard let session else { return }
        let settings = settings ?? SettingsWindowController(session: session)
        self.settings = settings
        settings.showWindow(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Where its notes were left, kept apart from Reflect Mac's.
        SessionState.folder = "Prism"
        Appearance.current.apply()
        Typeface.registerBundled()
        NSApp.mainMenu = Self.menu()
        let environment = ProcessInfo.processInfo.environment
        // Pages from the browser: on a port of Prism's own, beside Reflect
        // Mac's; a scripted run on another, beside the app in use.
        let scripted = environment["PRISM_SNAP"] != nil || environment["PRISM_CAPTURE_SCRIPT"] != nil
        let server = CaptureServer(app: "Prism", port: scripted ? 47_822 : 47_821,
                                   tokensKey: scripted ? "CaptureTokens (scripts)" : "CaptureTokens", isScripted: scripted)
        server.graphName = { [weak self] in self?.session?.graph.root.lastPathComponent ?? "" }
        server.onCapture = { [weak self] page, screenshot in
            guard let session = self?.session else { throw CocoaError(.fileWriteUnknown) }
            return try session.capture(page, screenshot: screenshot)
        }
        server.onOpen = { [weak self] path in self?.session?.openCaptured(path) }
        server.start()
        captureServer = server

        // `PRISM_GITHUB_SNAP=<png>`: the GitHub window drawn, no graph opened.
        if let path = environment["PRISM_GITHUB_SNAP"] {
            let window = GitHubWindowController(onCloned: {}, onOpenFolder: {}, closeGraph: {})
            window.window?.setFrameOrigin(NSPoint(x: -4000, y: 0))
            window.showWindow(nil)
            gitHub = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                // Drawn from its layers: SwiftUI's words are not in a view's cached display.
                guard let view = window.window?.contentView?.superview, let layer = view.layer,
                      let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let context = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
                context.cgContext.scaleBy(x: 2, y: 2)
                NSColor.windowBackgroundColor.setFill()
                layer.render(in: context.cgContext)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                exit(0)
            }
            return
        }
        // A script's graph, as it says; else Prism's own clone; else a
        // folder opened before — and, once, the offer of a clone of its own.
        if let path = environment["PRISM_GRAPH"] {
            // `PRISM_OWN_SYNC=1`: kept in step as Prism's own clone is, with the Mac's git.
            start(Graph(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)),
                  ownsSync: environment["PRISM_OWN_SYNC"] == "1")
        } else if GitHubGraph.exists {
            start(GitHubGraph.graph(), ownsSync: true)
        } else if let root = openedFolder() {
            start(Graph(root: root), ownsSync: false)
            if !UserDefaults.standard.bool(forKey: "OfferedGitHub"), !scripted {
                UserDefaults.standard.set(true, forKey: "OfferedGitHub")
                showGitHub(nil)
            }
        } else {
            showGitHub(nil)
            return
        }
        guard let session else { return }
        if environment["PRISM_SNAP"] != nil {
            runScript(session, environment)
            return
        }
        // `PRISM_CAPTURE_SCRIPT=1`: the capture server alone, for a script
        // to send pages to — no window, nothing brought forward.
        if environment["PRISM_CAPTURE_SCRIPT"] != nil { return }
        session.restoreWindows()
        session.windows.forEach { $0.showWindow(nil) }
        // The reading queue as it was left: open, if it was.
        if session.readingQueueWasOpen { session.openReadingQueue().showWindow(nil) }
        NSApp.activate()
    }

    /// Opens a graph; one open before is let go. Prism's own clone it
    /// keeps in step itself; a folder another app keeps, only when asked.
    private func start(_ graph: Graph, ownsSync: Bool) {
        closeGraph()
        let session = Session(graph: graph)
        if ownsSync { session.ownSync(prepare: graph.root == GitHubGraph.root ? GitHubGraph.prepare : {}) }
        self.session = session
        if graph.root == GitHubGraph.root {
            relay = GitHubGraph.listen { [weak session] in session?.syncForPush() }
        }
    }

    /// The graph open let go: written, and its windows closed.
    private func closeGraph() {
        relay?.stop()
        relay = nil
        guard let session else { return }
        session.save()
        session.endSync()
        session.windows.forEach { $0.window?.close() }
        self.session = nil
        settings?.close()
        settings = nil
    }

    /// Graph ▸ GitHub Account…: signing in, and the graph's repository.
    @objc func showGitHub(_ sender: Any?) {
        if let gitHub {
            gitHub.showWindow(nil)
            return
        }
        let window = GitHubWindowController(onCloned: { [weak self] in
            guard let self else { return }
            start(GitHubGraph.graph(), ownsSync: true)
            session?.frontWindow?.showWindow(nil)
        }, onOpenFolder: session == nil ? { [weak self] in
            guard let self, let root = chooseFolder() else { return }
            start(Graph(root: root), ownsSync: false)
            session?.frontWindow?.showWindow(nil)
        } : nil, closeGraph: { [weak self] in self?.closeGraph() })
        gitHub = window
        window.showWindow(nil)
        NSApp.activate()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gitHub = nil }
        }
    }

    /// The folder Prism last opened, or Reflect Mac's.
    private func openedFolder() -> URL? {
        let candidates = [
            UserDefaults.standard.string(forKey: "GraphPath"),
            UserDefaults(suiteName: "com.mariusae.ReflectMac")?.string(forKey: "GraphPath"),
        ]
        return candidates.compactMap { $0 }.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    private func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose the folder your Reflect graph is checked out in."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        UserDefaults.standard.set(url.path, forKey: "GraphPath")
        return url
    }

    /// `PRISM_SNAP=<png>`: the first window drawn, without showing it, to a
    /// picture, then quits. `PRISM_NOTE` the note to go to (a graph path),
    /// `PRISM_BESIDE` one opened beside it, `PRISM_LENS` the lens chosen,
    /// `PRISM_LIST=0` the list put away, `PRISM_SEARCH` words searched for,
    /// `PRISM_SCHEDULE=1` today's hours, `PRISM_READ=1` the note's page opened, `PRISM_READER=1` its reader toggled, `PRISM_TYPE` text typed at the
    /// note's end, `PRISM_LIST_STEP` ↓ pressed in the list so many times,
    /// `PRISM_FIND` ⌘K on a query, `PRISM_FACE`, `PRISM_SIZE` the type,
    /// `PRISM_DARK=1` the dark appearance, `PRISM_WAIT` seconds to wait first.
    private func runScript(_ session: Session, _ environment: [String: String]) {
        if environment["PRISM_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if environment["PRISM_DARK"] == "0" { NSApp.appearance = NSAppearance(named: .aqua) }
        if let face = environment["PRISM_FACE"].flatMap(Typeface.init(rawValue:)) { session.face = face }
        if let size = environment["PRISM_SIZE"].flatMap(Double.init) { session.size = CGFloat(size) }
        session.restoreWindows()
        guard let window = session.windows.first else { exit(1) }
        window.window?.setFrame(NSRect(x: -4000, y: 0, width: Double(environment["PRISM_WIDTH"] ?? "") ?? 1180,
                                       height: Double(environment["PRISM_HEIGHT"] ?? "") ?? 780), display: false)
        window.window?.orderBack(nil)
        window.window?.contentView?.layoutSubtreeIfNeeded()
        if let lens = environment["PRISM_LENS"].flatMap(Lens.init(rawValue:)) { window.chooseForScript(lens) }
        if environment["PRISM_LIST"] == "0" { window.toggleList(nil) }
        if let note = environment["PRISM_NOTE"] { window.open(note) }
        if let note = environment["PRISM_BESIDE"] { window.open(note, beside: true) }
        if environment["PRISM_SCHEDULE"] == "1" { window.showSchedule(nil) }
        if environment["PRISM_READ"] == "1" { window.readPage(nil) }
        if environment["PRISM_NOW_CARD"] == "1" { window.nowCardForScript() }
        if environment["PRISM_READER"] == "1" { window.readerForScript?.toggleReading() }
        if let by = environment["PRISM_TURN"].flatMap(Int.init) { window.readerForScript?.turn(by) }
        // `PRISM_HIGHLIGHT=<words>`: those words, found in the page read, highlighted — once it is in.
        if let words = environment["PRISM_HIGHLIGHT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { window.readerForScript?.highlightForScript(words) }
        }
        if let query = environment["PRISM_SEARCH"] { window.searchForScript(query) }
        if let text = environment["PRISM_TYPE"], let editor = window.activePaneForScript.note?.editor {
            window.window?.makeFirstResponder(editor)
            editor.enter(from: .bottom, x: .greatestFiniteMagnitude, scrolling: false)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if i > 0 { editor.insertNewline(nil) }
                editor.insertText(line, replacementRange: editor.selectedRange())
            }
        }
        if let steps = environment["PRISM_LIST_STEP"].flatMap(Int.init) { window.stepListForScript(steps) }
        if let query = environment["PRISM_FIND"] { window.commandBarForScript(query) }
        // `PRISM_BLOCKS_DROP=<path>#<ordinal>@<minute>`: a task dropped on the day's hours.
        if let spec = environment["PRISM_BLOCKS_DROP"], let at = spec.lastIndex(of: "@"), let hash = spec.lastIndex(of: "#"),
           let ordinal = Int(spec[spec.index(after: hash)..<at]), let minute = Int(spec[spec.index(after: at)...]),
           let schedule = window.activePaneForScript.scheduleForScript {
            schedule.place(task: String(spec[..<hash]), ordinal: ordinal, on: schedule.day, start: minute)
        }
        if let n = environment["PRISM_BLOCKS_EDIT"].flatMap(Int.init) { window.activePaneForScript.scheduleForScript?.editForScript(n) }
        if let path = environment["PRISM_SETTINGS_SNAP"] {
            let settings = SettingsWindowController(session: session)
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
        // `PRISM_QUEUE=1`: the reading queue's window drawn instead.
        if environment["PRISM_QUEUE"] == "1" {
            let queue = session.openReadingQueue()
            queue.window?.setFrame(NSRect(x: -4000, y: 0, width: Double(environment["PRISM_WIDTH"] ?? "") ?? 860,
                                          height: Double(environment["PRISM_HEIGHT"] ?? "") ?? 900), display: false)
            queue.window?.orderBack(nil)
            if environment["PRISM_READER"] == "1" { queue.readerForScript?.toggleReading() }
            let wait = environment["PRISM_WAIT"].flatMap(Double.init) ?? 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                queue.snapshot(to: URL(fileURLWithPath: environment["PRISM_SNAP"]!)) { exit(0) }
            }
            return
        }
        let wait = environment["PRISM_WAIT"].flatMap(Double.init) ?? 0.8
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            window.snapshot(to: URL(fileURLWithPath: environment["PRISM_SNAP"]!)) {
                session.save()
                exit(0)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { session?.save() }

    /// On the way out, what is written sent — a few seconds given to it —
    /// when Prism keeps the graph in step.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Session.quitting = true
        guard let session, session.ownsSync else { return .terminateNow }
        session.save()
        Task {
            await session.finishSync()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The Dock's icon clicked with no window open: one on today.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

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
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
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
        submenu("File", [
            item("New Row in Today", #selector(PrismWindow.writeToday(_:)), "n"),
            item("New Note", #selector(PrismWindow.newNote(_:)), "n", [.command, .option]),
            item("New Window", #selector(PrismApp.newWindow(_:)), "n", [.command, .shift]),
            item("Open New Reader", #selector(PrismApp.openReadingQueue(_:)), "n", [.command, .option, .shift]),
            .separator(),
            item("Close", #selector(PrismWindow.closePaneOrWindow(_:)), "w"),
        ])
        let find = item("Search…", #selector(PrismWindow.find(_:)), "f")
        let findInNote = item("Find in Note…", #selector(PrismWindow.findInNote(_:)), "f", [.command, .shift])
        findInNote.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
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
            findInNote,
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
            let choice = item(face.title, #selector(PrismApp.chooseTypeface(_:)))
            choice.representedObject = face.rawValue
            faces.submenu?.addItem(choice)
        }
        var lenses: [NSMenuItem] = Lens.allCases.enumerated().map { i, lens in
            let choice = item(lens.title, #selector(PrismWindow.showLens(_:)), lens.key)
            choice.tag = i
            choice.image = NSImage(systemSymbolName: lens.symbol, accessibilityDescription: nil)
            return choice
        }
        lenses += [
            item("Show List", #selector(PrismWindow.toggleList(_:)), "l", [.command, .option]),
            .separator(),
            item("Outline", #selector(PrismWindow.showOutline(_:)), "o", [.command, .option]),
            item("Schedule", #selector(PrismWindow.showSchedule(_:)), "s", [.command, .option]),
            .separator(),
            appearances,
            faces,
            item("Bigger", #selector(PrismApp.biggerText(_:)), "+"),
            item("Smaller", #selector(PrismApp.smallerText(_:)), "-"),
            item("Actual Size", #selector(PrismApp.actualSizeText(_:))),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
        submenu("View", lenses)
        submenu("Go", [
            item("Go to…", #selector(PrismWindow.showCommandBar(_:)), "k"),
            {
                // ⌘O, as it always was: the same.
                let alternate = item("Go to…", #selector(PrismWindow.showCommandBar(_:)), "o")
                alternate.isHidden = true
                alternate.allowsKeyEquivalentWhenHidden = true
                return alternate
            }(),
            item("Move to Heading…", #selector(PrismWindow.moveToHeading(_:)), "\\"),
            .separator(),
            item("Back", #selector(PrismWindow.goBack(_:)), "["),
            item("Forward", #selector(PrismWindow.goForward(_:)), "]"),
            .separator(),
            item("Today", #selector(PrismWindow.goToday(_:)), "d"),
            item("Previous Day", #selector(PrismWindow.previousDay(_:)), left, [.command, .control]),
            item("Next Day", #selector(PrismWindow.nextDay(_:)), right, [.command, .control]),
            item("This Week", #selector(PrismWindow.goThisWeek(_:)), "d", [.command, .shift]),
        ])
        submenu("Note", [
            item("Add to Inbox", #selector(PrismWindow.toggleInbox(_:)), "i", [.command, .shift]),
            item("Pin", #selector(PrismWindow.togglePinned(_:)), "p", [.command, .shift]),
            item("Topic", #selector(PrismWindow.toggleTopic(_:))),
            item("Private", #selector(PrismWindow.togglePrivate(_:))),
            .separator(),
            item("Add Cover…", #selector(PrismWindow.addCover(_:))),
            item("Remove Cover", #selector(PrismWindow.removeCover(_:))),
            .separator(),
            item("Read Note", #selector(PrismWindow.readPage(_:)), "r", [.command, .shift]),
            item("Reader", #selector(PrismWindow.toggleReaderMode(_:)), "e", [.command, .shift]),
            item("Highlight Passage", #selector(PrismWindow.highlightPassage(_:)), "h", [.command, .shift]),
            item("Previous Link", #selector(PrismWindow.previousSource(_:)), left, [.command, .option]),
            item("Next Link", #selector(PrismWindow.nextSource(_:)), right, [.command, .option]),
            .separator(),
            item("Copy Link", #selector(PrismWindow.copyNoteLink(_:))),
            item("Show in Finder", #selector(PrismWindow.revealNoteInFinder(_:))),
            .separator(),
            item("Move to Trash…", #selector(PrismWindow.trashNote(_:)), "\u{8}", [.command, .shift]),
        ])
        submenu("Graph", [
            item("Sync Now", #selector(PrismWindow.syncNow(_:)), "r"),
            item("GitHub Account…", #selector(PrismApp.showGitHub(_:))),
        ])
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        window.submenu = NSMenu(title: "Window")
        window.submenu?.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.submenu?.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let order = ["Prism", "File", "Edit", "Format", "View", "Outline", "Note", "Go", "Graph", "Window", "Help"]
        let items = main.items
        main.removeAllItems()
        for item in items.sorted(by: { (order.firstIndex(of: $0.submenu?.title ?? $0.title) ?? order.count) < (order.firstIndex(of: $1.submenu?.title ?? $1.title) ?? order.count) }) {
            main.addItem(item)
        }
        return main
    }
}

extension PrismApp: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseAppearance(_:)) {
            item.state = item.representedObject as? String == Appearance.current.rawValue ? .on : .off
        }
        if item.action == #selector(chooseTypeface(_:)) {
            item.state = item.representedObject as? String == session?.face.rawValue ? .on : .off
        }
        return true
    }
}
