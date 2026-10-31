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
    /// Tasks for today from elsewhere: those still open from the days
    /// before — the last `days` of them, those due later left where they
    /// are — and any note's due today or before. The latest days first,
    /// then the notes.
    public static func carried(_ tasks: [NoteTask], today: Day, days: Int = 7) -> [NoteTask] {
        let first = today.adding(-days)
        return tasks.filter { task in
            guard !task.done, task.day != today else { return false }
            if let due = task.dueDate { return due <= today && (task.day.map { $0 < today } ?? true) }
            guard let day = task.day else { return false }
            return day < today && day >= first
        }.sorted { a, b in
            switch (a.day, b.day) {
            case let (x?, y?) where x != y: return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.notePath != b.notePath ? a.notePath < b.notePath : a.ordinal < b.ordinal
            }
        }
    }

    /// Carried tasks by the note each is in: the latest days first, then
    /// other notes, by name.
    public static func byNote(_ carried: [NoteTask]) -> [(path: String, tasks: [NoteTask])] {
        Dictionary(grouping: carried, by: \.notePath).sorted { a, b in
            switch (GraphPaths.day(fromDailyPath: a.key), GraphPaths.day(fromDailyPath: b.key)) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.key < b.key
            }
        }.map { ($0.key, $0.value) }
    }
}
