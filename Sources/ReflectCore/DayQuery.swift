import Foundation

/// A day as it might be asked for in a few words: `today`, `yesterday`,
/// `friday`, `last friday`, `next week`, `3 days ago`, `in two weeks`,
/// `a month ago` — or a date as written, `2026-10-05`, `Jan 3`, `March 5
/// 2024`, which the system reads.
public enum DayQuery {
    /// The day a query names, counted from `today`; nil when it names none.
    public static func day(_ query: String, today: Day = .today) -> Day? {
        let text = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
        guard !text.isEmpty else { return nil }
        if let day = Day(text) { return day }
        switch text {
        case "today", "now": return today
        case "tomorrow", "tmrw", "tmr": return today.adding(1)
        case "yesterday": return today.adding(-1)
        case "last week": return today.adding(-7)
        case "next week": return today.adding(7)
        default: break
        }
        if let day = weekday(text, today: today) { return day }
        if let day = relative(text, today: today) { return day }
        return detected(text, today: today)
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// `friday` — the coming one, today if it is one — `last friday`, `next friday`.
    private static func weekday(_ text: String, today: Day) -> Day? {
        var words = text.split(separator: " ").map(String.init)
        var direction = 0
        if words.count == 2, words[0] == "last" || words[0] == "past" || words[0] == "previous" {
            direction = -1
            words.removeFirst()
        } else if words.count == 2, words[0] == "next" || words[0] == "this" || words[0] == "coming" {
            direction = words[0] == "next" ? 1 : 0
            words.removeFirst()
        }
        guard words.count == 1, words[0].count >= 3,
              let wanted = weekdays.firstIndex(where: { $0.hasPrefix(words[0]) }),
              let date = today.date else { return nil }
        let current = Calendar(identifier: .gregorian).component(.weekday, from: date) - 1
        switch direction {
        case -1:
            let back = (current - wanted + 7) % 7
            return today.adding(-(back == 0 ? 7 : back))
        case 1:
            let ahead = (wanted - current + 7) % 7
            return today.adding(ahead == 0 ? 7 : ahead)
        default:
            return today.adding((wanted - current + 7) % 7)
        }
    }

    private static let numbers = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                                  "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]

    /// `3 days ago`, `in two weeks`, `a month from now`.
    private static func relative(_ text: String, today: Day) -> Day? {
        var words = text.split(separator: " ").map(String.init)
        var sign = 0
        if words.first == "in" {
            sign = 1
            words.removeFirst()
        } else if words.last == "ago" {
            sign = -1
            words.removeLast()
        } else if words.count >= 3, words.suffix(2) == ["from", "now"] {
            sign = 1
            words.removeLast(2)
        } else if words.last == "later" || words.last == "hence" {
            sign = 1
            words.removeLast()
        }
        guard sign != 0, words.count == 2, let count = Int(words[0]) ?? numbers[words[0]] else { return nil }
        let unit = words[1].hasSuffix("s") ? String(words[1].dropLast()) : words[1]
        guard let date = today.date else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        let component: Calendar.Component
        switch unit {
        case "day": return today.adding(sign * count)
        case "week": return today.adding(sign * count * 7)
        case "month": component = .month
        case "year": component = .year
        default: return nil
        }
        return calendar.date(byAdding: component, value: sign * count, to: date).map { Day($0) }
    }

    /// A date as written, read the system's way — only when it is all the
    /// query says.
    private static func detected(_ text: String, today: Day) -> Day? {
        guard text.rangeOfCharacter(from: .decimalDigits) != nil || weekdays.contains(where: { text.contains($0) })
                || ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].contains(where: { text.contains($0) }),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              match.range.length >= (text as NSString).length - 1, let date = match.date else { return nil }
        return Day(date)
    }
}
