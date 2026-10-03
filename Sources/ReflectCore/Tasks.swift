import Foundation

/// Reflect's Tasks: the round checkboxes — `+ [ ]` — gathered from every note,
/// and grouped as its Tasks view groups them (V1's task view, as the open app
/// ports it in `group-tasks.ts`): **Current**, **Overdue**, **Upcoming**, then a
/// group for each note whose tasks have no date.
///
/// A task's date is its own due date — the first `[[YYYY-MM-DD]]` in it —
/// else its daily note's. Only a due date passed makes a task overdue: one
/// left in a past day's note is still current.
public struct NoteTask: Sendable, Equatable {
    public var notePath: String
    /// Which task of its note it is, counting in the order they are written.
    public var ordinal: Int
    public var text: String
    public var done: Bool
    /// The text of the list items it is under, outermost first.
    public var breadcrumbs: [String]
    public var dueDate: Day?
    public var day: Day?
    public var noteTitle: String
    public var pin: NoteEntry.Pin?
    public var modified: Date

    var date: Day? { dueDate ?? day }
}

public struct TaskGroup: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case current, overdue, upcoming, note }
    public var kind: Kind
    public var label: String
    /// The note a note group is of.
    public var notePath: String?
    public var tasks: [NoteTask]
}

public enum Tasks {
    /// The tasks in a note's text, open and done, in the order written.
    public static func tasks(in source: String, path: String, entry: NoteEntry) -> [NoteTask] {
        guard source.contains("+ [") else { return [] }
        let rows = OutlineMarkdown.parse(source).rows
        var found: [NoteTask] = []
        var ordinal = 0
        var ancestors: [(depth: Int, text: String)] = []
        for row in rows {
            while let last = ancestors.last, last.depth >= row.depth { ancestors.removeLast() }
            if isTask(row) {
                found.append(NoteTask(notePath: path, ordinal: ordinal, text: row.text, done: row.task?.isDone == true,
                                      breadcrumbs: ancestors.map(\.text), dueDate: dueDate(in: row.text), day: entry.day,
                                      noteTitle: entry.title, pin: entry.pin, modified: entry.modified))
                ordinal += 1
            }
            if row.kind.isListItem { ancestors.append((row.depth, InlineMarkup.plainText(row.text))) }
        }
        return found
    }

    /// Whether a row is one of Reflect's tasks: a `+ [ ]` item.
    public static func isTask(_ row: Row) -> Bool { row.task != nil && row.kind == .bullet && row.marker == "+" }

    /// The first `[[YYYY-MM-DD]]` in a task's text: when it is due.
    static func dueDate(in text: String) -> Day? {
        guard text.contains("[[") else { return nil }
        let ns = text as NSString
        for span in InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length)) {
            if case .wikiLink(let target) = span.kind, let day = Day(target.trimmingCharacters(in: .whitespaces)) { return day }
        }
        return nil
    }

    /// Breadcrumbs as shown: trimmed, and a lone "Tasks" or "Todo" parent left out.
    public static func visibleBreadcrumbs(_ breadcrumbs: [String]) -> [String] {
        let visible = breadcrumbs.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard visible.count == 1 else { return visible }
        let bare = visible[0].filter { $0.isLetter }.lowercased()
        return ["task", "tasks", "todo", "todos"].contains(bare) ? [] : visible
    }

    /// Groups tasks as Reflect's Tasks view does, empty groups left out.
    public static func group(_ tasks: [NoteTask], today: Day) -> [TaskGroup] {
        var current: [NoteTask] = [], overdue: [NoteTask] = [], upcoming: [NoteTask] = []
        var byNote: [String: [NoteTask]] = [:]
        for task in tasks {
            guard let date = task.date else {
                byNote[task.notePath, default: []].append(task)
                continue
            }
            if let due = task.dueDate, due < today {
                overdue.append(task)
            } else if date > today {
                upcoming.append(task)
            } else {
                current.append(task)
            }
        }
        func dated(_ a: NoteTask, _ b: NoteTask) -> Bool {
            if a.date != b.date { return a.date! < b.date! }
            if a.notePath != b.notePath { return a.notePath < b.notePath }
            return a.ordinal < b.ordinal
        }
        var groups: [TaskGroup] = []
        for (kind, label, list) in [(TaskGroup.Kind.current, "Current", current), (.overdue, "Overdue", overdue),
                                    (.upcoming, "Upcoming", upcoming)] where !list.isEmpty {
            groups.append(TaskGroup(kind: kind, label: label, notePath: nil, tasks: list.sorted(by: dated)))
        }
        let notes = byNote.values.map { list in
            TaskGroup(kind: .note, label: list[0].noteTitle, notePath: list[0].notePath, tasks: list.sorted { $0.ordinal < $1.ordinal })
        }.sorted { a, b in
            let x = a.tasks[0], y = b.tasks[0]
            // Pinned notes first, by their order; then the most lately edited.
            switch (x.pin, y.pin) {
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            case let (p?, q?) where p != q: return p < q
            default: break
            }
            if x.modified != y.modified { return x.modified > y.modified }
            return x.notePath < y.notePath
        }
        return groups + notes
    }

    /// A note's text with one of its tasks ticked, or unticked.
    public static func setting(done: Bool, ordinal: Int, in source: String) -> String? {
        var outline = OutlineMarkdown.parse(source)
        var seen = 0
        for index in outline.rows.indices where isTask(outline.rows[index]) {
            if seen == ordinal {
                outline.rows[index].task = done ? .done("x") : .open
                return OutlineMarkdown.serialize(outline)
            }
            seen += 1
        }
        return nil
    }
}

extension NoteIndex {
    /// Every task in the graph — open ones, and done ones when asked — from
    /// the notes as last read. Templates hold none.
    public func tasks(includingDone: Bool = false) -> [NoteTask] {
        all.filter { !$0.path.hasPrefix("templates/") }.flatMap { entry -> [NoteTask] in
            guard let text = body(entry.path) else { return [] }
            return Tasks.tasks(in: text, path: entry.path, entry: entry).filter { includingDone || !$0.done }
        }
    }
}

/// Checkboxes — tasks and checklist items — counted as progress: the done
/// among them, and all.
public enum Checkboxes {
    public struct Progress: Equatable, Sendable {
        public var done: Int
        public var total: Int
        public var isEmpty: Bool { total == 0 }
        public var share: Double { total == 0 ? 0 : Double(done) / Double(total) }

        public init(done: Int = 0, total: Int = 0) {
            self.done = done
            self.total = total
        }
    }

    /// Those in some rows, and in what is folded in them.
    public static func progress(of rows: [Row]) -> Progress {
        var progress = Progress()
        for row in Row.unfold(rows) where row.task != nil {
            progress.total += 1
            if row.task?.isDone == true { progress.done += 1 }
        }
        return progress
    }

    /// A note's, from its text; nil for one with none, found without
    /// reading the rest of it.
    public static func progress(in source: String) -> Progress? {
        guard source.contains("[ ]") || source.contains("[x]") || source.contains("[X]") else { return nil }
        let progress = progress(of: OutlineMarkdown.parse(source).rows)
        return progress.isEmpty ? nil : progress
    }

    /// For each row, those under it — its children, theirs, and what is
    /// folded in any of them — in one pass.
    public static func underEach(_ rows: [Row]) -> [Progress] {
        var under = [Progress](repeating: Progress(), count: rows.count)
        var open: [Int] = []
        for (index, row) in rows.enumerated() {
            while let last = open.last, rows[last].depth >= row.depth { open.removeLast() }
            let own = progress(of: row.folded)
            if row.task != nil {
                // The row's own box counts for those above it, not itself.
                let box = Progress(done: row.task?.isDone == true ? 1 : 0, total: 1)
                for ancestor in open {
                    under[ancestor].done += box.done
                    under[ancestor].total += box.total
                }
            }
            under[index].done += own.done
            under[index].total += own.total
            for ancestor in open {
                under[ancestor].done += own.done
                under[ancestor].total += own.total
            }
            open.append(index)
        }
        return under
    }
}

