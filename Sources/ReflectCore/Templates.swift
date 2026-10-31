import Foundation

/// A note's rows used again: a new note made from them, or put into one.
/// `{{date}}` becomes the day's date, `{{day}}` its weekday, `{{time}}`
/// the time; the template's title and frontmatter stay its own.
public enum Templates {
    /// A template's rows, filled in for `date`: its title row left out.
    public static func rows(of source: String, at date: Date = Date(), calendar: Calendar = .current) -> [Row] {
        var rows = OutlineMarkdown.parse(source).rows
        if let first = rows.first, case .heading(1) = first.kind { rows.removeFirst() }
        if let first = rows.first, first.gap.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows[0].gap = [] }
        return rows.map { row in
            var row = row
            row.text = fill(row.text, at: date, calendar: calendar)
            row.folded = row.folded.map { child in
                var child = child
                child.text = fill(child.text, at: date, calendar: calendar)
                return child
            }
            return row
        }
    }

    /// The words with `{{date}}`, `{{day}}` and `{{time}}` filled in.
    public static func fill(_ text: String, at date: Date, calendar: Calendar = .current) -> String {
        guard text.contains("{{") else { return text }
        let day = Day(date, calendar: calendar)
        let weekday = DateFormatter()
        weekday.calendar = calendar
        weekday.timeZone = calendar.timeZone
        weekday.dateFormat = "EEEE"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateFormat = "HH:mm"
        return text.replacingOccurrences(of: "{{date}}", with: "[[\(day.description)]]")
            .replacingOccurrences(of: "{{day}}", with: weekday.string(from: date))
            .replacingOccurrences(of: "{{time}}", with: time.string(from: date))
    }
}
