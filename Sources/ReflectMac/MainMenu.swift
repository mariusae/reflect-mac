import AppKit

/// The menu bar, built in code. Every command the app has is here, with its
/// shortcut, because the menu bar is where a Mac user looks for them.
@MainActor
enum MainMenu {
    static let appName = "Reflect Mac"

    static func build() -> NSMenu {
        let main = NSMenu()
        let up = arrow(NSUpArrowFunctionKey), down = arrow(NSDownArrowFunctionKey)

        main.addItem(submenu(appName, [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(submenu("File", [
            item("Open Graph…", #selector(AppDelegate.openGraph(_:)), "o"),
            .separator(),
            item("Save", #selector(MainWindowController.saveDocument(_:)), "s"),
            item("Sync Now", #selector(MainWindowController.syncNow(_:)), "r"),
            .separator(),
            item("Show in Finder", #selector(MainWindowController.revealInFinder(_:)), "r", [.command, .shift]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ]))

        let find = submenu("Find", [
            findItem("Find…", .showFindInterface, "f"),
            findItem("Find Next", .nextMatch, "g"),
            findItem("Find Previous", .previousMatch, "g", [.command, .shift]),
            findItem("Use Selection for Find", .setSearchString, "e"),
            item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"),
        ])
        let spelling = submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
            item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
        ])
        let substitutions = submenu("Substitutions", [
            item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
            .separator(),
            item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
            item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
            item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
            item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ])
        let transformations = submenu("Transformations", [
            item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
            item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
            item("Capitalize", #selector(NSResponder.capitalizeWord(_:))),
        ])
        let speech = submenu("Speech", [
            item("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
            item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
        ])
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            submenu("Selection", [
                item("Select Paragraph", #selector(NSResponder.selectParagraph(_:)), "l", [.command, .shift]),
                item("Select Branch", #selector(OutlineTextView.selectBranch(_:)), "b", [.command, .shift]),
                .separator(),
                item("Expand Selection", #selector(OutlineTextView.expandSelection(_:)), up, [.command, .option]),
                item("Contract Selection", #selector(OutlineTextView.contractSelection(_:)), down, [.command, .option]),
            ]),
            .separator(),
            find,
            spelling,
            substitutions,
            transformations,
            speech,
        ]))

        let rowType = submenu("Row Type", [
            tagged(item("Body", #selector(OutlineTextView.setRowType(_:))), 0),
            tagged(item("Heading 1", #selector(OutlineTextView.setRowType(_:))), 1),
            tagged(item("Heading 2", #selector(OutlineTextView.setRowType(_:))), 2),
            tagged(item("Heading 3", #selector(OutlineTextView.setRowType(_:))), 3),
            tagged(item("Task", #selector(OutlineTextView.setRowType(_:))), 10),
            tagged(item("Ordered", #selector(OutlineTextView.setRowType(_:))), 11),
            tagged(item("Quote", #selector(OutlineTextView.setRowType(_:))), 12),
            tagged(item("Paragraph", #selector(OutlineTextView.setRowType(_:))), 13),
        ])
        main.addItem(submenu("Format", [
            item("Bold", #selector(OutlineTextView.toggleBold(_:)), "b"),
            item("Italic", #selector(OutlineTextView.toggleItalic(_:)), "i"),
            item("Code", #selector(OutlineTextView.toggleCode(_:)), "`", [.command, .shift]),
            item("Strikethrough", #selector(OutlineTextView.toggleStrikethrough(_:)), "-", [.command, .shift]),
            item("Link…", #selector(OutlineTextView.addLink(_:)), "k"),
            .separator(),
            rowType,
        ]))

        main.addItem(submenu("Outline", [
            item("New Row", #selector(OutlineTextView.newRow(_:)), "\r"),
            .separator(),
            item("Indent", #selector(OutlineTextView.indentRows(_:)), "]"),
            item("Outdent", #selector(OutlineTextView.outdentRows(_:)), "["),
            item("Move Up", #selector(OutlineTextView.moveRowsUp(_:)), up, [.command, .control]),
            item("Move Down", #selector(OutlineTextView.moveRowsDown(_:)), down, [.command, .control]),
            .separator(),
            item("Toggle Done", #selector(OutlineTextView.toggleDone(_:))),
            item("Duplicate", #selector(OutlineTextView.duplicateRows(_:)), "d", [.command, .shift]),
            item("Delete Rows", #selector(OutlineTextView.deleteRows(_:)), "k", [.command, .shift]),
            .separator(),
            item("Expand", #selector(OutlineTextView.expand(_:)), "0"),
            item("Collapse", #selector(OutlineTextView.collapse(_:)), "9"),
            item("Expand Completely", #selector(OutlineTextView.expandCompletely(_:)), "0", [.command, .control]),
            item("Collapse Completely", #selector(OutlineTextView.collapseCompletely(_:)), "9", [.command, .control]),
            item("Expand All", #selector(OutlineTextView.expandAll(_:)), "0", [.command, .option]),
            item("Collapse All", #selector(OutlineTextView.collapseAll(_:)), "9", [.command, .option]),
        ]))

        main.addItem(submenu("View", [
            item("Bigger", #selector(MainWindowController.makeTextBigger(_:)), "+"),
            item("Smaller", #selector(MainWindowController.makeTextSmaller(_:)), "-"),
            item("Actual Size", #selector(MainWindowController.makeTextStandardSize(_:))),
            .separator(),
            item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]),
            item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(submenu("Go", [
            item("Today", #selector(MainWindowController.goToToday(_:)), "t"),
            .separator(),
            item("Previous Day", #selector(MainWindowController.goToPreviousDay(_:)), up, [.control, .option]),
            item("Next Day", #selector(MainWindowController.goToNextDay(_:)), down, [.control, .option]),
            .separator(),
            item("Next Note Needing Review", #selector(MainWindowController.goToNextConflict(_:))),
        ]))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Console", #selector(AppDelegate.showConsole(_:)), "l", [.command, .option]),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu

        let help = submenu("Help", [])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func arrow(_ key: Int) -> String { String(UnicodeScalar(key)!) }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func tagged(_ item: NSMenuItem, _ tag: Int) -> NSMenuItem {
        item.tag = tag
        return item
    }

    private static func findItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                                 _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = self.item(title, #selector(NSResponder.performTextFinderAction(_:)), key, modifiers)
        item.tag = action.rawValue
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}
