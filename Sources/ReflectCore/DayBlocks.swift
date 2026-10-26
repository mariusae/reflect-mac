import Foundation

/// A day's time blocks, as its note holds them: the items under a bullet
/// called "Timeblocks", each starting with its time —
///
///     - Timeblocks
///       - 1-2pm do the first task
///       - 2pm-2:30pm do the second one
///         - [ ] Subtask 1
///       - 4-5pm wind down
///
/// — read, and changed, as the week's time blocker shows and moves them:
/// each change made to the note's text, the rest of it left as it was.
public struct DayBlock: Equatable, Sendable {
    /// The row that starts with the time.
    public var row: Int
    /// Minutes from midnight.
    public var start: Int
    public var end: Int
    /// What it says, after its time, as written.
    public var title: String
    /// A checkbox on the block itself: a block to tick off.
    public var task: Row.Task?
    /// The rows right under it: its checklist, or notes.
    public var items: [Item]

    public struct Item: Equatable, Sendable {
        public var row: Int
        public var text: String
        public var task: Row.Task?
    }

    public var duration: Int { end - start }

    public init(row: Int, start: Int, end: Int, title: String, task: Row.Task?, items: [Item]) {
        self.row = row
        self.start = start
        self.end = end
        self.title = title
        self.task = task
        self.items = items
    }
}

public enum DayBlocks {
    /// The bullet's name, as a new one is written.
    public static let heading = "Timeblocks"

    /// Whether a row is the bullet the blocks are under: "Timeblocks", or
    /// "Time blocks", in any case.
    static func isContainer(_ row: Row) -> Bool {
        guard row.kind.isListItem || { if case .heading = row.kind { true } else { false } }() else { return false }
        return InlineMarkup.plainText(row.text).lowercased().filter(\.isLetter) == "timeblocks"
    }

    /// Where the bullet is among the rows, if there is one.
    public static func container(in rows: [Row]) -> Int? { rows.firstIndex(where: isContainer) }

    /// The index past a row and everything under it.
    static func subtreeEnd(_ rows: [Row], _ index: Int) -> Int {
        var end = index + 1
        while end < rows.count, rows[end].depth > rows[index].depth { end += 1 }
        return end
    }

    /// The blocks a note's text holds, in order of time.
    public static func blocks(in source: String) -> [DayBlock] {
        blocks(in: OutlineMarkdown.parse(source).rows)
    }

    public static func blocks(in rows: [Row]) -> [DayBlock] {
        guard let container = container(in: rows) else { return [] }
        let depth = rows[container].depth + 1
        let end = subtreeEnd(rows, container)
        var found: [(row: Int, stamp: TimeStamp, end: Int)] = []
        var index = container + 1
        while index < end {
            let next = subtreeEnd(rows, index)
            if rows[index].depth == depth, let stamp = TimeStamp.at(startOf: rows[index].text) {
                found.append((index, stamp, next))
            }
            index = next
        }
        let starts = found.map(\.stamp.start).sorted()
        return found.map { item in
            let start = item.stamp.start
            // Its end as written; else when the next starts; else half an hour on.
            let later = starts.first { $0 > start }
            let end = min(24 * 60, item.stamp.end ?? later ?? start + 30)
            let text = rows[item.row].text as NSString
            let title = text.substring(from: min(text.length, NSMaxRange(item.stamp.fullRange)))
            var items: [DayBlock.Item] = []
            var child = item.row + 1
            while child < item.end {
                if rows[child].depth == depth + 1 { items.append(DayBlock.Item(row: child, text: rows[child].text, task: rows[child].task)) }
                child += 1
            }
            return DayBlock(row: item.row, start: start, end: max(end, start + 5), title: title, task: rows[item.row].task, items: items)
        }.sorted { $0.start < $1.start }
    }

    // MARK: Changes

    /// How a new stamp is written: as the day's blocks are, else as this
    /// computer tells the time.
    static func style(_ rows: [Row]) -> TimeStamp.Style {
        if let existing = blocks(in: rows).lazy.compactMap({ TimeStamp.at(startOf: rows[$0.row].text) }).first(where: { !$0.isBare }) {
            return existing.style
        }
        var style = TimeStamp.Style()
        style.twelveHour = TimeStamp.localeIsTwelveHour
        return style
    }

    static func stamp(_ start: Int, _ end: Int, style: TimeStamp.Style) -> String {
        TimeStamp.write(start, style: style) + style.separator + TimeStamp.write(end, style: style)
    }

    /// The bullet, made at the note's end if it has none — in place of the
    /// empty bullet an untouched day is.
    static func ensureContainer(_ outline: inout Outline) -> Int {
        if let index = container(in: outline.rows) { return index }
        let row = Row(kind: .bullet, depth: 0, text: heading)
        if outline.rows.count == 1, outline.rows[0].kind.isListItem, outline.rows[0].text.trimmingCharacters(in: .whitespaces).isEmpty,
           outline.rows[0].task == nil {
            outline.rows[0] = row
            return 0
        }
        outline.rows.append(row)
        return outline.rows.count - 1
    }

    /// Rows put under the bullet as a block, among the others in order of
    /// its start: the first the block, the rest under it, their depths as
    /// they were, from the first's.
    static func insert(_ subtree: [Row], start: Int, into outline: inout Outline) {
        guard !subtree.isEmpty else { return }
        let container = ensureContainer(&outline)
        let depth = outline.rows[container].depth + 1
        let base = subtree[0].depth
        let placed = subtree.enumerated().map { i, row -> Row in
            var row = row
            row.depth = depth + max(0, row.depth - base)
            row.extraIndent = 0
            if i == 0 { row.gap = [] }
            if !row.kind.isListItem, i == 0 { row.kind = .bullet }
            return row
        }
        let end = subtreeEnd(outline.rows, container)
        var at = end
        var index = container + 1
        while index < end {
            if outline.rows[index].depth == depth, let stamp = TimeStamp.at(startOf: outline.rows[index].text), stamp.start > start {
                at = index
                break
            }
            index = subtreeEnd(outline.rows, index)
        }
        outline.rows.insert(contentsOf: placed, at: at)
    }

    /// A row's text with its time — the one it starts with, if any — set.
    static func retimed(_ text: String, start: Int, end: Int, style: TimeStamp.Style) -> String {
        let written = stamp(start, end, style: style)
        guard let old = TimeStamp.at(startOf: text) else { return text.isEmpty ? written : written + " " + text }
        let rest = (text as NSString).substring(from: NSMaxRange(old.fullRange))
        // Written as it was, if it was not bare.
        let kept = old.isBare ? written : old.written(start: start, end: end)
        return rest.isEmpty ? kept : kept + " " + rest
    }

    /// A new block: its time, what it says, and — a block to tick off — a checkbox.
    public static func adding(start: Int, end: Int, title: String, checklist: Bool = false, to source: String) -> String {
        var outline = OutlineMarkdown.parse(source)
        let text = stamp(start, end, style: style(outline.rows)) + (title.isEmpty ? "" : " " + title)
        insert([Row(kind: .bullet, text: text, task: checklist ? .open : nil)], start: start, into: &outline)
        return OutlineMarkdown.serialize(outline)
    }

    /// A row and what is under it, taken out: the text after, and the rows.
    public static func removing(row: Int, from source: String) -> (source: String, subtree: [Row])? {
        var outline = OutlineMarkdown.parse(source)
        guard outline.rows.indices.contains(row) else { return nil }
        let end = subtreeEnd(outline.rows, row)
        let subtree = Array(outline.rows[row..<end])
        outline.rows.removeSubrange(row..<end)
        if outline.rows.isEmpty { outline.rows = [.blank] }
        return (OutlineMarkdown.serialize(outline), subtree)
    }

    /// Rows put into the day as a block at a time: the first's time set, or
    /// put before what it says.
    public static func inserting(_ subtree: [Row], start: Int, end: Int, into source: String) -> String {
        var outline = OutlineMarkdown.parse(source)
        guard var first = subtree.first else { return source }
        first.text = retimed(first.text, start: start, end: end, style: style(outline.rows))
        insert([first] + subtree.dropFirst(), start: start, into: &outline)
        return OutlineMarkdown.serialize(outline)
    }

    /// A block given another time, the same day: put among the others again.
    public static func retiming(row: Int, start: Int, end: Int, in source: String) -> String {
        guard let (rest, subtree) = removing(row: row, from: source) else { return source }
        return inserting(subtree, start: start, end: end, into: rest)
    }

    /// A row's text set, its time kept: what a block says, or an item's words.
    public static func settingTitle(row: Int, to title: String, in source: String) -> String {
        var outline = OutlineMarkdown.parse(source)
        guard outline.rows.indices.contains(row) else { return source }
        let text = outline.rows[row].text
        if let stamp = TimeStamp.at(startOf: text) {
            let kept = (text as NSString).substring(to: NSMaxRange(stamp.range))
            outline.rows[row].text = title.isEmpty ? kept : kept + " " + title
        } else {
            outline.rows[row].text = title
        }
        return OutlineMarkdown.serialize(outline)
    }

    /// A row's checkbox ticked, or unticked; a row without one, given one, or not.
    public static func settingTask(row: Int, to task: Row.Task?, in source: String) -> String {
        var outline = OutlineMarkdown.parse(source)
        guard outline.rows.indices.contains(row) else { return source }
        outline.rows[row].task = task
        return OutlineMarkdown.serialize(outline)
    }

    /// An item put last under a block: a checkbox, to tick off.
    public static func addingItem(_ text: String, under row: Int, in source: String) -> String {
        var outline = OutlineMarkdown.parse(source)
        guard outline.rows.indices.contains(row) else { return source }
        let end = subtreeEnd(outline.rows, row)
        outline.rows.insert(Row(kind: .bullet, depth: outline.rows[row].depth + 1, text: text, task: .open), at: end)
        return OutlineMarkdown.serialize(outline)
    }

    /// One of Reflect's tasks — the `ordinal`th `+ [ ]` of its note — taken
    /// out with what is under it: the note's text after, and the rows.
    public static func takingTask(ordinal: Int, from source: String) -> (source: String, subtree: [Row])? {
        let rows = OutlineMarkdown.parse(source).rows
        var seen = 0
        for index in rows.indices where Tasks.isTask(rows[index]) {
            if seen == ordinal { return removing(row: index, from: source) }
            seen += 1
        }
        return nil
    }

    /// Which of a note's tasks — counted as `takingTask` counts them — are
    /// its blocks: put on the day already.
    public static func blockedTasks(in source: String) -> Set<Int> {
        let rows = OutlineMarkdown.parse(source).rows
        let blocked = Set(blocks(in: rows).map(\.row))
        var found: Set<Int> = [], seen = 0
        for index in rows.indices where Tasks.isTask(rows[index]) {
            if blocked.contains(index) { found.insert(seen) }
            seen += 1
        }
        return found
    }
}
