import AppKit
import ReflectCore

/// Drives the app from a script, for trying it without a person at the
/// keyboard: with `REFLECT_SCRIPT=<file>` set, each line of the file is done
/// in turn once the window is up. Keys go through the app as real key
/// events, so they meet the same menus and key bindings typing would.
///
///     wait 0.5          pause
///     type some text    type it
///     key cmd+shift+k   press a key, with modifiers
///     snap name         draw the window into $REFLECT_SNAP_DIR/name.png
///     dump              print the note the keyboard is in, as saved
///     go 2026-09-24     go to a day
///     quit
@MainActor
enum Script {
    static func runIfRequested(_ controller: MainWindowController) {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_SCRIPT"],
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        // Commands in menus go to the key window, which a script run from a
        // terminal does not otherwise get.
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        step(lines[...], controller, after: 1.0)
    }

    private static func step(_ lines: ArraySlice<String>, _ controller: MainWindowController, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let line = lines.first else { return }
            let rest = lines.dropFirst()
            let (command, argument) = split(line)
            var next: TimeInterval = 0.05
            switch command {
            case "wait":
                next = TimeInterval(argument) ?? 0.5
            case "type":
                for character in argument { press(String(character), controller) }
            case "key":
                press(argument, controller)
            case "snap":
                snap(controller, name: argument)
            case "snap-console":
                ConsoleWindowController.shared.show()
                if let window = ConsoleWindowController.shared.window { write(window, name: argument) }
            case "dump":
                controller.timeline.saveAll()
                let day = controller.timeline.currentDay
                print("--- \(day)\n\(controller.graph.read(day) ?? "(no file)")---", terminator: "\n")
                fflush(stdout)
            case "go":
                if let day = Day(argument) { controller.timeline.focus(day) }
            case "scroll":
                // scroll <points> <times>: timed, to see how tiling keeps up.
                let parts = argument.split(separator: " ").compactMap { Double($0) }
                let clip = (controller.timeline.view as! NSScrollView).contentView
                let start = Date()
                for _ in 0..<Int(parts.count > 1 ? parts[1] : 1) {
                    clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY + parts[0]))
                    (controller.timeline.view as! NSScrollView).reflectScrolledClipView(clip)
                    clip.superview?.layoutSubtreeIfNeeded()
                    controller.window?.displayIfNeeded()
                }
                print(String(format: "scrolled in %.2fs, now at %@ (%.0f)", Date().timeIntervalSince(start),
                             controller.timeline.currentDay.description, clip.bounds.minY))
                fflush(stdout)
            case "verify":
                // Every daily note through the editor and back: nothing may change.
                let editor = OutlineTextView(metrics: controller.timeline.metrics)
                var checked = 0, failed: [String] = []
                for (day, _) in controller.graph.dailyNotes() {
                    guard let text = controller.graph.read(day) else { continue }
                    var outline = OutlineMarkdown.parse(text)
                    let rows = outline.rows
                    guard !rows.isEmpty else { continue }
                    editor.load(rows)
                    outline.rows = editor.rows
                    checked += 1
                    if OutlineMarkdown.serialize(outline) != text { failed.append(day.description) }
                }
                print("verified \(checked), failed \(failed.count): \(failed.prefix(20))")
                fflush(stdout)
            case "append":
                // append <day> <line>: another app writing the note.
                let (dayText, line) = split(argument)
                if let day = Day(dayText) {
                    try? controller.graph.write((controller.graph.read(day) ?? "") + line + "\n", for: day)
                }
            case "row":
                // row <n>: the caret to the start of that row of the note
                // the keyboard is in.
                if let editor = controller.window?.firstResponder as? OutlineTextView, let row = Int(argument) {
                    editor.editText(inRow: row, atEnd: false)
                }
            case "hover":
                // hover <row>: as if the pointer were over that row of the
                // note the keyboard is in.
                if let editor = controller.window?.firstResponder as? OutlineTextView, let row = Int(argument) {
                    let paragraph = editor.paragraphRanges[row]
                    let glyph = editor.layoutManager!.glyphIndexForCharacter(at: paragraph.location)
                    let fragment = editor.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    editor.hover(at: NSPoint(x: editor.textContainerOrigin.x + fragment.minX + 40,
                                             y: editor.textContainerOrigin.y + fragment.midY))
                }
            case "click":
                // click <title>: presses the button with that title.
                func find(_ view: NSView) -> NSButton? {
                    if let button = view as? NSButton, button.title == argument { return button }
                    for child in view.subviews { if let found = find(child) { return found } }
                    return nil
                }
                if let root = controller.window?.contentView, let button = find(root) {
                    button.performClick(nil)
                } else {
                    print("script: no button \(argument)")
                }
            case "menu":
                // menu <title>: chooses the menu item with that title.
                func find(_ menu: NSMenu?) -> NSMenuItem? {
                    for item in menu?.items ?? [] {
                        if item.title == argument { return item }
                        if let found = find(item.submenu) { return found }
                    }
                    return nil
                }
                if let item = find(NSApp.mainMenu), let action = item.action {
                    NSApp.sendAction(action, to: controller, from: item)
                }
            case "image":
                print("image \(argument): \(String(describing: controller.timeline.images.naturalSize(argument)))")
                fflush(stdout)
            case "attrs":
                // attrs <text>: the attributes where that text is, in the note the keyboard is in.
                if let editor = controller.window?.firstResponder as? OutlineTextView {
                    let range = (editor.string as NSString).range(of: argument)
                    if range.location != NSNotFound {
                        print(editor.textStorage!.attributes(at: range.location, effectiveRange: nil).keys.map(\.rawValue).sorted())
                        print("images: \(editor.images != nil)")
                    }
                }
                fflush(stdout)
            case "paste-file", "paste-image":
                // As if pasting a file, or a picture's bytes, from a
                // pasteboard of the script's own — never the clipboard.
                let board = NSPasteboard(name: NSPasteboard.Name("ReflectScript"))
                board.clearContents()
                let url = URL(fileURLWithPath: argument)
                if command == "paste-file" {
                    board.writeObjects([url as NSURL])
                } else if let data = try? Data(contentsOf: url) {
                    board.setData(data, forType: .png)
                }
                if let editor = controller.window?.firstResponder as? OutlineTextView {
                    editor.add(editor.incoming(from: board))
                }
            case "metrics":
                // metrics: how each row's first line is laid out.
                if let editor = controller.window?.firstResponder as? OutlineTextView, let layout = editor.layoutManager {
                    for (index, paragraph) in editor.paragraphRanges.enumerated() {
                        let glyph = layout.glyphIndexForCharacter(at: paragraph.location)
                        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                        let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                        let font = editor.textStorage!.attribute(.font, at: paragraph.location, effectiveRange: nil) as! NSFont
                        print("row \(index) len \(paragraph.length) fragment \(fragment) used \(used) glyphY \(layout.location(forGlyphAt: glyph).y) ts \(layout.typesetter.baselineOffset(in: layout, glyphIndex: glyph)) defBase \(layout.defaultBaselineOffset(for: font)) defLine \(layout.defaultLineHeight(for: font)) asc \(font.ascender) desc \(font.descender)")
                    }
                }
                fflush(stdout)
            case "views":
                print(controller.timeline.describeViews())
                fflush(stdout)
            case "state":
                let responder = controller.window?.firstResponder
                print("active=\(NSApp.isActive) key=\(controller.window?.isKeyWindow ?? false) responder=\(String(describing: responder.map { type(of: $0) }))")
                if let editor = responder as? OutlineTextView {
                    print("selection=\(editor.selectedRange()) rows=\(String(describing: editor.selectedRows)) caret=\(editor.caretPosition)")
                }
                fflush(stdout)
            case "quit":
                controller.timeline.saveAll()
                controller.recordState()
                SessionState.shared.writeNow()
                exit(0)
            case "place":
                let place = controller.timeline.place
                print("place \(place.day) +\(Int(place.offset)) focus \(String(describing: controller.timeline.focusedSelection))")
                fflush(stdout)
            default:
                print("script: what is \(line)?")
            }
            step(rest, controller, after: next)
        }
    }

    private static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]))
    }

    private static let keys: [String: (code: UInt16, character: String)] = [
        "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\u{7f}"),
        "esc": (53, "\u{1b}"), "forwarddelete": (117, String(UnicodeScalar(NSDeleteFunctionKey)!)),
        "left": (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!)),
        "right": (124, String(UnicodeScalar(NSRightArrowFunctionKey)!)),
        "down": (125, String(UnicodeScalar(NSDownArrowFunctionKey)!)),
        "up": (126, String(UnicodeScalar(NSUpArrowFunctionKey)!)),
    ]

    private static func press(_ spec: String, _ controller: MainWindowController) {
        guard let window = controller.window else { return }
        var parts = spec.count > 1 ? spec.split(separator: "+").map(String.init) : [spec]
        let name = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "ctrl": flags.insert(.control)
            case "opt": flags.insert(.option)
            default: break
            }
        }
        var key = keys[name] ?? (0, name)
        if name == "tab" && flags.contains(.shift) { key.character = "\u{19}" }
        if key.code >= 123 && key.code <= 126 { flags.formUnion([.function, .numericPad]) }
        let characters = flags.contains(.shift) && key.character.count == 1 && key.code == 0
            ? key.character.uppercased() : key.character
        // A menu's shortcut goes to its command directly: menus answer only
        // the key window, and an app started from a terminal has none.
        if !flags.intersection([.command, .control]).isEmpty,
           let item = menuItem(in: NSApp.mainMenu, key: key.character.lowercased(), flags: flags.intersection([.command, .control, .option, .shift])),
           let action = item.action {
            if !(window.firstResponder?.tryToPerform(action, with: item) ?? false) {
                NSApp.sendAction(action, to: nil, from: item)
            }
            return
        }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: key.character,
                                               isARepeat: false, keyCode: key.code) else { continue }
            NSApp.sendEvent(event)
        }
    }

    private static func menuItem(in menu: NSMenu?, key: String, flags: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if let found = menuItem(in: item.submenu, key: key, flags: flags) { return found }
            let mask = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
            if item.keyEquivalent.lowercased() == key, mask == flags || (mask.union(.shift) == flags && item.keyEquivalent != item.keyEquivalent.lowercased()) {
                return item
            }
        }
        return nil
    }

    private static func snap(_ controller: MainWindowController, name: String) {
        if let window = controller.window { write(window, name: name) }
    }

    private static func write(_ window: NSWindow, name: String) {
        guard let dir = ProcessInfo.processInfo.environment["REFLECT_SNAP_DIR"],
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
