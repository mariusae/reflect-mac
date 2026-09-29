import Foundation

/// A week, as a weekly note names it: `2026-W40` — an ISO week, Monday to
/// Sunday, numbered in the year its Thursday falls in.
///
/// Reflect keeps daily notes only; weekly ones live beside them, in
/// `weekly/`, and to Reflect are notes named by their week.
public struct Week: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let week: Int

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()

    public init?(year: Int, week: Int) {
        guard week >= 1, week <= 53 else { return nil }
        self.year = year
        self.week = week
        // A 53rd week only in the years that have one.
        guard let monday, Week(monday) == self else { return nil }
    }

    /// The week a day falls in.
    public init(_ day: Day) {
        let noon = Self.calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        let parts = Self.calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: noon)
        year = parts.yearForWeekOfYear!
        week = parts.weekOfYear!
    }

    /// A week from its ISO form, `2026-W40` (the `W` in either case).
    public init?(_ text: some StringProtocol) {
        let text = String(text)
        guard text.count == 8, let year = Int(text.prefix(4)), text.dropFirst(4).prefix(2).uppercased() == "-W",
              let week = Int(text.suffix(2)), text.suffix(2).allSatisfy(\.isNumber) else { return nil }
        self.init(year: year, week: week)
    }

    public static var current: Week { Week(.today) }

    /// Its Monday, and its Sunday.
    public var monday: Day? {
        let parts = DateComponents(hour: 12, weekday: 2, weekOfYear: week, yearForWeekOfYear: year)
        return Self.calendar.date(from: parts).map { Day($0, calendar: Self.calendar) }
    }

    public var sunday: Day? { monday?.adding(6) }

    public var days: [Day] { monday.map { first in (0..<7).map(first.adding) } ?? [] }

    public func adding(_ weeks: Int) -> Week {
        guard let monday else { return self }
        return Week(monday.adding(7 * weeks))
    }

    public var description: String { String(format: "%04d-W%02d", year, week) }

    /// "Week 40, 2026".
    public var title: String { "Week \(week), \(year)" }

    public static func < (lhs: Week, rhs: Week) -> Bool { (lhs.year, lhs.week) < (rhs.year, rhs.week) }
}

extension GraphPaths {
    public static let weeklyDirectory = "weekly"

    /// `weekly/2026-W40.md`.
    public static func weeklyPath(for week: Week) -> String {
        "\(weeklyDirectory)/\(week).md"
    }

    /// The week a graph-relative path names, when it is a weekly note.
    public static func week(fromWeeklyPath path: String) -> Week? {
        guard path.hasPrefix(weeklyDirectory + "/"), path.hasSuffix(".md") else { return nil }
        return Week(path.dropFirst(weeklyDirectory.count + 1).dropLast(3))
    }
}
