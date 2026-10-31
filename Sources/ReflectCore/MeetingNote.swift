import Foundation

/// A meeting's own note, made from a calendar's event: named for the event
/// and its day, saying when it is and who is in it — each a link, a note
/// of their own once written in — and room for what is said.
public enum MeetingNote {
    /// What it is called: the event's name, and its day — a meeting held
    /// every week a note for each time.
    public static func title(_ name: String, on day: Day, calendar: Calendar = .current) -> String {
        guard let date = day.date else { return name }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(day.year == Day.today.year ? "MMMMd" : "MMMMdyyyy")
        return "\(name), \(formatter.string(from: date))"
    }

    /// Its text: its title, when — the day linked — who, and Notes, to write under.
    public static func source(title: String, day: Day, start: Date, end: Date, people: [String], calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        var rows = [Row(kind: .heading(1), text: title),
                    Row(kind: .bullet, text: "When: [[\(day.description)]] \(time.string(from: start))–\(time.string(from: end))")]
        let named = people.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains("@") }
        if !named.isEmpty { rows.append(Row(kind: .bullet, text: "With: " + named.map { "[[\($0)]]" }.joined(separator: ", "))) }
        rows.append(Row(kind: .bullet, text: "Notes"))
        return OutlineMarkdown.serialize(Outline(rows: rows))
    }
}

extension MeetingNote {
    /// The note for a meeting: the one made before, or made now — and a
    /// link to it at the top of its day, where there is none yet. Its path.
    public static func make(_ name: String, day: Day, start: Date, end: Date, people: [String],
                            in graph: Graph, index: NoteIndex) throws -> String {
        let title = title(name, on: day)
        if let found = index.resolve(title) { return found }
        let path = try NoteCreation.create(title: title, in: graph.root)
        try graph.write(source(title: title, day: day, start: start, end: end, people: people), path: path)
        index.refresh(path)
        // From its day: a link at the top, once.
        let dayPath = GraphPaths.dailyPath(for: day)
        let daySource = graph.read(path: dayPath) ?? ""
        if !daySource.contains("[[\(title)]]") {
            try graph.write(QuickNote.prepending([Row(kind: .bullet, text: "[[\(title)]]")], toDay: daySource), path: dayPath)
            index.refresh(dayPath)
        }
        return path
    }
}
