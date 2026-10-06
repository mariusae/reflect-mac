import AppKit

/// The outline editor's commands, as menus: the same in every app that
/// has the editor, with the same shortcuts.
@MainActor
package enum EditorMenus {
    package static func selection() -> NSMenuItem {
        let up = arrow(NSUpArrowFunctionKey), down = arrow(NSDownArrowFunctionKey)
        return submenu("Selection", [
            item("Select Paragraph", #selector(NSResponder.selectParagraph(_:)), "l", [.command, .shift]),
            item("Select Branch", #selector(OutlineTextView.selectBranch(_:)), "b", [.command, .shift]),
            .separator(),
            item("Expand Selection", #selector(OutlineTextView.expandSelection(_:)), up, [.command, .option]),
            item("Contract Selection", #selector(OutlineTextView.contractSelection(_:)), down, [.command, .option]),
        ])
    }

    package static func format() -> NSMenuItem {
        let rowType = submenu("Row Type", [
            tagged(item("Body", #selector(OutlineTextView.setRowType(_:))), 0),
            tagged(item("Heading 1", #selector(OutlineTextView.setRowType(_:))), 1),
            tagged(item("Heading 2", #selector(OutlineTextView.setRowType(_:))), 2),
            tagged(item("Heading 3", #selector(OutlineTextView.setRowType(_:))), 3),
            tagged(item("Task", #selector(OutlineTextView.setRowType(_:))), 10),
            tagged(item("Checklist Item", #selector(OutlineTextView.setRowType(_:))), 14),
            tagged(item("Ordered", #selector(OutlineTextView.setRowType(_:))), 11),
            tagged(item("Quote", #selector(OutlineTextView.setRowType(_:))), 12),
            tagged(item("Paragraph", #selector(OutlineTextView.setRowType(_:))), 13),
        ])
        return submenu("Format", [
            item("Bold", #selector(OutlineTextView.toggleBold(_:)), "b"),
            item("Italic", #selector(OutlineTextView.toggleItalic(_:)), "i"),
            item("Code", #selector(OutlineTextView.toggleCode(_:)), "`", [.command, .shift]),
            item("Strikethrough", #selector(OutlineTextView.toggleStrikethrough(_:)), "-", [.command, .shift]),
            item("Highlight", #selector(OutlineTextView.toggleHighlight(_:)), "h", [.command, .shift]),
            item("Link…", #selector(OutlineTextView.addLink(_:)), "k"),
            .separator(),
            item("Bullet", #selector(OutlineTextView.toggleBullet(_:)), "8", [.command, .shift]),
            item("Checklist Item", #selector(OutlineTextView.cycleChecklist(_:)), "\r"),
            item("Task", #selector(OutlineTextView.cycleTask(_:)), "\r", [.command, .shift]),
            item("Horizontal Line", #selector(OutlineTextView.insertHorizontalRule(_:)), "-", [.command, .option]),
            item("Code Block", #selector(OutlineTextView.toggleCodeBlock(_:)), "c", [.command, .option]),
            rowType,
        ])
    }

    package static func outline() -> NSMenuItem {
        let up = arrow(NSUpArrowFunctionKey), down = arrow(NSDownArrowFunctionKey)
        return submenu("Outline", [
            item("New Row", #selector(OutlineTextView.newRow(_:)), "\r"),
            item("New Time Block", #selector(OutlineTextView.newTimeBlock(_:)), "\r", [.command, .option]),
            .separator(),
            item("Indent", #selector(OutlineTextView.indentRows(_:)), arrow(NSRightArrowFunctionKey), [.command, .control]),
            item("Outdent", #selector(OutlineTextView.outdentRows(_:)), arrow(NSLeftArrowFunctionKey), [.command, .control]),
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
            .separator(),
            item("Focus In", #selector(OutlineTextView.focusIn(_:)), arrow(NSRightArrowFunctionKey), [.command, .option]),
            item("Focus Out", #selector(OutlineTextView.focusOut(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option]),
            item("Unfocus", #selector(OutlineTextView.unfocus(_:))),
        ])
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
}
