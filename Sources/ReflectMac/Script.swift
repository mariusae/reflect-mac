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
                let roots = [controller.window?.contentView] + (controller.window?.childWindows ?? []).map(\.contentView)
                if let button = roots.compactMap({ $0 }).lazy.compactMap(find).first {
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
                    // As the menu would: to whatever has the keyboard, else the window.
                    if !(controller.window?.firstResponder?.tryToPerform(action, with: item) ?? false) {
                        NSApp.sendAction(action, to: controller, from: item)
                    }
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
            case "open":
                // open <path> [split]: as if chosen in the chooser.
                let (path, mode) = split(argument)
                controller.workspace.show(NoteRef(path: path), inSplit: mode == "split")
            case "link":
                // link <title> [split]: as if a [[title]] were followed.
                let parts = argument.components(separatedBy: " | ")
                // Through NSURL, as a link out of the text arrives.
                let url = (URL.wiki(parts[0])! as NSURL) as URL
                controller.workspace.open(url, inSplit: parts.count > 1)
            case "choose":
                // choose <query>: the chooser, showing what a query finds.
                controller.openQuickly(nil)
                let items = OpenQuickly.items(for: argument, index: controller.index, search: ReflectSearchIndex(root: controller.graph.root), pictures: controller.pictureText.index)
                print("choose “\(argument)”: " + items.prefix(8).map { "\($0.title) [\($0.detail?.string.prefix(50) ?? "")]" }.joined(separator: " · "))
                fflush(stdout)
            case "sidebar-search":
                controller.sidebar.search(for: argument)
            case "sidebar-open":
                controller.sidebar.openRow(containing: argument)
            case "window-id":
                print("window-id \(controller.window?.windowNumber ?? 0)")
                fflush(stdout)
            case "dividers":
                // Where the split view's dividers are, and the toolbar's separators, in the window.
                if let split = controller.window?.contentViewController as? NSSplitViewController, let window = controller.window {
                    let views = split.splitView.arrangedSubviews
                    let edges = views.map { view in
                        let frame = view.convert(view.bounds, to: nil)
                        return "\(frame.minX)–\(frame.maxX)\(view.isHidden ? " hidden" : "")"
                    }
                    print("dividers: subviews " + split.splitView.subviews.map { "\(type(of: $0)) \($0.frame.minX)–\($0.frame.maxX)" }.joined(separator: " | ")
                          + " vertical \(split.splitView.isVertical) arranges \(split.splitView.arrangesAllSubviews) delegate \(String(describing: split.splitView.delegate))")
                    print("dividers: panes " + edges.joined(separator: " | ") + " splitView at \(split.splitView.convert(split.splitView.bounds, to: nil).minX) thickness \(split.splitView.dividerThickness)")
                    for item in window.toolbar?.items ?? [] where item is NSTrackingSeparatorToolbarItem {
                        let view = item.value(forKey: "_view") as? NSView ?? item.view
                        let frame = view.map { $0.convert($0.bounds, to: nil) } ?? .zero
                        print("dividers: separator \(item.itemIdentifier.rawValue) index \((item as! NSTrackingSeparatorToolbarItem).dividerIndex) at \(frame.minX)–\(frame.maxX)")
                    }
                    // The toolbar's own view: where its parts are drawn.
                    if let toolbarView = window.standardWindowButton(.closeButton)?.superview?.superview {
                        func walk(_ view: NSView, _ depth: Int) {
                            guard depth < 7 else { return }
                            let name = String(describing: type(of: view))
                            if name.contains("Section") || name.contains("Separator") || name.contains("Background") || name.contains("Platter") {
                                print("dividers: view \(name) at \(view.convert(view.bounds, to: nil).minX)–\(view.convert(view.bounds, to: nil).maxX)")
                            }
                            for sub in view.subviews { walk(sub, depth + 1) }
                        }
                        walk(toolbarView, 0)
                    }
                    fflush(stdout)
                }
            case "side-state":
                let item = controller.workspace.sideItem
                if let split = controller.window?.contentViewController as? NSSplitViewController {
                    print("split: " + split.splitView.arrangedSubviews.map { "\($0.frame.origin.x),\($0.frame.width)\($0.isHidden ? " hidden" : "")" }.joined(separator: " | "))
                }
                print("side: collapsed \(item.isCollapsed) frame \(controller.workspace.side.view.frame) window \(controller.window?.frame.size ?? .zero) note \(controller.workspace.side.ref?.path ?? "-")")
                fflush(stdout)
            case "sidebar-open-split":
                controller.sidebar.openRow(containing: argument, inSplit: true)
            case "sidebar":
                // sidebar [section]: what the sidebar shows.
                print("sidebar: " + controller.sidebar.shownRows.prefix(40).joined(separator: " | "))
                fflush(stdout)
            case "backlinks-of":
                // backlinks-of <path>: the sidebar's backlinks, as if the keyboard were there.
                controller.sidebar.follow(argument)
            case "tick-task":
                // tick-task <text>: the task's checkbox in the Tasks list clicked.
                controller.sidebar.tickTask(containing: argument)
            case "sort-tags":
                controller.sidebar.sort(tagsBy: argument == "count" ? .count : .name)
            case "move-pinned":
                // move-pinned <from> <to>: a pinned note dragged to a new place.
                let parts = argument.split(separator: " ").compactMap { Int($0) }
                if parts.count == 2 { controller.sidebar.movePinned(from: parts[0], to: parts[1]) }
            case "trash-note":
                // trash-note <path>: moved to the Trash, as if confirmed.
                controller.trash(argument)
            case "note-end":
                // note-end: the main note scrolled to its end; whether it shows backlinks.
                controller.workspace.main?.scrollToEnd()
                print("note-end backlinks \(controller.workspace.main?.showsBacklinks ?? false)")
                fflush(stdout)
            case "post-return":
                // post-return [cmd|opt]: a real Return press, to whatever window is key.
                // As the app hands a key press on: a key equivalent first, then to the window.
                if let window = NSApp.windows.first(where: { $0 is ChooserPanel && $0.isVisible }) ?? NSApp.keyWindow ?? controller.window {
                    let flags: NSEvent.ModifierFlags = argument == "cmd" ? .command : argument == "opt" ? .option : []
                    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                        if flags.isEmpty || !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
                    }
                }
            case "snap-popover":
                for window in NSApp.windows where window.isVisible && String(describing: type(of: window)).contains("Popover") {
                    write(window, name: argument)
                }
            case "calendar-pick":
                // calendar-pick <yyyy-mm-dd>: that day, picked in the open calendar.
                if let day = Day(argument),
                   let picker = NSApp.windows.compactMap({ $0.contentView?.firstDescendant(of: CalendarPickerView.self) }).first {
                    picker.onPick?(day, false)
                }
            case "settings":
                SettingsWindowController.shared.show()
            case "snap-settings":
                if let window = SettingsWindowController.shared.window { write(window, name: argument) }
            case "typography":
                // typography <key> <value>: a setting set, as its control would.
                let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                var typography = Typography.current
                switch parts.first {
                case "body": typography.bodyFamily = parts.count > 1 ? parts[1] : nil
                case "heading": typography.headingFamily = parts.count > 1 ? parts[1] : nil
                case "mono": typography.monospaceFamily = parts.count > 1 ? parts[1] : nil
                case "bodyface": typography.bodyFace = parts.count > 1 ? parts[1] : nil
                case "headingface": typography.headingFace = parts.count > 1 ? parts[1] : nil
                case "line": typography.lineHeight = CGFloat(Double(parts[1]) ?? 1.18)
                case "rows": typography.rowSpacing = CGFloat(Double(parts[1]) ?? 0.2)
                case "length": typography.lineLength = CGFloat(Double(parts[1]) ?? 720)
                case "reset": typography = .defaults
                case "preset": typography = Typography.presets.first { $0.name == parts[1] }?.typography ?? typography
                default: break
                }
                Typography.current = typography
            case "caret-row":
                // caret-row <n>: the caret at the end of row n of the note the keyboard is in.
                if let editor = controller.window?.firstResponder as? OutlineTextView, let n = Int(argument), n < editor.paragraphRanges.count {
                    let paragraph = editor.paragraphRanges[n]
                    editor.setSelectedRange(NSRange(location: paragraph.location + paragraph.length - 1, length: 0))
                }
            case "toolbar":
                if let toolbar = controller.window?.toolbar {
                    let visible = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier.rawValue))
                    print("toolbar: " + toolbar.items.map { item in
                        let frame = item.view.map { $0.convert($0.bounds, to: nil) }
                        return "\(item.itemIdentifier.rawValue)\(visible.contains(item.itemIdentifier.rawValue) ? "" : " (overflow)")\(frame.map { " @\(Int($0.minX))-\(Int($0.maxX))" } ?? "")"
                    }.joined(separator: " | ") + " window \(Int(controller.window?.frame.width ?? 0))")
                    fflush(stdout)
                }
            case "titlebar-views":
                // The title bar's views, where they are: to see what a snapshot may not.
                if let root = controller.window?.standardWindowButton(.closeButton)?.superview?.superview {
                    func walk(_ view: NSView, _ depth: Int) {
                        let name = String(describing: type(of: view))
                        if name.contains("ItemViewer") || name.contains("Glass") || name.contains("Group") || name.contains("Platter") || view is ProgressRingButton {
                            let frame = view.convert(view.bounds, to: nil)
                            print("titlebar: \(String(repeating: " ", count: depth))\(name) \(Int(frame.minX))-\(Int(frame.maxX))\(view.isHidden ? " hidden" : "")")
                        }
                        for sub in view.subviews { walk(sub, depth + 1) }
                    }
                    walk(root, 0)
                    fflush(stdout)
                }
            case "next-unfinished":
                controller.goToNextUnfinished(nil)
                if let editor = controller.window?.firstResponder as? OutlineTextView {
                    print("next-unfinished row \(editor.rowIndex(at: editor.selectedRange().location)) of \(editor.paragraphRanges.count): \(editor.checkboxProgress.map { "\($0.done)/\($0.total)" } ?? "none")")
                    fflush(stdout)
                }
            case "peek-mode":
                // peek-mode <n>: a mode chosen in the peeking sidebar, as its control would.
                if let mode = Int(argument).flatMap(SidebarViewController.Mode.init(rawValue:)) { controller.peek?.sidebar.show(mode) }
            case "modes":
                print("modes: " + controller.sidebars.map { "\($0.mode.title)" }.joined(separator: " / "))
                fflush(stdout)
            case "peek":
                // peek [hide]: the sidebar, put away, peeking out — or back.
                if argument == "hide" { controller.peek?.hide() } else { controller.peek?.show() }
            case "open-window":
                controller.openInWindow(argument)
            case "note-windows":
                print("note-windows: " + controller.noteWindows.map { "\($0.key) “\($0.value.window?.title ?? "")” key=\($0.value.window?.isKeyWindow == true)" }.sorted().joined(separator: " | "))
                fflush(stdout)
            case "window-type":
                // window-type <text>: typed at the end of the note in the window of its own that is in front.
                if let note = controller.noteWindows.values.first(where: { $0.window?.isKeyWindow == true }) ?? controller.noteWindows.values.first {
                    let editor = note.pane.noteView.editor
                    editor.window?.makeFirstResponder(editor)
                    editor.setSelectedRange(NSRange(location: max(0, (editor.textStorage?.length ?? 1) - 1), length: 0))
                    editor.insertText(argument, replacementRange: editor.selectedRange())
                }
            case "snap-note-window":
                if let note = controller.noteWindows.values.first, let window = note.window { write(window, name: argument) }
            case "close-note-windows":
                for note in controller.noteWindows.values { note.close() }
            case "rows":
                // rows: the rows of the note the keyboard is in, as the editor holds them.
                if let editor = controller.window?.firstResponder as? OutlineTextView {
                    print("caret: \(editor.selectedRange()) row \(editor.rowIndex(at: editor.selectedRange().location))")
                    print("rows: " + editor.rows.map { "\($0.kind)/\($0.depth)/\($0.text.debugDescription)/gap\($0.gap.count)" }.joined(separator: " | "))
                    fflush(stdout)
                }
            case "settle-title":
                // settle-title: a waiting rename, settled now, as leaving the note would.
                controller.workspace.main?.settleTitle()
                controller.workspace.side.pane?.settleTitle()
            case "topic":
                controller.toggleTopic(nil)
            case "pin":
                controller.togglePinned(nil)
            case "picture-text":
                // picture-text <query>: the pictures whose text has the words.
                let pictures = controller.pictureText.index
                print("picture-text \(pictures.count) pictures with text; “\(argument)”: "
                      + pictures.search(argument).prefix(5).map { "\($0.path) → \(controller.index.notes(showing: $0.path))" }.joined(separator: " · "))
                fflush(stdout)
            case "type-chooser-timed":
                // type-chooser-timed <text>: each character typed on its own,
                // with how long the main thread was held for each.
                if let panel = NSApp.windows.first(where: { $0 is ChooserPanel }), let field = panel.firstResponder as? NSTextView {
                    var times: [String] = []
                    for character in argument {
                        let start = Date()
                        field.insertText(String(character), replacementRange: field.selectedRange())
                        times.append(String(format: "%@ %.1fms", String(character), Date().timeIntervalSince(start) * 1000))
                    }
                    print("typed: " + times.joined(separator: ", "))
                    fflush(stdout)
                }
            case "type-chooser":
                if let panel = NSApp.windows.first(where: { $0 is ChooserPanel }), let field = panel.firstResponder as? NSTextView {
                    field.insertText(argument, replacementRange: field.selectedRange())
                }
            case "snap-children":
                for child in controller.window?.childWindows ?? [] where child.isVisible { write(child, name: argument) }
            case "snap-chooser":
                if let panel = NSApp.windows.first(where: { $0 is ChooserPanel }) { write(panel, name: argument) }
            case "back":
                controller.goBack(nil)
            case "close-split":
                controller.closeSplitView(nil)
            case "title":
                print("title: \(controller.window?.title ?? "")")
                fflush(stdout)
            case "click-text", "option-click-text", "command-click-text":
                // click-text <text>: a real click, through the window, in the
                // middle of that text in the note the keyboard is in.
                if let editor = controller.window?.firstResponder as? OutlineTextView, let window = controller.window,
                   let layout = editor.layoutManager, let container = editor.textContainer {
                    let range = (editor.string as NSString).range(of: argument)
                    guard range.location != NSNotFound else { print("script: no \(argument)"); break }
                    let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + range.length / 2, length: 1), actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    let point = editor.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                    let flags: NSEvent.ModifierFlags = command == "option-click-text" ? [.option] : command == "command-click-text" ? [.command] : []
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                            NSApp.postEvent(event, atStart: false)
                        }
                    }
                }
            case "drop-picture":
                // drop-picture <on|above|below|margin> <text>: the first picture
                // dragged to that text, just above or below its row, or into the
                // space before it — as a drop at that point would take it.
                if let editor = controller.window?.firstResponder as? OutlineTextView,
                   let layout = editor.layoutManager, let container = editor.textContainer, let storage = editor.textStorage {
                    let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { break }
                    var picture: NSRange?
                    storage.enumerateAttribute(.outlineImage, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                        if value != nil { picture = range; stop.pointee = true }
                    }
                    let range = (editor.string as NSString).range(of: parts[1])
                    guard let picture, range.location != NSNotFound,
                          let span = editor.spans(atRowOf: picture.location).first(where: { $0.range.location == picture.location })
                    else { print("script: no picture or no \(parts[1])"); break }
                    let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + range.length / 2, length: 1), actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    let line = layout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                        .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
                    let point: NSPoint = switch parts[0] {
                    case "above": NSPoint(x: rect.midX, y: line.minY + 1)
                    case "below": NSPoint(x: rect.midX, y: line.maxY - 1)
                    case "margin": NSPoint(x: editor.textContainerOrigin.x + 4, y: rect.midY)
                    default: NSPoint(x: rect.midX, y: line.minY + 10)
                    }
                    let drop = editor.pictureDrop(at: point)
                    print("drop \(drop)")
                    editor.movePicture((editor.string as NSString).substring(with: span.range), from: (editor, span.range), to: drop)
                }
            case "hover-text":
                // hover-text <text>: the pointer comes to rest on that text.
                if let editor = controller.window?.firstResponder as? OutlineTextView,
                   let layout = editor.layoutManager, let container = editor.textContainer {
                    let range = (editor.string as NSString).range(of: argument)
                    guard range.location != NSNotFound else { print("script: no \(argument)"); break }
                    let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + range.length / 2, length: 1), actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                    let point = NSPoint(x: rect.midX + editor.textContainerOrigin.x, y: rect.midY + editor.textContainerOrigin.y)
                    if let hover = editor.linkHover(at: point) {
                        LinkCard.shared.hover(hover, in: editor, anchor: editor.firstRect(forCharacterRange: hover.range, actualRange: nil))
                    } else {
                        print("script: no link at \(argument)")
                    }
                }
            case "clipboard-paste":
                // clipboard-paste <image>: the image alone on the clipboard,
                // Edit ▸ Paste as the menu has it, then the clipboard as it was.
                let board = NSPasteboard.general
                let saved = (board.pasteboardItems ?? []).map { item in
                    item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
                }
                board.clearContents()
                board.setData(try? Data(contentsOf: URL(fileURLWithPath: argument)), forType: .png)
                func find(_ menu: NSMenu?) -> NSMenuItem? {
                    for item in menu?.items ?? [] {
                        if item.action == #selector(NSText.paste(_:)) { return item }
                        if let found = find(item.submenu) { return found }
                    }
                    return nil
                }
                if let item = find(NSApp.mainMenu), let editor = controller.window?.firstResponder as? OutlineTextView {
                    let enabled = editor.validateUserInterfaceItem(item)
                    print("paste enabled: \(enabled)")
                    if enabled { editor.paste(item) }
                }
                board.clearContents()
                for item in saved {
                    let restored = NSPasteboardItem()
                    for (type, data) in item { restored.setData(data, forType: type) }
                    board.writeObjects([restored])
                }
                fflush(stdout)
            case "drop-file":
                // drop-file <path>: a drag of a file, from a pasteboard of
                // the script's own, into the note the keyboard is in.
                if let editor = controller.window?.firstResponder as? OutlineTextView {
                    let board = NSPasteboard(name: NSPasteboard.Name("ReflectScriptDrag"))
                    board.clearContents()
                    board.writeObjects([URL(fileURLWithPath: argument) as NSURL])
                    let drag = FakeDrag(pasteboard: board, location: editor.convert(NSPoint(x: 60, y: 10), to: nil), window: controller.window!)
                    let entered = editor.draggingEntered(drag)
                    let prepared = editor.prepareForDragOperation(drag)
                    let performed = editor.performDragOperation(drag)
                    print("drop: entered \(entered.rawValue) prepared \(prepared) performed \(performed)")
                }
                fflush(stdout)
            case "picture-menu":
                // picture-menu [item]: right-clicks the first picture in the
                // note the keyboard is in, lists its menu, and chooses an item.
                guard let editor = controller.window?.firstResponder as? OutlineTextView, let window = controller.window,
                      let storage = editor.textStorage, let layout = editor.layoutManager, let container = editor.textContainer else { break }
                var target: NSPoint?
                storage.enumerateAttribute(.outlineImage, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    guard value is ImageBox else { return }
                    let glyph = layout.glyphIndexForCharacter(at: range.location)
                    var lineGlyphs = NSRange()
                    let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
                    let characters = layout.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
                    if let frame = ImageLine.frames(in: storage, characters: characters, container: container, fragment: fragment, indent: 30).first?.frame {
                        target = NSPoint(x: frame.midX + editor.textContainerOrigin.x, y: frame.midY + editor.textContainerOrigin.y)
                    }
                    stop.pointee = true
                }
                guard let point = target,
                      let event = NSEvent.mouseEvent(with: .rightMouseDown, location: editor.convert(point, to: nil), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let menu = editor.menu(for: event) else { print("script: no picture menu"); break }
                print("menu: " + menu.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " · "))
                if !argument.isEmpty, let item = menu.items.first(where: { $0.title == argument }), let action = item.action {
                    let board = NSPasteboard.general
                    let saved = (board.pasteboardItems ?? []).map { item in
                        item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
                    }
                    NSApp.sendAction(action, to: item.target, from: item)
                    if argument.hasPrefix("Copy") {
                        let types = (board.types ?? []).map(\.rawValue)
                        print("clipboard: \(types) png \(board.data(forType: .png)?.count ?? 0) bytes")
                        board.clearContents()
                        for item in saved {
                            let restored = NSPasteboardItem()
                            for (type, data) in item { restored.setData(data, forType: type) }
                            board.writeObjects([restored])
                        }
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

/// A drag, as far as a drop needs one, for the script.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var numberOfValidItemsForDrop: Int = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

extension NSView {
    /// The first view of a kind in this one, itself included.
    func firstDescendant<T: NSView>(of kind: T.Type) -> T? {
        if let found = self as? T { return found }
        for view in subviews { if let found = view.firstDescendant(of: kind) { return found } }
        return nil
    }
}
