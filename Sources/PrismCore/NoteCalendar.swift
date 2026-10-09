import Foundation
import ReflectCore

/// A month, as a calendar shows it, and which of its days have a note —
/// and, for those with tasks or a checklist, how far along they are.
public enum NoteCalendar {
    /// A day with a note: its progress, when its note has checkboxes.
    public struct Mark: Equatable, Sendable {
        public var progress: Checkboxes.Progress?

        public init(progress: Checkboxes.Progress?) {
            self.progress = progress
        }
    }

    /// A month: its year and month, 1 to 12.
    public struct Month: Hashable, Sendable {
        public var year: Int
        public var month: Int

        public init(year: Int, month: Int) {
            self.year = year
            self.month = month
        }

        public init(_ day: Day) {
            self.init(year: day.year, month: day.month)
        }

        public func adding(_ months: Int) -> Month {
            let index = year * 12 + (month - 1) + months
            return Month(year: index / 12, month: index % 12 + 1)
        }

        /// `October 2026`.
        public func title(calendar: Calendar = .current) -> String {
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return "" }
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return formatter.string(from: date)
        }
    }

    /// The week a row of the calendar stands for: its Monday's, or its
    /// first day's when the row has no Monday in the month.
    public static func week(ofRow row: [Day?]) -> Week? {
        let days = row.compactMap { $0 }
        return (days.first { Week($0).monday == $0 } ?? days.first).map(Week.init)
    }

    /// The weeks with a note.
    public static func weeksWithNotes(index: NoteIndex) -> Set<Week> {
        Set(index.all.compactMap { GraphPaths.week(fromWeeklyPath: $0.path) })
    }

    /// The month's weeks, each seven days from the calendar's first weekday,
    /// nil before the first and after the last.
    public static func weeks(of month: Month, calendar: Calendar = .current) -> [[Day?]] {
        guard let first = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)),
              let count = calendar.range(of: .day, in: .month, for: first)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        var cells: [Day?] = Array(repeating: nil, count: lead)
        cells += (1...count).map { Day(year: month.year, month: month.month, day: $0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    /// The weekdays' short names, in the calendar's order: `M T W T F S S`.
    public static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    /// Every day with a note, from the graph's daily notes, its progress
    /// from the index's copy of its text.
    public static func marks(graph: Graph, index: NoteIndex) -> [Day: Mark] {
        var marks: [Day: Mark] = [:]
        for day in graph.dailyNoteFiles().keys {
            let text = index.body(GraphPaths.dailyPath(for: day)) ?? ""
            // A note left empty is no note.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count > 40 || !OutlineMarkdown.parse(text).isBlank else { continue }
            marks[day] = Mark(progress: Checkboxes.progress(in: text))
        }
        return marks
    }
}
