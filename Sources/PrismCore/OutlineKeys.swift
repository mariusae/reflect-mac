import Foundation
import ReflectCore

/// What the keys do to an outline, whatever editor they are pressed in: the
/// rows before, and the rows after with where the caret goes. As the Mac's
/// editor has them, after Bike.
public enum OutlineKeys {
    /// Where the caret is: a row, and how far into its text.
    public struct Caret: Equatable, Sendable {
        public var row: Int
        public var offset: Int

        public init(row: Int, offset: Int) {
            self.row = row
            self.offset = offset
        }
    }

    // MARK: Return

    /// Return in a row: it is split there. At its start, with text after, a
    /// new row opens above and the text stays put. At the end of a row with
    /// children, the new row is its first child. A heading or a line across
    /// is followed by a plain row; a checkbox, by an open one; a number, by
    /// the next. In a code block, Return ends the block from its last line.
    public static func split(_ rows: [Row], at caret: Caret) -> (rows: [Row], caret: Caret)? {
        guard rows.indices.contains(caret.row) else { return nil }
        var all = rows
        let row = all[caret.row]
        let text = row.text as NSString
        let offset = min(max(caret.offset, 0), text.length)
        if row.kind == .code { return leaveCodeBlock(all, index: caret.row, offset: offset) }

        var next = row
        next.text = ""
        next.folded = []
        next.continuationIndents = nil
        // A list with blank lines between its items goes on the same way.
        let hasSiblingAbove = OutlineEditing.previousSibling(all, before: caret.row, depth: row.depth).map { all[$0].kind.isListItem } ?? false
        next.gap = !row.gap.isEmpty && hasSiblingAbove ? [""] : []
        if next.task != nil { next.task = .open }
        if next.kind == .ordered { next.number += 1 }
        switch next.kind {
        case .heading, .rule: next = Row(kind: .bullet, depth: row.depth, gap: [""])
        default: break
        }

        if offset == 0 && text.length > 0 {
            all.insert(next, at: caret.row)
            return (all, Caret(row: caret.row + 1, offset: 0))
        }
        all[caret.row].text = text.substring(to: offset)
        next.text = text.substring(from: offset)
        if offset == text.length, OutlineEditing.subtreeEnd(all, caret.row) > caret.row + 1 {
            let child = all[caret.row + 1]
            next.depth = child.depth
            if child.kind.isListItem && row.kind.isListItem {
                next.kind = child.kind
                next.marker = child.marker
                next.number = 1
                next.task = child.task == nil ? nil : .open
            }
            next.gap = child.gap
        }
        all.insert(next, at: caret.row + 1)
        return (all, Caret(row: caret.row + 1, offset: 0))
    }

    /// Return on a code block's last line, its fence: a row after the
    /// block, a blank line it ended on taken away.
    private static func leaveCodeBlock(_ rows: [Row], index: Int, offset: Int) -> (rows: [Row], caret: Caret)? {
        var all = rows
        let row = all[index]
        var lines = row.text.components(separatedBy: "\n")
        guard lines.count >= 2, let last = lines.last, isFence(last) else { return nil }
        let line = (row.text as NSString).substring(to: min(offset, (row.text as NSString).length)).components(separatedBy: "\n").count - 1
        if line == lines.count - 2, lines[line].trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 2 {
            lines.remove(at: line)
        } else if line != lines.count - 1 {
            return nil
        }
        all[index].text = lines.joined(separator: "\n")
        all.insert(Row(kind: .bullet, depth: row.depth), at: index + 1)
        OutlineEditing.normalize(&all)
        return (all, Caret(row: index + 1, offset: 0))
    }

    public static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    // MARK: Delete

    /// Delete at the start of a row of some type: it becomes a plain row
    /// first, as in Bike. Nil when it is one already: then the row joins
    /// the one before, as text does.
    public static func plain(_ rows: [Row], at index: Int) -> [Row]? {
        guard rows.indices.contains(index) else { return nil }
        var all = rows
        var row = all[index]
        guard row.task != nil || !(row.kind == .bullet || row.kind == .paragraph) else { return nil }
        if row.task != nil {
            row.task = nil
            row.marker = "-"
        } else {
            row.kind = .bullet
            row.marker = "-"
            row.spacing = 1
        }
        all[index] = row
        return all
    }

    // MARK: Typing

    /// Markdown typed at the start of a plain row, then a space, sets the
    /// row's type: `#` a heading, `>` a quote, `[]` a checklist item, `+` a
    /// task, `1.` a number. The typed marks go; the caret is at the row's
    /// start. Nil when what is typed is no such mark.
    public static func smartType(_ rows: [Row], at index: Int, typed prefix: String) -> [Row]? {
        guard rows.indices.contains(index) else { return nil }
        var all = rows
        var row = all[index]
        guard row.task == nil, row.kind == .bullet || row.kind == .paragraph, !prefix.isEmpty, prefix.count <= 6,
              row.text.hasPrefix(prefix) else { return nil }
        let rest = String(row.text.dropFirst(prefix.count))
        switch prefix {
        case _ where prefix.allSatisfy({ $0 == "#" }):
            row.kind = .heading(prefix.count)
        case ">":
            row.kind = .quote
        case "[]", "[ ]", "[x]", "[X]", "-[]", "-[ ]":
            row.kind = .bullet
            row.marker = row.marker == "*" ? "*" : "-"
            row.task = prefix.lowercased() == "[x]" ? .done(prefix.contains("X") ? "X" : "x") : .open
        case "+":
            row.kind = .bullet
            row.marker = "+"
            row.task = .open
        case _ where ["-", "*"].contains(prefix) && row.kind == .paragraph:
            row.kind = .bullet
            row.marker = prefix.first!
        default:
            let digits = prefix.dropLast()
            guard let delimiter = prefix.last, delimiter == "." || delimiter == ")",
                  !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) else { return nil }
            row.kind = .ordered
            row.marker = delimiter
            row.number = number
        }
        row.spacing = 1
        row.text = rest
        all[index] = row
        return all
    }

    // MARK: Checkboxes

    /// A checkbox ticked, or unticked: a task's or a checklist item's.
    public static func toggle(_ rows: [Row], at index: Int) -> [Row]? {
        guard rows.indices.contains(index), let task = rows[index].task else { return nil }
        var all = rows
        all[index].task = task.isDone ? .open : .done("x")
        return all
    }
}
