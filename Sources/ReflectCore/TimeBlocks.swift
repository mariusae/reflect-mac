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
        // A bare number is a count, not a time: one of them says which.
        guard start.colon || start.suffix != nil || end?.colon == true || end?.suffix != nil else { return nil }
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
        if let e = endMinutes, e <= startMinutes { endMinutes = e + 24 * 60 }
        var full = index
        while full < units.count, units[full] == 0x20 || units[full] == 0x09 { full += 1 }
        return TimeStamp(range: NSRange(location: 0, length: index), fullRange: NSRange(location: 0, length: full),
                         start: startMinutes, end: endMinutes, style: style)
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
            guard heads.count >= 2 else { return nil }
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
}
