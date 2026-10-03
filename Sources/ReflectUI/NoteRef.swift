import ReflectCore

/// A note to show: a day's, or one under `notes/`.
package enum NoteRef: Hashable {
    case day(Day)
    case note(String)

    /// From a graph-relative path.
    package init(path: String) {
        if let day = GraphPaths.day(fromDailyPath: path) { self = .day(day) } else { self = .note(path) }
    }

    package var path: String {
        switch self {
        case .day(let day): GraphPaths.dailyPath(for: day)
        case .note(let path): path
        }
    }

    package var day: Day? {
        if case .day(let day) = self { day } else { nil }
    }

    /// What the app's saved state knows it by: a day by its date, as it
    /// always has been, any other note by its path.
    package var stateKey: String { day?.description ?? path }
}

import Foundation

extension URL {
    /// The title a `reflect-note:` link names — what `[[title]]` says.
    ///
    /// Read from the whole address: such a link has no path in the web's
    /// sense, and once it has been through AppKit, as `NSURL`, its `path`
    /// is empty.
    package var wikiTarget: String? {
        guard scheme == "reflect-note" else { return nil }
        let rest = absoluteString.dropFirst("reflect-note:".count)
        let title = (String(rest).removingPercentEncoding ?? String(rest)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// A `reflect-note:` link to a title.
    package static func wiki(_ title: String) -> URL? {
        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/?#")))
        return encoded.flatMap { URL(string: "reflect-note:" + $0) }
    }
}
