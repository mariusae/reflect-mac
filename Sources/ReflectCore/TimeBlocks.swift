import Foundation

/// A row that starts with a time, or a span of them: `9:00–10:30 Deep work`,
/// `11am Standup`, `14:00 to 15:30 Review`. A list whose every item starts
/// so is a timeline — time blocked, each item shown as long as it lasts.
public struct TimeStamp: Equatable, Sendable {
    /// The stamp in the row's text, in UTF-16 units: the times and what
    /// joins them, not the space after.
    public var range: NSRange
    /// The stamp and the spaces after it: what a row hides of itself.
    public var fullRange: NSRange
    /// Minutes from midnight.
    public var start: Int
    /// Minutes from midnight, past the start: an end before the start is
    /// the next day's.
    public var end: Int?
    /// How it was written, to write it again so.
    public var style: Style
    /// Written as bare numbers — `11-1` — which say a time only among
    /// times written plainly: alone, they could be a count.
    public var isBare = false

    public struct Style: Equatable, Sendable {
        /// `9am`, `9:30pm`: twelve hours, and the suffix's case.
        public var twelveHour = false
        public var upperSuffix = false
        /// `09:00` rather than `9:00`.
        public var padded = false
        /// What joins two times, spaces and all.
        public var separator = "–"

        public init() {}
    }

    /// How long it lasts, if it says.
    public var duration: Int? { end.map { $0 - start } }

    /// The stamp a row's text starts with, if it starts with one.
    public static func at(startOf text: String) -> TimeStamp? {
        let units = Array(text.utf16.prefix(40))
        var index = 0
        guard let first = time(units, &index) else { return nil }
        var style = Style()
        style.padded = first.padded
        var start = first
        var end: Clock?
        let afterFirst = index
        // A separator, then a second time; else the stamp is the first alone.
        var probe = index
        while probe < units.count, units[probe] == 0x20 { probe += 1 }
        var joined = false
        if probe < units.count, [0x2D, 0x2013, 0x2014].contains(units[probe]) {
            probe += 1
            joined = true
        } else if probe + 1 < units.count, units[probe] == 0x74, units[probe + 1] == 0x6F {
            // "to", a word of its own.
            probe += 2
            joined = probe < units.count && units[probe] == 0x20
        }
        if joined {
            let separatorStart = index
            while probe < units.count, units[probe] == 0x20 { probe += 1 }
            var second = probe
            if let clock = time(units, &second) {
                end = clock
                style.separator = String(utf16CodeUnits: Array(units[separatorStart..<probe]), count: probe - separatorStart)
                index = second
            }
        }
        if end == nil { index = afterFirst }
        // A bare number is a count, not a time; two joined — `11-1` — may be
        // times, if the list they are in says so.
        let isBare = !(start.colon || start.suffix != nil || end?.colon == true || end?.suffix != nil)
        guard !isBare || end != nil else { return nil }
        // What follows is the row's words, or nothing.
        if index < units.count, ![0x20, 0x09, 0x2C, 0x3A].contains(units[index]) { return nil }
        // `11–1pm`: the first takes the second's half of the day, or the other.
        if start.suffix == nil, let suffix = end?.suffix {
            start.suffix = suffix
            if start.minutes(twelveHour: true) > end!.minutes(twelveHour: true) { start.suffix = suffix == .am ? .pm : .am }
        }
        if end?.suffix == nil, let suffix = start.suffix, end != nil { end!.suffix = suffix }
        let twelve = start.suffix != nil
        style.twelveHour = twelve
        style.upperSuffix = start.upper || end?.upper == true
        guard start.isValid(twelveHour: twelve), end?.isValid(twelveHour: twelve) ?? true else { return nil }
        let startMinutes = start.minutes(twelveHour: twelve)
        var endMinutes = end.map { $0.minutes(twelveHour: twelve) }
        // `11-1`: past noon, as it is said; else an end before the start is the next day's.
        if let e = endMinutes, e <= startMinutes { endMinutes = !twelve && e + 12 * 60 > startMinutes && e < 12 * 60 ? e + 12 * 60 : e + 24 * 60 }
        var full = index
        // `10:00–11:00: hello`: the colon after the times goes with them.
        if full < units.count, units[full] == 0x3A || units[full] == 0x2C { full += 1 }
        while full < units.count, units[full] == 0x20 || units[full] == 0x09 { full += 1 }
        return TimeStamp(range: NSRange(location: 0, length: index), fullRange: NSRange(location: 0, length: full),
                         start: startMinutes, end: endMinutes, style: style, isBare: isBare)
    }

    private enum Suffix { case am, pm }

    private struct Clock {
        var hour: Int
        var minute: Int
        var colon: Bool
        var padded: Bool
        var suffix: Suffix?
        var upper = false

        func isValid(twelveHour: Bool) -> Bool {
            minute < 60 && (twelveHour ? (1...12).contains(hour) : hour < 24)
        }

        func minutes(twelveHour: Bool) -> Int {
            guard twelveHour, let suffix else { return hour * 60 + minute }
            return ((hour % 12) + (suffix == .pm ? 12 : 0)) * 60 + minute
        }
    }

    /// `9`, `09:30`, `9:30am`, `9 pm`: a time, read on from an index.
    private static func time(_ units: [UInt16], _ index: inout Int) -> Clock? {
        var i = index
        func digits(max: Int) -> (Int, Int)? {
            var value = 0, count = 0
            while i < units.count, count < max, (0x30...0x39).contains(units[i]) {
                value = value * 10 + Int(units[i] - 0x30)
                count += 1
                i += 1
            }
            return count == 0 ? nil : (value, count)
        }
        guard let (hour, hourDigits) = digits(max: 2) else { return nil }
        var clock = Clock(hour: hour, minute: 0, colon: false, padded: hourDigits == 2 && hour < 10, suffix: nil)
        if i < units.count, units[i] == 0x3A || units[i] == 0x2E {
            let mark = i
            i += 1
            if let (minute, count) = digits(max: 2), count == 2 {
                clock.minute = minute
                clock.colon = true
            } else {
                i = mark
            }
        }
        // am or pm, a space before it or not.
        var probe = i
        if probe < units.count, units[probe] == 0x20 { probe += 1 }
        if probe < units.count {
            let letter = units[probe] | 0x20
            if letter == 0x61 || letter == 0x70 {
                var end = probe + 1
                let upper = units[probe] < 0x60
                if end < units.count, units[end] | 0x20 == 0x6D { end += 1 }
                // Only as a word: "9 apples" is not nine in the morning.
                let isWord = end >= units.count || !(((units[end] | 0x20) >= 0x61 && (units[end] | 0x20) <= 0x7A))
                if isWord, end - probe == 2 || probe == i {
                    clock.suffix = letter == 0x61 ? .am : .pm
                    clock.upper = upper
                    i = end
                }
            }
        }
        index = i
        return clock
    }

    /// A time written as a stamp in this style.
    public static func write(_ minutes: Int, style: Style) -> String {
        let minutes = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        let hour = minutes / 60, minute = minutes % 60
        if style.twelveHour {
            let shown = hour % 12 == 0 ? 12 : hour % 12
            let suffix = hour < 12 ? "am" : "pm"
            let time = minute == 0 ? "\(shown)" : "\(shown):\(String(format: "%02d", minute))"
            return time + (style.upperSuffix ? suffix.uppercased() : suffix)
        }
        return (style.padded ? String(format: "%02d", hour) : "\(hour)") + ":" + String(format: "%02d", minute)
    }

    /// The stamp's text for a start and an end, in this stamp's style.
    public func written(start: Int, end: Int?) -> String {
        guard let end else { return Self.write(start, style: style) }
        return Self.write(start, style: style) + style.separator + Self.write(end, style: style)
    }

    /// Minutes as people say a length: `45m`, `1h`, `1h 30m`.
    public static func length(_ minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }

    /// A time as the clock shows it here: `9:30`, or `9:30 AM`.
    public static func shown(_ minutes: Int, twelveHour: Bool) -> String {
        let minutes = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        let hour = minutes / 60, minute = minutes % 60
        if twelveHour {
            let shown = hour % 12 == 0 ? 12 : hour % 12
            return (minute == 0 ? "\(shown)" : "\(shown):\(String(format: "%02d", minute))") + (hour < 12 ? " AM" : " PM")
        }
        return "\(hour):\(String(format: "%02d", minute))"
    }

    /// Two times, as the clock shows them: "9:30 – 10:15", or, in twelve
    /// hours, "9:30 – 10:15 AM", the half of the day once when they share it.
    public static func span(_ start: Int, _ end: Int, twelveHour: Bool) -> String {
        let from = shown(start, twelveHour: twelveHour), to = shown(end, twelveHour: twelveHour)
        guard twelveHour, from.suffix(3) == to.suffix(3) else { return from + " – " + to }
        return String(from.dropLast(3)) + " – " + to
    }

    /// Whether this Mac or phone shows the time in twelve hours.
    public static var localeIsTwelveHour: Bool {
        (DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }
}

/// A list of time blocks: the rows of an outline that are one, and how
/// long each lasts.
public struct Timeline: Equatable, Sendable {
    /// The row whose children the blocks are; nil for rows at the top of a note.
    public var parent: Int?
    public var blocks: [Block]

    public struct Block: Equatable, Sendable {
        /// The row that starts with the time.
        public var row: Int
        /// It and what is under it.
        public var rows: Range<Int>
        public var stamp: TimeStamp
        public var start: Int { stamp.start }
        /// When it ends: as written; else when the next starts; else half
        /// an hour on.
        public var end: Int
        /// When the next block starts, if after this one ends: the time
        /// between is free.
        public var next: Int?

        public var duration: Int { end - start }
        public var free: Int { next.map { max(0, $0 - end) } ?? 0 }
    }

    /// The timelines in an outline's rows: lists of two items or more, each
    /// starting with a time. An empty item is let be — it is one being
    /// written — and goes with the block before it.
    public static func find(depths: [Int], texts: [String], isListItem: [Bool]) -> [Timeline] {
        let count = depths.count
        var found: [Timeline] = []
        /// The children of a parent, from a row, at a depth: their indices,
        /// or nil when one is not a time block.
        func blocks(from first: Int, depth: Int, parent: Int?) -> Timeline? {
            var heads: [(Int, TimeStamp)] = []
            var i = first
            while i < count, depths[i] >= depth {
                if depths[i] == depth {
                    let text = texts[i]
                    if let stamp = TimeStamp.at(startOf: text), isListItem[i] {
                        heads.append((i, stamp))
                    } else if !(text.trimmingCharacters(in: .whitespaces).isEmpty && isListItem[i] && !heads.isEmpty) {
                        return nil
                    }
                }
                i += 1
            }
            // Bare numbers alone are a list of counts — `1-2 cups` — not times;
            // one block alone is one if it says when it ends.
            guard heads.contains(where: { !$0.1.isBare }),
                  heads.count >= 2 || heads.first?.1.end != nil else { return nil }
            var result: [Block] = []
            for (n, (row, stamp)) in heads.enumerated() {
                let rangeEnd = n + 1 < heads.count ? heads[n + 1].0 : i
                let nextStart = n + 1 < heads.count ? heads[n + 1].1.start : nil
                var end = stamp.end ?? stamp.start + 30
                if stamp.end == nil, let nextStart, nextStart > stamp.start { end = nextStart }
                result.append(Block(row: row, rows: row..<rangeEnd, stamp: stamp, end: end,
                                    next: nextStart.flatMap { $0 > end ? $0 : nil }))
            }
            return Timeline(parent: parent, blocks: result)
        }
        // At the top: every row at depth zero a block.
        if count > 0, depths[0] == 0, let top = blocks(from: 0, depth: 0, parent: nil) { found.append(top) }
        for parent in 0..<count where parent + 1 < count && depths[parent + 1] == depths[parent] + 1 && isListItem[parent] {
            if let timeline = blocks(from: parent + 1, depth: depths[parent] + 1, parent: parent) { found.append(timeline) }
        }
        return found
    }

    /// The row Return at the end of a block makes — a block with nothing
    /// under it — when it makes one: the next block, starting as this one
    /// ends, half an hour long, the caret after its time.
    public static func nextBlock(after index: Int, in rows: [Row]) -> Row? {
        guard let block = find(rows).lazy.compactMap({ $0.blocks.first { $0.row == index } }).first, block.rows.count == 1 else { return nil }
        let row = rows[index]
        var next = Row(kind: row.kind, depth: row.depth, task: row.task == nil ? nil : .open, marker: row.marker)
        if row.kind == .ordered { next.number = row.number + 1 }
        next.text = block.stamp.written(start: block.end, end: block.end + 30) + " "
        return next
    }

    /// A new time block, made at a row: from now — to the five minutes —
    /// for a quarter of an hour. The row itself, if empty; else among the
    /// blocks it is in, or beside the block it is, in order of time; else a
    /// new last child of it, making it a timeline. The rows after, the new
    /// one's index, and where the caret goes in it: after its time.
    public static func newBlock(in rows: [Row], at index: Int, now: Int) -> (rows: [Row], row: Int, offset: Int) {
        var rows = rows.isEmpty ? [.blank] : rows
        let index = min(max(index, 0), rows.count - 1)
        var start = now - now % 5
        let current = rows[index]
        let timelines = find(rows)
        let timeline = timelines.first { $0.blocks.contains { $0.rows.contains(index) } }
        // Not on top of a block: from the end of the one under way, and on.
        while let taken = timeline?.blocks.first(where: { $0.start <= start && start < $0.end }) { start = taken.end }
        // Written as the blocks around it are.
        let reference = timeline?.blocks.first { !$0.stamp.isBare }?.stamp ?? TimeStamp.at(startOf: current.text)
        var style = reference?.style ?? TimeStamp.Style()
        if reference?.isBare == true { style = TimeStamp.Style() }
        let model = TimeStamp(range: NSRange(), fullRange: NSRange(), start: start, end: start + 15, style: style)
        let text = model.written(start: start, end: start + 15) + " "
        func block(like row: Row?, depth: Int) -> Row {
            var new = Row(kind: .bullet, depth: depth, text: text, task: row?.task == nil ? nil : .open, marker: row?.marker ?? "-")
            if let row, row.kind.isListItem { new.kind = row.kind }
            return new
        }
        // An empty row: it becomes the block.
        if current.text.trimmingCharacters(in: .whitespaces).isEmpty, current.kind.isListItem || current.kind == .paragraph {
            if !current.kind.isListItem { rows[index].kind = .bullet }
            rows[index].text = text
            return (rows, index, (text as NSString).length)
        }
        // Among blocks, or beside one: before the first that starts later.
        var siblings: [(row: Int, rows: Range<Int>, start: Int)] = timeline?.blocks.map { ($0.row, $0.rows, $0.start) } ?? []
        if siblings.isEmpty, let stamp = TimeStamp.at(startOf: current.text), current.kind.isListItem {
            siblings = [(index, index..<OutlineEditing.subtreeEnd(rows, index), stamp.start)]
        }
        if let last = siblings.last {
            let like = rows[siblings.first { $0.rows.contains(index) }?.row ?? last.row]
            let at = siblings.first { $0.start > start }?.row ?? last.rows.upperBound
            rows.insert(block(like: like, depth: like.depth), at: at)
            return (rows, at, (text as NSString).length)
        }
        // Else under the row: its last child — or, a row that cannot hold
        // children, after it.
        let at = OutlineEditing.subtreeEnd(rows, index)
        rows.insert(block(like: nil, depth: current.canHaveChildren ? current.depth + 1 : current.depth), at: at)
        return (rows, at, (text as NSString).length)
    }

    public static func find(_ rows: [Row]) -> [Timeline] {
        find(depths: rows.map(\.depth), texts: rows.map(\.text), isListItem: rows.map(\.kind.isListItem))
    }

    /// Blocks moved: each from `index` on — or that one alone — by so many
    /// minutes, its start or its end; the texts of the rows to change.
    public func moved(_ index: Int, by minutes: Int, resizing: Bool, alone: Bool, texts: [String]) -> [Int: String] {
        var changed: [Int: String] = [:]
        for (n, block) in blocks.enumerated() where n == index || (n > index && !alone) {
            let stamp = block.stamp
            var start = block.start, end: Int? = stamp.end
            if n == index && resizing {
                end = max(block.start + 5, block.end + minutes)
            } else {
                start += minutes
                end = end.map { $0 + minutes }
                // A block whose end was the next one's start keeps its length.
                if end == nil, n == index, alone { end = block.end + minutes }
            }
            let text = texts[block.row] as NSString
            let rewritten = stamp.written(start: start, end: end)
            changed[block.row] = rewritten + text.substring(from: stamp.range.length)
        }
        return changed
    }

    /// Blocks moved — that one alone unless `following` — by so many
    /// minutes, its start or, resizing, its end; the texts of the rows to
    /// change.
    public func moved(_ index: Int, by minutes: Int, resizing: Bool, following: Bool, texts: [String]) -> [Int: String] {
        moved(index, by: minutes, resizing: resizing, alone: !following, texts: texts)
    }
}

/// How a timeline is drawn over its rows — D2: each block's bullet a node
/// on a line running down to the next block's, its time and length in a
/// small line over its words, free time a dashed stretch, and lengths and
/// gaps given a little more room the longer they are — but only a little,
/// so a long day stays short. What each row is to that drawing, worked out
/// here, the same for the Mac and the phone; each turns it into points.
public struct TimeMark: Equatable, Sendable {
    /// The row a block starts at.
    public struct Head: Equatable, Sendable {
        /// Which timeline, and which of its blocks.
        public var timeline: Int
        public var index: Int
        /// How deep the timeline is within others: nested blocks, inside a
        /// block of their own.
        public var level: Int
        public var stamp: TimeStamp
        /// Minutes from midnight: its end as written, or as the next begins.
        public var start: Int
        public var end: Int
        /// "9:00 – 10:30 · 1h 30m".
        public var label: String
        /// "overlaps Offsite 30m", when it starts before one ends; and,
        /// where that is too long, "30m overlap".
        public var overlap: String?
        public var overlapShort: String?
        /// The block's last row, and the next block's first, in rows.
        public var lastRow: Int
        public var nextRow: Int?
        public var done: Bool
    }

    /// A block ending at the row: the room after it.
    public struct Foot: Equatable, Sendable {
        public var timeline: Int
        public var index: Int
        public var level: Int
        /// Room for its length, in rows: none up to half an hour, then a
        /// little more each time it doubles.
        public var length: Double
        /// Free time after it, before the next: its minutes, its room in
        /// rows, and what it says.
        public var free: Int
        public var freeLength: Double
        public var freeLabel: String?
        /// Whether its timeline's last: room after it, where the line ends.
        public var isLast: Bool
    }

    public var head: Head?
    /// Innermost first: a nested timeline's last block ends where its
    /// block in the timeline around it does.
    public var feet: [Foot] = []

    /// Room for a length, in rows.
    public static func length(_ minutes: Int) -> Double {
        max(0, log2(Double(max(minutes, 1)) / 30)) * 0.25
    }

    /// Room for free time, in rows: a line to say it, and a little more for a long one.
    public static func freeLength(_ minutes: Int) -> Double {
        minutes <= 0 ? 0 : 0.8 + max(0, log2(Double(minutes) / 30)) * 0.3
    }

    /// The marks of an outline's rows, by row: the rows of its timelines.
    public static func marks(depths: [Int], texts: [String], isListItem: [Bool], done: [Bool],
                             twelveHour: Bool) -> [Int: TimeMark] {
        let timelines = Timeline.find(depths: depths, texts: texts, isListItem: isListItem)
        guard !timelines.isEmpty else { return [:] }
        // How deep each timeline is: one inside a block of another, deeper.
        var levels = [Int](repeating: 0, count: timelines.count)
        let order = timelines.indices.sorted { (timelines[$0].parent ?? -1) < (timelines[$1].parent ?? -1) }
        for t in order {
            guard let parent = timelines[t].parent else { continue }
            if let outer = order.first(where: { o in o != t && timelines[o].blocks.contains { $0.rows.contains(parent) } }) {
                levels[t] = levels[outer] + 1
            }
        }
        var marks: [Int: TimeMark] = [:]
        func title(_ block: Timeline.Block) -> String {
            let text = (texts[block.row] as NSString).substring(from: min(block.stamp.fullRange.length, (texts[block.row] as NSString).length))
            // Its first line, without the break that ends it.
            let words = (text.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}")).first ?? "").trimmingCharacters(in: .whitespaces)
            return words.count > 24 ? String(words.prefix(23)) + "…" : words
        }
        for (t, timeline) in timelines.enumerated() {
            let blocks = timeline.blocks
            for (n, block) in blocks.enumerated() {
                // Starting before an earlier one ends: overlapping it.
                var overlap: String?, overlapShort: String?
                if let earlier = blocks[..<n].max(by: { $0.end < $1.end }), earlier.end > block.start {
                    let minutes = min(earlier.end, block.end) - block.start
                    let name = title(earlier)
                    overlap = "overlaps " + (name.isEmpty ? "" : name + " ") + TimeStamp.length(minutes)
                    overlapShort = TimeStamp.length(minutes) + " overlap"
                }
                let label = TimeStamp.span(block.start, block.end, twelveHour: twelveHour) + " · " + TimeStamp.length(block.duration)
                let last = block.rows.upperBound - 1
                let next = n + 1 < blocks.count ? blocks[n + 1].row : nil
                marks[block.row, default: TimeMark()].head = Head(
                    timeline: t, index: n, level: levels[t], stamp: block.stamp, start: block.start, end: block.end,
                    label: label, overlap: overlap, overlapShort: overlapShort,
                    lastRow: last, nextRow: next, done: done[block.row])
                let free = block.free
                marks[last, default: TimeMark()].feet.append(Foot(
                    timeline: t, index: n, level: levels[t], length: length(block.duration),
                    free: free, freeLength: freeLength(free), freeLabel: free > 0 ? "\(TimeStamp.length(free)) free" : nil,
                    isLast: next == nil))
            }
        }
        for key in marks.keys { marks[key]?.feet.sort { $0.level > $1.level } }
        return marks
    }
}
