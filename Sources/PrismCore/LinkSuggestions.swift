import Foundation
import ReflectCore

/// Finishing a link as it is typed: after `@` at the start of a word, or
/// after `[[`, the notes and days what follows names, the chosen one put in
/// as `[[Name]]`. What the editor asks, kept apart from any editor.
public enum LinkSuggestions {
    /// What started it: `@` — easy on a phone's keys — or `[[`.
    public enum Trigger: Sendable {
        case at, brackets

        public var text: String { self == .at ? "@" : "[[" }
    }

    /// A note or day to link to.
    public struct Candidate: Equatable, Sendable {
        /// As it is shown: a day by its date.
        public var title: String
        /// What the link says: a day as `YYYY-MM-DD`, a note by its title.
        public var name: String
        public var isDay: Bool

        public init(title: String, name: String, isDay: Bool) {
            self.title = title
            self.name = name
            self.isDay = isDay
        }
    }

    /// Whether what was just typed at `location` — its last character —
    /// starts a link: an `@` at the start of a word, not in an address
    /// (`a@b`); or the second `[` of `[[`, not of `[[[`.
    public static func trigger(in text: NSString, typedAt location: Int) -> Trigger? {
        guard location >= 0, location < text.length else { return nil }
        let character = text.character(at: location)
        if character == 0x40 {
            guard location > 0 else { return .at }
            let before = text.substring(with: NSRange(location: location - 1, length: 1))
            let opens = before.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || before == "\u{2028}" || "([{\"'“‘".contains(before)
            return opens ? .at : nil
        }
        if character == 0x5b, location >= 1, text.character(at: location - 1) == 0x5b,
           location < 2 || text.character(at: location - 2) != 0x5b {
            return .brackets
        }
        return nil
    }

    /// What has been typed after the trigger, which ends at `start`, up to
    /// the caret — or nil when the caret has left it, or, after `@`, when
    /// what is typed is plainly not a name.
    public static func query(in text: NSString, start: Int, caret: Int, trigger: Trigger) -> String? {
        let opener = (trigger.text as NSString).length
        guard caret >= start, start >= opener, caret <= text.length,
              text.substring(with: NSRange(location: start - opener, length: opener)) == trigger.text else { return nil }
        let typed = text.substring(with: NSRange(location: start, length: caret - start))
        guard !typed.contains("]"), !typed.contains("\n"), !typed.contains("\u{2028}"), typed.count <= 120 else { return nil }
        if trigger == .at {
            // A name has spaces in it, but not two together, nor ends a sentence.
            guard typed.count <= 60, !typed.contains("  "), !typed.hasPrefix(" "),
                  !(typed.last.map { ".,;:!?)".contains($0) } ?? false) else { return nil }
        }
        return typed
    }

    /// The days and notes a query names, best first: a day it says —
    /// `today`, `tomorrow`, `2026-10-05` — then the notes by name.
    public static func candidates(_ query: String, index: NoteIndex, today: Day = .today, limit: Int = 8) -> [Candidate] {
        let query = query.trimmingCharacters(in: .whitespaces)
        var found: [Candidate] = []
        let lowered = query.lowercased()
        let offsets = ["today": 0, "tomorrow": 1, "yesterday": -1]
        var days: [Day] = []
        if let day = DayQuery.day(query, today: today) { days.append(day) }
        for (word, offset) in offsets.sorted(by: { $0.value < $1.value }) where !lowered.isEmpty && word.hasPrefix(lowered) {
            days.append(today.adding(offset))
        }
        for day in days where !found.contains(where: { $0.name == day.description }) {
            found.append(Candidate(title: dayTitle(day, today: today), name: day.description, isDay: true))
        }
        for match in index.matches(query, limit: limit) where !match.entry.title.isEmpty {
            found.append(Candidate(title: match.entry.title, name: match.entry.title, isDay: false))
        }
        return Array(found.prefix(limit))
    }

    /// The text to put in for a choice, and where: over the trigger and what
    /// was typed after it — `@` and all, as `[[Name]]` — and over the closing
    /// `]]` after the caret, when there is one already.
    public static func accepting(_ candidate: Candidate, in text: NSString, start: Int, caret: Int, trigger: Trigger) -> (range: NSRange, text: String) {
        let opener = (trigger.text as NSString).length
        let closing = caret + 2 <= text.length && text.substring(with: NSRange(location: caret, length: 2)) == "]]"
        let end = caret + (trigger == .brackets && closing ? 2 : 0)
        return (NSRange(location: start - opener, length: end - start + opener), "[[" + candidate.name + "]]")
    }

    static func dayTitle(_ day: Day, today: Day) -> String {
        let named = [0: "Today", 1: "Tomorrow", -1: "Yesterday"]
        for (offset, name) in named where today.adding(offset) == day { return name }
        guard let date = day.date else { return day.description }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
        return formatter.string(from: date)
    }
}
