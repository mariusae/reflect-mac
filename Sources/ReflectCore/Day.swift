import Foundation

/// A calendar day, as a daily note names it: `2026-09-25`.
///
/// Days are civil dates with no time zone; which one is today is the local
/// calendar's business, answered by `Day.today`.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// A day from its ISO form, or nil when the text is not a real date.
    public init?(_ text: some StringProtocol) {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = Int(text.prefix(4)), let month = Int(text.dropFirst(5).prefix(2)),
              let day = Int(text.suffix(2)),
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) })
        else { return nil }
        self.init(year: year, month: month, day: day)
        guard let date, Day(date) == self else { return nil }
    }

    /// The day a moment falls on, in the local calendar.
    public init(_ date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    public static var today: Day { Day(Date()) }

    /// Local midnight at the start of the day.
    public var date: Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The day `count` days later (earlier, when negative).
    public func adding(_ count: Int) -> Day {
        // Noon keeps a daylight saving change from landing on the wrong day.
        let calendar = Calendar.current
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Day(calendar.date(byAdding: .day, value: count, to: noon)!)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

/// Where things live in a graph.
public enum GraphPaths {
    public static let dailyDirectory = "daily"
    public static let notesDirectory = "notes"

    /// `daily/2026-09-25.md`.
    public static func dailyPath(for day: Day) -> String {
        "\(dailyDirectory)/\(day).md"
    }

    /// The day a graph-relative path names, when it is a daily note.
    public static func day(fromDailyPath path: String) -> Day? {
        guard path.hasPrefix(dailyDirectory + "/"), path.hasSuffix(".md") else { return nil }
        return Day(path.dropFirst(dailyDirectory.count + 1).dropLast(3))
    }
}
