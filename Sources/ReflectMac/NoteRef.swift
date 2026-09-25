import ReflectCore

/// A note to show: a day's, or one under `notes/`.
enum NoteRef: Hashable {
    case day(Day)
    case note(String)

    /// From a graph-relative path.
    init(path: String) {
        if let day = GraphPaths.day(fromDailyPath: path) { self = .day(day) } else { self = .note(path) }
    }

    var path: String {
        switch self {
        case .day(let day): GraphPaths.dailyPath(for: day)
        case .note(let path): path
        }
    }

    var day: Day? {
        if case .day(let day) = self { day } else { nil }
    }

    /// What the app's saved state knows it by: a day by its date, as it
    /// always has been, any other note by its path.
    var stateKey: String { day?.description ?? path }
}
