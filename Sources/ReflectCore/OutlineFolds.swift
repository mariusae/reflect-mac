import Foundation

/// Which rows of a note are folded, kept apart from the note: folding is
/// how a note is shown on one device, not what it says, so it goes in
/// neither the Markdown nor the repository.
///
/// A folded row is remembered by where it is among all the note's rows,
/// folded ones included, and by its text. Put back on a note that has
/// changed since — on another device, say — a fold goes to the row with
/// that text nearest where it was, and is dropped when there is none.
public enum OutlineFolds {
    public struct Mark: Codable, Equatable, Sendable {
        /// The row's place among all the note's rows, as written.
        public var index: Int
        public var text: String

        public init(index: Int, text: String) {
            self.index = index
            self.text = text
        }
    }

    /// The folds in rows as they stand on screen.
    public static func marks(_ rows: [Row]) -> [Mark] {
        var marks: [Mark] = []
        var index = 0
        func walk(_ rows: [Row]) {
            for row in rows {
                let here = index
                index += 1
                if row.isFolded {
                    marks.append(Mark(index: here, text: row.text))
                    walk(row.folded)
                }
            }
        }
        walk(rows)
        return marks
    }

    /// Folds rows, all shown, as the marks say.
    public static func apply(_ marks: [Mark], to rows: [Row]) -> [Row] {
        guard !marks.isEmpty else { return rows }
        var rows = Row.unfold(rows)
        var taken = Set<Int>()
        var targets: [Int] = []
        for mark in marks {
            if mark.index < rows.count, rows[mark.index].text == mark.text, !taken.contains(mark.index) {
                targets.append(mark.index)
                taken.insert(mark.index)
            } else if let nearest = rows.indices
                .filter({ rows[$0].text == mark.text && !taken.contains($0) })
                .min(by: { abs($0 - mark.index) < abs($1 - mark.index) }) {
                targets.append(nearest)
                taken.insert(nearest)
            }
        }
        // From the last, so folding a row leaves the places of those before
        // it where they were, and an outer fold takes its folded inner rows.
        for index in targets.sorted(by: >) {
            OutlineEditing.fold(&rows, at: index)
        }
        return rows
    }
}
