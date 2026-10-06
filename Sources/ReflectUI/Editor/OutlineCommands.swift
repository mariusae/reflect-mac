import AppKit
import ReflectCore
import UniformTypeIdentifiers

/// The outline's commands, as the menus and keys reach them.
extension OutlineTextView {

    /// Applies an outline operation to the targeted rows, as one step to
    /// undo, and keeps the selection on the rows it was on.
    @discardableResult
    package func perform(_ name: String, on selection: Range<Int>? = nil, followingCaret: Bool = true,
                 _ transform: (inout [Row], Range<Int>) -> Range<Int>?) -> Bool {
        let before = rows
        let target = selection ?? targetRows
        let wasSelectingRows = isSelectingRows
        let caret = caretPosition
        var after = before
        guard let result = transform(&after, target) else {
            NSSound.beep()
            return false
        }
        replace(before, with: after, actionName: name)
        guard followingCaret else {
            // Done to rows the caret is not about — a checkbox clicked, a
            // bullet folded — the page stays where it is, and the caret on
            // the text it was on: rows a fold took in or let out shift the
            // ones after it, and a row folded away leaves it on the fold.
            if wasSelectingRows { return true }
            if caret.row < target.upperBound {
                restoreCaret(caret)
            } else {
                let row = caret.row + after.count - before.count
                if row < target.upperBound {
                    editText(inRow: target.lowerBound, atEnd: true, scrolling: false)
                } else {
                    restoreCaret(CaretPosition(row: row, offset: caret.offset))
                }
            }
            return true
        }
        if wasSelectingRows {
            selectRows(anchor: result.lowerBound, head: result.upperBound - 1)
        } else {
            let row = min(result.lowerBound + (caret.row - target.lowerBound), paragraphRanges.count - 1)
            restoreCaret(CaretPosition(row: max(row, 0), offset: caret.offset))
        }
        scrollRangeToVisible(selectedRange())
        return true
    }

    // MARK: New rows

    /// Return: the text after the caret becomes a new row. At the end of a
    /// row whose children are showing, the new row is its first child.
    package func splitRow() {
        if selectedRange().length > 0 { insertText("", replacementRange: selectedRange()) }
        let location = selectedRange().location
        let index = rowIndex(at: location)
        let paragraph = paragraphRanges[index]
        var all = rows
        let before = all
        let row = all[index]
        if row.kind == .code {
            if !leaveCodeBlock(at: index, offset: location - paragraph.location) { super.insertLineBreak(nil) }
            return
        }
        let offset = location - paragraph.location
        let length = paragraph.length - 1
        if offset == length, startNextTimeBlock(after: index, in: all) { return }

        var next = row
        next.text = ""
        next.folded = []
        next.continuationIndents = nil
        // A list with blank lines between its items goes on the same way;
        // the blank line before the first item of a list is the list's own.
        let hasSiblingAbove = OutlineEditing.previousSibling(all, before: index, depth: row.depth).map { all[$0].kind.isListItem } ?? false
        next.gap = !row.gap.isEmpty && hasSiblingAbove ? [""] : []
        if next.task != nil { next.task = .open }
        if next.kind == .ordered { next.number += 1 }
        switch next.kind {
        case .heading, .rule:
            next = Row(kind: .bullet, depth: row.depth, gap: [""])
        default:
            break
        }

        if offset == 0 && length > 0 {
            // At the start of a row, a new row opens above and the text stays
            // where it is, with its children.
            all.insert(next, at: index)
            replace(before, with: all, actionName: "New Row")
            restoreCaret(CaretPosition(row: index + 1, offset: 0))
        } else {
            let text = row.text as NSString
            all[index].text = text.substring(to: offset)
            next.text = text.substring(from: offset)
            if offset == length, OutlineEditing.subtreeEnd(all, index) > index + 1 {
                let child = all[index + 1]
                next.depth = child.depth
                if child.kind.isListItem && row.kind.isListItem {
                    next.kind = child.kind
                    next.marker = child.marker
                    next.number = 1
                    next.task = child.task == nil ? nil : .open
                }
                next.gap = child.gap
            }
            all.insert(next, at: index + 1)
            replace(before, with: all, actionName: "New Row")
            restoreCaret(CaretPosition(row: index + 1, offset: 0))
        }
        scrollRangeToVisible(selectedRange())
    }

    /// Return at the end of a time block with nothing under it: the next
    /// block, starting as this one ends, half an hour long.
    private func startNextTimeBlock(after index: Int, in all: [Row]) -> Bool {
        guard let next = Timeline.nextBlock(after: index, in: all) else { return false }
        var after = all
        after.insert(next, at: index + 1)
        replace(all, with: after, actionName: "New Row")
        restoreCaret(CaretPosition(row: index + 1, offset: (next.text as NSString).length))
        scrollRangeToVisible(selectedRange())
        return true
    }

    /// Outline ▸ New Time Block: a block from now, a quarter of an hour
    /// long, to name — and drag where it goes, or make longer.
    @objc package func newTimeBlock(_ sender: Any?) {
        let index = isSelectingRows ? targetRows.upperBound - 1 : rowIndex(at: selectedRange().location)
        let time = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let before = rows
        let made = Timeline.newBlock(in: before, at: index, now: (time.hour ?? 0) * 60 + (time.minute ?? 0))
        if selectedRows != nil { leaveRowSelection() }
        replace(before, with: made.rows, actionName: "New Time Block")
        restoreCaret(CaretPosition(row: made.row, offset: made.offset))
        scrollRangeToVisible(selectedRange())
    }

    /// A new row after a row, to write in.
    package func insertRow(after index: Int) {
        editText(inRow: index)
        splitRow()
    }

    /// Outline ▸ New Row: a new row after this one, leaving the selection's
    /// text alone.
    @objc package func newRow(_ sender: Any?) {
        insertRow(after: isSelectingRows ? targetRows.upperBound - 1 : rowIndex(at: selectedRange().location))
    }

    /// Markdown typed at the start of a row, then a space, sets the row's
    /// type — Bike's smart row types, in Reflect's Markdown.
    package func applySmartRowType() -> Bool {
        let location = selectedRange().location
        let index = rowIndex(at: location)
        let paragraph = paragraphRanges[index]
        let prefix = (textStorage!.string as NSString).substring(with: NSRange(location: paragraph.location, length: location - paragraph.location))
        var row = rows[index]
        guard row.task == nil, row.kind == .bullet || row.kind == .paragraph, !prefix.isEmpty, prefix.count <= 6 else { return false }
        let rest = String(row.text.dropFirst(prefix.count))

        switch prefix {
        case _ where prefix.allSatisfy({ $0 == "#" }):
            row.kind = .heading(prefix.count)
        case ">":
            row.kind = .quote
        case "[]", "[ ]", "[x]", "[X]", "-[]", "-[ ]":
            // As Reflect's editor reads them: a square checklist item.
            row.kind = .bullet
            row.marker = row.marker == "*" ? "*" : "-"
            row.task = prefix.lowercased() == "[x]" ? .done(prefix.contains("X") ? "X" : "x") : .open
        case "+":
            // `+`: one of Reflect's Tasks, round.
            row.kind = .bullet
            row.marker = "+"
            row.task = .open
        case _ where ["-", "*", "+"].contains(prefix) && row.kind == .paragraph:
            row.kind = .bullet
            row.marker = prefix.first!
        case _ where Self.ruleMarks.contains(prefix) && rest.isEmpty:
            // A line across, and a row after it to go on in.
            makeRule(at: index)
            return true
        default:
            let digits = prefix.dropLast()
            guard let delimiter = prefix.last, delimiter == "." || delimiter == ")",
                  !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) else { return false }
            row.kind = .ordered
            row.marker = delimiter
            row.number = number
        }
        row.spacing = 1
        row.text = rest
        replaceRow(index, with: row, actionName: "Change Row Type")
        restoreCaret(CaretPosition(row: index, offset: 0))
        return true
    }

    // MARK: Structure

    @objc package func indentRows(_ sender: Any?) {
        perform("Indent") { OutlineEditing.indent(&$0, $1) }
    }

    @objc package func outdentRows(_ sender: Any?) {
        perform("Outdent") { OutlineEditing.outdent(&$0, $1) }
    }

    @objc package func moveRowsUp(_ sender: Any?) {
        perform("Move Up") { OutlineEditing.moveUp(&$0, $1) }
    }

    @objc package func moveRowsDown(_ sender: Any?) {
        perform("Move Down") { OutlineEditing.moveDown(&$0, $1) }
    }

    @objc package func deleteRows(_ sender: Any?) {
        let wasSelectingRows = isSelectingRows
        var landing = 0
        perform("Delete Rows") { rows, selection in
            landing = OutlineEditing.delete(&rows, selection)
            return landing..<(landing + 1)
        }
        if !wasSelectingRows { restoreCaret(CaretPosition(row: landing, offset: 0)) }
    }

    @objc package func duplicateRows(_ sender: Any?) {
        perform("Duplicate") { rows, selection in OutlineEditing.duplicate(&rows, selection) }
    }

    /// Format ▸ Checklist Item (⌘Return): a square checkbox — open, checked,
    /// then a bullet again.
    @objc package func cycleChecklist(_ sender: Any?) {
        perform("Checklist Item") { rows, selection in
            OutlineEditing.cycle(.checklist, &rows, selection)
            return selection
        }
    }

    /// Format ▸ Task (⇧⌘Return): a round checkbox, one of Reflect's Tasks —
    /// open, checked, then a bullet again.
    @objc package func cycleTask(_ sender: Any?) {
        perform("Task") { rows, selection in
            OutlineEditing.cycle(.task, &rows, selection)
            return selection
        }
    }

    @objc package func toggleDone(_ sender: Any?) {
        perform("Toggle Done") { rows, selection in
            OutlineEditing.toggleDone(&rows, selection)
            return selection
        }
    }

    // MARK: Folding

    @objc package func collapse(_ sender: Any?) {
        fold(name: "Collapse") { rows, index in -OutlineEditing.fold(&rows, at: index) }
    }

    @objc package func expand(_ sender: Any?) {
        fold(name: "Expand") { rows, index in OutlineEditing.unfold(&rows, at: index) }
    }

    @objc package func collapseCompletely(_ sender: Any?) {
        fold(name: "Collapse") { rows, index in -OutlineEditing.foldCompletely(&rows, at: index) }
    }

    @objc package func expandCompletely(_ sender: Any?) {
        fold(name: "Expand") { rows, index in OutlineEditing.unfold(&rows, at: index, completely: true) }
    }

    @objc package func collapseAll(_ sender: Any?) {
        fold(name: "Collapse All", selection: 0..<paragraphRanges.count) { rows, index in
            -OutlineEditing.foldCompletely(&rows, at: index)
        }
    }

    @objc package func expandAll(_ sender: Any?) {
        fold(name: "Expand All", selection: 0..<paragraphRanges.count) { rows, index in
            OutlineEditing.unfold(&rows, at: index, completely: true)
        }
    }

    /// Folds or unfolds each targeted row that has children, keeping the
    /// selection on the rows it was on. `change` says how many rows came
    /// onto the screen, less how many left it.
    private func fold(name: String, selection: Range<Int>? = nil, _ change: (inout [Row], Int) -> Int) {
        perform(name, on: selection) { rows, selection in
            var changed = false
            var upper = selection.upperBound
            var index = selection.lowerBound
            // Only rows at the top of the selection's own subtrees: a
            // child folded into its parent is no longer there to fold.
            while index < min(upper, rows.count) {
                let delta = change(&rows, index)
                if delta != 0 { changed = true }
                upper += delta
                index = OutlineEditing.subtreeEnd(rows, index)
            }
            guard changed else { return nil }
            let limit = rows.count
            return min(selection.lowerBound, limit - 1)..<min(max(upper, selection.lowerBound + 1), limit)
        }
    }

    // MARK: Pasting rows

    /// Pasted Markdown of more than a line comes in as rows: in place of an
    /// empty row, or after the rows it was pasted onto.
    package func pasteRows(_ pasted: [Row]) {
        guard !pasted.isEmpty else { return }
        var all = rows
        let before = all
        let target = targetRows
        let at: Int, depth: Int
        let current = all[target.lowerBound]
        if !isSelectingRows, target.count == 1, current.text.isEmpty, !current.isFolded {
            all.remove(at: target.lowerBound)
            at = target.lowerBound
            depth = current.depth
        } else {
            at = OutlineEditing.block(all, target).upperBound
            depth = current.depth
        }
        let base = pasted.map(\.depth).min() ?? 0
        var incoming = pasted.map { row in
            var row = row
            row.depth = row.depth - base + depth
            return row
        }
        // A list with blank lines between its rows takes rows the same way.
        incoming[0].gap = at > 0 && !all[at - 1].gap.isEmpty ? [""] : []
        all.insert(contentsOf: incoming, at: at)
        OutlineEditing.normalize(&all)
        let wasSelectingRows = isSelectingRows
        replace(before, with: all, actionName: "Paste")
        let last = at + incoming.count - 1
        if wasSelectingRows {
            selectRows(anchor: at, head: last)
        } else {
            editText(inRow: last)
        }
    }

    // MARK: Row types

    /// Format ▸ Row Type: the menu item's tag says which.
    @objc package func setRowType(_ sender: NSMenuItem) {
        perform("Change Row Type") { rows, selection in
            for index in selection {
                var row = rows[index]
                row.spacing = 1
                switch sender.tag {
                case 0: row.kind = .bullet; row.task = nil; row.marker = "-"
                case 1...6: row.kind = .heading(sender.tag); row.task = nil
                case 10: row.kind = .bullet; row.marker = "+"; row.task = row.task ?? .open
                case 14: row.kind = .bullet; row.marker = "-"; row.task = row.task ?? .open
                case 11: row.kind = .ordered; row.marker = "."; row.task = nil
                case 12: row.kind = .quote; row.task = nil
                case 13: row.kind = .paragraph; row.task = nil
                default: break
                }
                rows[index] = row
            }
            OutlineEditing.normalize(&rows)
            return selection
        }
    }

    /// Format ▸ Bullet: takes the bullets off the selected rows, leaving
    /// their text where it is — written, as Reflect writes it, as a paragraph
    /// in the item above — or, when some have none, puts bullets on those.
    @objc package func toggleBullet(_ sender: Any?) {
        perform("Bullet") { rows, selection in
            let on = rows[selection].allSatisfy(\.kind.isListItem)
            var changed = false
            for index in selection {
                var row = rows[index]
                if on {
                    row.kind = .paragraph
                    row.task = nil
                } else if row.kind == .paragraph {
                    row.kind = .bullet
                    row.marker = "-"
                    row.spacing = 1
                } else {
                    continue
                }
                rows[index] = row
                changed = true
            }
            guard changed else { return nil }
            OutlineEditing.normalize(&rows)
            return selection
        }
    }

    /// Format ▸ Horizontal Line: a line across after this row — or in
    /// place of it, when it is empty — and a new row after it, to write in.
    @objc package func insertHorizontalRule(_ sender: Any?) {
        if isSelectingRows, let rows = selectedRows { editText(inRow: rows.upperBound - 1) }
        let index = rowIndex(at: selectedRange().location)
        let row = row(at: index)
        let text = ruleText(ofRowAt: selectedRange().location)
        if text.isEmpty || Self.ruleMarks.contains(text) {
            makeRule(at: index)
        } else {
            // After the row and all under it.
            var after = rows
            let before = after
            let end = OutlineEditing.subtreeEnd(after, index)
            after.insert(Row(kind: .rule, depth: row.depth, text: "---"), at: end)
            after.insert(Row(kind: .bullet, depth: row.depth), at: end + 1)
            OutlineEditing.normalize(&after)
            replace(before, with: after, actionName: "Horizontal Line")
            restoreCaret(CaretPosition(row: end + 1, offset: 0))
        }
    }

    /// What typed alone on a row makes it a line across: Markdown's three
    /// marks, and the dash they become when smart dashes are on.
    package static let ruleMarks: Set<String> = ["---", "***", "___", "—", "—-", "–-"]

    /// A row's text, trimmed — the text, not its style, which has none.
    package func ruleText(ofRowAt location: Int) -> String {
        (string as NSString).substring(with: textRange(ofRowAt: location)).trimmingCharacters(in: .whitespaces)
    }

    /// Makes a row a line across, and puts the caret in a new row after it.
    package func makeRule(at index: Int) {
        var after = rows
        let before = after
        let row = after[index]
        let typed = row.text.trimmingCharacters(in: .whitespaces)
        var rule = Row(kind: .rule, depth: row.depth, text: ["---", "***", "___"].contains(typed) ? typed : "---")
        rule.gap = row.gap
        after[index] = rule
        after.insert(Row(kind: .bullet, depth: row.depth), at: index + 1)
        OutlineEditing.normalize(&after)
        replace(before, with: after, actionName: "Horizontal Line")
        restoreCaret(CaretPosition(row: index + 1, offset: 0))
    }

    // MARK: Code blocks

    /// Whether a line is a code fence: three backticks or tildes, and
    /// perhaps a language.
    package static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.range(of: #"^(```+|~~~+)[\w+#.-]*$"#, options: .regularExpression) != nil
    }

    /// Return on a code block's last, empty line, or on its closing fence:
    /// out of the block, into a new row after it. Says whether it left.
    package func leaveCodeBlock(at index: Int, offset: Int) -> Bool {
        var all = rows
        let before = all
        let row = all[index]
        var lines = row.text.components(separatedBy: "\n")
        guard lines.count >= 2, let last = lines.last, Self.isFence(last) else { return false }
        let line = (row.text as NSString).substring(to: min(offset, (row.text as NSString).length)).components(separatedBy: "\n").count - 1
        if line == lines.count - 2, lines[line].trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 2 {
            lines.remove(at: line)
        } else if line != lines.count - 1 {
            return false
        }
        all[index].text = lines.joined(separator: "\n")
        all.insert(Row(kind: .bullet, depth: row.depth), at: index + 1)
        OutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "New Row")
        restoreCaret(CaretPosition(row: index + 1, offset: 0))
        return true
    }

    /// A row that says only a fence — ```` ``` ````, perhaps with a
    /// language — then Return: a code block, the caret inside it.
    package func makeCodeBlock(at index: Int, fence: String) -> Bool {
        var all = rows
        let before = all
        let row = all[index]
        let opening = fence.trimmingCharacters(in: .whitespaces)
        let closing = String(opening.prefix(while: { $0 == "`" || $0 == "~" }))
        var code = Row(kind: .code, depth: row.depth, text: opening + "\n\n" + closing)
        code.gap = row.gap
        all[index] = code
        OutlineEditing.normalize(&all)
        replace(before, with: all, actionName: "Code Block")
        restoreCaret(CaretPosition(row: index, offset: (opening as NSString).length + 1))
        return true
    }

    /// Format ▸ Code Block: the rows chosen, their text, as one code block —
    /// or a code block back into rows, a line to a row.
    @objc package func toggleCodeBlock(_ sender: Any?) {
        perform("Code Block") { rows, selection in
            let first = rows[selection.lowerBound]
            if first.kind == .code {
                var lines = first.text.components(separatedBy: "\n")
                if let opening = lines.first, Self.isFence(opening) { lines.removeFirst() }
                if let closing = lines.last, Self.isFence(closing) { lines.removeLast() }
                if lines.isEmpty { lines = [""] }
                let unfolded = lines.map { Row(kind: .bullet, depth: first.depth, text: $0.trimmingCharacters(in: .whitespaces)) }
                rows.replaceSubrange(selection.lowerBound..<(selection.lowerBound + 1), with: unfolded)
                OutlineEditing.normalize(&rows)
                return selection.lowerBound..<(selection.lowerBound + unfolded.count)
            }
            // Each row's text, indented by its depth under the first.
            let base = first.depth
            let lines = rows[selection].map { String(repeating: "  ", count: max(0, $0.depth - base)) + $0.text }
            var code = Row(kind: .code, depth: base, text: "```\n" + lines.joined(separator: "\n") + "\n```")
            code.gap = first.gap
            rows.replaceSubrange(selection, with: [code])
            OutlineEditing.normalize(&rows)
            return selection.lowerBound..<(selection.lowerBound + 1)
        }
    }

    // MARK: Inline formatting

    @objc package func toggleBold(_ sender: Any?) { wrapSelection("**") }
    @objc package func toggleItalic(_ sender: Any?) { wrapSelection("*") }
    @objc package func toggleCode(_ sender: Any?) { wrapSelection("`") }
    @objc package func toggleStrikethrough(_ sender: Any?) { wrapSelection("~~") }
    @objc package func toggleHighlight(_ sender: Any?) { wrapSelection("==") }

    /// Puts Markdown around the selection, or takes it away when it is
    /// already there.
    private func wrapSelection(_ marker: String) {
        guard !isSelectingRows else { NSSound.beep(); return }
        let text = textStorage!.string as NSString
        let range = selectedRange()
        let length = (marker as NSString).length
        let selected = text.substring(with: range)
        if range.location >= length, NSMaxRange(range) + length <= text.length,
           text.substring(with: NSRange(location: range.location - length, length: length)) == marker,
           text.substring(with: NSRange(location: NSMaxRange(range), length: length)) == marker {
            let outer = NSRange(location: range.location - length, length: range.length + 2 * length)
            insertText(selected, replacementRange: outer)
            setSelectedRange(NSRange(location: outer.location, length: range.length))
            return
        }
        insertText(marker + selected + marker, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + length, length: range.length))
    }

    /// Format ▸ Link: in a link, edits where it goes, which is hidden;
    /// elsewhere, makes the selection a link, or puts one in.
    @objc package func addLink(_ sender: Any?) {
        guard !isSelectingRows, let storage = textStorage else { NSSound.beep(); return }
        let range = selectedRange()
        let text = storage.string as NSString
        let existing = spans(atRowOf: range.location).first { span in
            switch span.kind {
            case .link, .wikiLink:
                return range.location >= span.range.location && NSMaxRange(range) <= NSMaxRange(span.range)
            default:
                return false
            }
        }
        let anchor = firstRectOfSelection.insetBy(dx: -2, dy: 0)
        if let span = existing {
            let label = text.substring(with: span.content)
            switch span.kind {
            case .link(let target):
                LinkEditor.show(title: "Link", value: target, relativeTo: anchor, of: self) { [weak self] target in
                    self?.replaceSpan(span, with: "[\(label)](\(target))")
                }
            case .wikiLink(let title):
                LinkEditor.show(title: "Note", value: title, relativeTo: anchor, of: self) { [weak self] title in
                    // A link that shows its title shows the new one.
                    let labeled = text.substring(with: span.range).contains("|") && label != title
                    self?.replaceSpan(span, with: labeled ? "[[\(title)|\(label)]]" : "[[\(title)]]")
                }
            default:
                break
            }
            return
        }
        let selected = text.substring(with: range)
        LinkEditor.show(title: "Link", value: "", relativeTo: anchor, of: self) { [weak self] target in
            guard let self else { return }
            let markdown = selected.isEmpty ? "<\(target)>" : "[\(selected)](\(target))"
            self.insertText(markdown, replacementRange: range)
        }
    }

    private func replaceSpan(_ span: InlineSpan, with markdown: String) {
        insertText(markdown, replacementRange: span.range)
    }

    package override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(paste(_:)) where isEditable && carriesFiles(.general):
            // A picture alone on the clipboard can be pasted, though it is
            // not text.
            return true
        case #selector(focusIn(_:)):
            return !(focus != nil && rows.count == 1)
        case #selector(focusOut(_:)), #selector(unfocus(_:)):
            return focus != nil
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleCode(_:)),
             #selector(toggleStrikethrough(_:)), #selector(toggleHighlight(_:)), #selector(addLink(_:)):
            return isEditable && !isSelectingRows
        case #selector(indentRows(_:)), #selector(outdentRows(_:)), #selector(moveRowsUp(_:)),
             #selector(moveRowsDown(_:)), #selector(deleteRows(_:)), #selector(duplicateRows(_:)),
             #selector(toggleDone(_:)), #selector(newRow(_:)), #selector(setRowType(_:)), #selector(toggleBullet(_:)),
             #selector(insertHorizontalRule(_:)), #selector(toggleCodeBlock(_:)),
             #selector(cycleChecklist(_:)), #selector(cycleTask(_:)), #selector(newTimeBlock(_:)):
            return isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

// MARK: - Selection, as Bike widens it

extension OutlineTextView {
    /// Selection ▸ Expand Selection: the word, the sentence, the row's text,
    /// the row, its branch, its parent's branch, and so on out to every row.
    @objc package func expandSelection(_ sender: Any?) {
        let before = selectionSnapshot
        if let selectedRows {
            let all = rows
            let branch = OutlineEditing.block(all, selectedRows)
            if branch != selectedRows {
                selectRows(anchor: branch.lowerBound, head: branch.upperBound - 1)
            } else if let parent = parentIndex(of: selectedRows.lowerBound, in: all) {
                let parentBranch = OutlineEditing.block(all, parent..<(parent + 1))
                selectRows(anchor: parentBranch.lowerBound, head: parentBranch.upperBound - 1)
            } else if selectedRows.count < all.count {
                selectRows(anchor: 0, head: all.count - 1)
            } else {
                NSSound.beep()
                return
            }
        } else {
            let range = selectedRange()
            let index = rowIndex(at: range.location)
            let paragraph = paragraphRanges[index]
            let text = NSRange(location: paragraph.location, length: paragraph.length - 1)
            let string = textStorage!.string as NSString
            var next: NSRange?
            if range.length == 0 {
                let word = selectionRange(forProposedRange: range, granularity: .selectByWord)
                if word.length > 0, NSLocationInRange(word.location, text) { next = NSIntersectionRange(word, text) }
            }
            if next == nil {
                string.enumerateSubstrings(in: text, options: [.bySentences, .substringNotRequired]) { _, sentence, _, stop in
                    if NSIntersectionRange(sentence, range).length == range.length, sentence.location <= range.location,
                       NSMaxRange(sentence) >= NSMaxRange(range), sentence != range, sentence != text {
                        next = sentence
                        stop.pointee = true
                    }
                }
            }
            if next == nil && range != text && text.length > 0 { next = text }
            if let next {
                setSelectedRange(next)
            } else {
                selectRows(anchor: index, head: index)
            }
        }
        expansions.append(before)
        expandedTo = selectionSnapshot
    }

    /// Selection ▸ Contract Selection: back the way Expand came.
    @objc package func contractSelection(_ sender: Any?) {
        guard expandedTo == selectionSnapshot, let previous = expansions.popLast() else {
            expansions = []
            NSSound.beep()
            return
        }
        restore(previous)
        expandedTo = selectionSnapshot
    }

    /// Selection ▸ Select Paragraph: the row's text.
    package override func selectParagraph(_ sender: Any?) {
        let index = isSelectingRows ? rowHead : rowIndex(at: selectedRange().location)
        let paragraph = paragraphRanges[index]
        editText(inRow: index, atEnd: false)
        setSelectedRange(NSRange(location: paragraph.location, length: paragraph.length - 1))
    }

    /// Selection ▸ Select Branch: the row and everything in it, as rows.
    @objc package func selectBranch(_ sender: Any?) {
        let branch = OutlineEditing.block(rows, targetRows)
        selectRows(anchor: branch.lowerBound, head: branch.upperBound - 1)
    }

    private func parentIndex(of index: Int, in rows: [Row]) -> Int? {
        var candidate = index - 1
        while candidate >= 0 {
            if rows[candidate].depth < rows[index].depth { return candidate }
            candidate -= 1
        }
        return nil
    }
}

// MARK: - Pictures and files, pasted and dropped

extension OutlineTextView {
    /// A file on its way into the graph.
    package struct Incoming {
        package var data: Data
        /// The name on disk it asks for.
        package var name: String
        /// What a link to it says: the file's own name.
        package var title: String
        package var isImage: Bool
    }

    /// The files and pictures on a pasteboard: files copied or dragged from
    /// the Finder, or a picture on its own — a screenshot, an image copied
    /// from a page. Text wins over a picture that comes with it.
    /// Picture types a pasteboard can carry a picture's bytes as.
    package static let pictureTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), .pdf]

    /// Whether a pasteboard carries files or a picture, without reading them.
    package func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(where: Self.pictureTypes.contains)
            || types.contains(where: { NSFilePromiseReceiver.readableDraggedTypes.contains($0.rawValue) })
    }

    package func incoming(from pasteboard: NSPasteboard, textFirst: Bool = true) -> [Incoming] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.compactMap { url in
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue,
                      let data = try? Data(contentsOf: url) else { return nil }
                let type = UTType(filenameExtension: url.pathExtension)
                if let type, let ext = Assets.imageExtensions.first(where: { type.conforms(to: UTType($0.key) ?? .data) })?.value {
                    return Incoming(data: data, name: Assets.pastedName(extension: ext), title: url.lastPathComponent, isImage: true)
                }
                return Incoming(data: data, name: Assets.fileName(for: url.lastPathComponent), title: url.lastPathComponent, isImage: false)
            }
        }
        // Pasting, text that comes with a picture is what was meant; a drop
        // of a picture that carries its address along is the picture.
        if textFirst, let text = pasteboard.string(forType: .string), !text.isEmpty { return [] }
        // A document copied as itself — a PDF from Preview — with no file to name it.
        if let pdf = pasteboard.data(forType: .pdf) {
            let name = Assets.pastedName(extension: "pdf")
            return [Incoming(data: pdf, name: name, title: name, isImage: false)]
        }
        if let png = pasteboard.data(forType: .png) {
            return [Incoming(data: png, name: Assets.pastedName(extension: "png"), title: "", isImage: true)]
        }
        if let jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            return [Incoming(data: jpeg, name: Assets.pastedName(extension: "jpg"), title: "", isImage: true)]
        }
        if let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return [Incoming(data: png, name: Assets.pastedName(extension: "png"), title: "", isImage: true)]
        }
        return []
    }

    /// Saves files into the graph's `assets/`, and links them where the
    /// caret is: pictures as `![](…)`, anything else as `[name](…)`.
    package func add(_ files: [Incoming]) {
        guard let root = images?.root, isEditable else { NSSound.beep(); return }
        var markdown: [String] = []
        for file in files {
            do {
                let path = try Assets.add(file.data, named: file.name, to: root)
                Log.shared.info("files", "Added \(path)", detail: file.title.isEmpty ? nil : "from \(file.title)")
                if file.data.count > Assets.largeFileBytes {
                    Log.shared.warning("files", "“\(file.title.isEmpty ? path : file.title)” is \(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)). Git keeps every version forever; GitHub rejects files over 100 MB.")
                }
                if file.isImage {
                    markdown.append("![](\(path))")
                } else {
                    let title = file.title.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    markdown.append("[\(title)](\(path))")
                }
            } catch {
                Log.shared.error("files", "Could not add \(file.title.isEmpty ? file.name : file.title)", detail: error.localizedDescription)
                presentError(error)
            }
        }
        guard !markdown.isEmpty else { return }
        if isSelectingRows, let rows = selectedRows { editText(inRow: rows.upperBound - 1) }
        insertText(markdown.joined(separator: " "), replacementRange: selectedRange())
    }

    // A text view that takes only text refuses anything else before it is
    // asked: pictures and files are named here, on the pasteboard and in
    // drags, so that pasting and dropping them reach `add`.

    package override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL] + Self.pictureTypes
    }

    package override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL, Self.pictureType, Self.rowsType] + Self.pictureTypes
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    package override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if carriesRows(sender) { return rowDragUpdated(sender) }
        if carriesPicture(sender) { return pictureDragUpdated(sender) }
        let operation = super.draggingEntered(sender)
        return isEditable && carriesFiles(sender.draggingPasteboard) ? .copy : operation
    }

    package override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if carriesRows(sender) { return rowDragUpdated(sender) }
        if carriesPicture(sender) { return pictureDragUpdated(sender) }
        // The text view moves its drop caret along; the answer is ours.
        let operation = super.draggingUpdated(sender)
        return isEditable && carriesFiles(sender.draggingPasteboard) ? .copy : operation
    }

    package override func draggingExited(_ sender: NSDraggingInfo?) {
        pictureDragEnded()
        super.draggingExited(sender)
    }

    package override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if carriesRows(sender) || carriesPicture(sender) { return isEditable }
        return isEditable && carriesFiles(sender.draggingPasteboard) ? true : super.prepareForDragOperation(sender)
    }

    package override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if carriesRows(sender) { return dropRows(sender) }
        if carriesPicture(sender) { return dropPicture(sender) }
        let pasteboard = sender.draggingPasteboard
        guard isEditable, carriesFiles(pasteboard) else { return super.performDragOperation(sender) }
        window?.makeFirstResponder(self)
        let point = convert(sender.draggingLocation, from: nil)
        // Between words, and never inside a link or other Markdown.
        setSelectedRange(NSRange(location: snappedLocation(characterIndexForInsertion(at: point)), length: 0))
        let files = incoming(from: pasteboard, textFirst: false)
        if !files.isEmpty {
            add(files)
            return true
        }
        // Photos, Safari and Mail promise files and write them when asked.
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !promises.isEmpty else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let location = selectedRange()
        var received: [URL] = []
        let group = DispatchGroup()
        for promise in promises {
            group.enter()
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                if let error {
                    Log.shared.warning("files", "A dropped file did not arrive", detail: error.localizedDescription)
                } else {
                    received.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let board = NSPasteboard(name: NSPasteboard.Name("ReflectDrop-\(UUID().uuidString)"))
            board.clearContents()
            board.writeObjects(received as [NSURL])
            let files = self.incoming(from: board, textFirst: false)
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
            guard !files.isEmpty else { return }
            self.setSelectedRange(NSRange(location: min(location.location, self.textStorage!.length - 1), length: 0))
            self.add(files)
        }
        return true
    }
}
