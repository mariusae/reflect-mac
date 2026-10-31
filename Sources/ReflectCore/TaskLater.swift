import Foundation

/// When a task is put off to — a day of its own, the task moved into its
/// note: tomorrow, the weekend, next week.
public enum TaskLater: CaseIterable, Sendable {
    case tomorrow, weekend, nextWeek

    public var title: String {
        switch self {
        case .tomorrow: "Tomorrow"
        case .weekend: "This Weekend"
        case .nextWeek: "Next Week"
        }
    }

    public var symbol: String {
        switch self {
        case .tomorrow: "sunrise"
        case .weekend: "sofa"
        case .nextWeek: "calendar"
        }
    }

    /// Its day, from `today`: the weekend its Saturday — the next one, on a
    /// weekend already; next week its Monday.
    public func day(from today: Day, calendar: Calendar = .current) -> Day {
        guard let date = today.date else { return today.adding(1) }
        // 1 Sunday … 7 Saturday.
        let weekday = calendar.component(.weekday, from: date)
        switch self {
        case .tomorrow:
            return today.adding(1)
        case .weekend:
            // A weekday: the Saturday coming. A Saturday or a Sunday: the next one's.
            return today.adding(weekday == 7 ? 7 : weekday == 1 ? 6 : 7 - weekday)
        case .nextWeek:
            // The Monday coming; a Monday, the one after.
            return today.adding(weekday == 1 ? 1 : 9 - weekday)
        }
    }
}

extension Tasks {
    /// Tasks still open from the days before `today` — the last `days` of
    /// them — to carry into today: those due later left where they are.
    public static func carried(_ tasks: [NoteTask], today: Day, days: Int = 7) -> [NoteTask] {
        let first = today.adding(-days)
        return tasks.filter { task in
            guard !task.done, let day = task.day, day < today, day >= first else { return false }
            if let due = task.dueDate, due > today { return false }
            return true
        }.sorted { a, b in a.day! != b.day! ? a.day! > b.day! : a.ordinal < b.ordinal }
    }
}
