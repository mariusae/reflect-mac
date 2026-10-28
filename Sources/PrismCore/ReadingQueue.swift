import Foundation
import ReflectCore

/// Prism Reader's: the inbox's links, one at a time, the oldest first —
/// each checked off, or snoozed, before the next comes.
///
/// A note is in the queue while it is in the inbox, has something to read
/// — a page it links to, a PDF it holds — and is not snoozed. Snoozed, its
/// frontmatter says till when: `snoozed_until: 2026-10-28T08:00`, the
/// phone's own time. Its age is the day it was saved — the first day
/// linking to it, as a page saved from the browser is — else when it last
/// changed.
public enum ReadingQueue {
    /// The frontmatter key a note is snoozed by: when it comes back.
    public static let snoozeKey = "snoozed_until"

    public struct Item: Equatable, Sendable {
        public let path: String
        /// When it was saved, for its place in the queue.
        public let saved: Date
    }

    /// What there is to read, oldest first; and the soonest a snoozed one
    /// comes back, when there is one.
    public static func items(index: NoteIndex, root: URL, now: Date = Date()) -> (items: [Item], next: Date?) {
        var items: [Item] = []
        var next: Date?
        for entry in index.inbox where entry.day == nil {
            // The file's word, not the index's: one checked off a moment ago is out.
            guard let text = try? String(contentsOf: root.appendingPathComponent(entry.path), encoding: .utf8),
                  isInInbox(text), !ReaderSource.all(in: text, root: root).isEmpty else { continue }
            if let until = snoozedUntil(in: text), until > now {
                next = min(next ?? until, until)
                continue
            }
            items.append(Item(path: entry.path, saved: index.firstDay(linking: entry.path)?.date ?? entry.modified))
        }
        items.sort { $0.saved != $1.saved ? $0.saved < $1.saved : $0.path < $1.path }
        return (items, next)
    }

    private static func isInInbox(_ text: String) -> Bool {
        Frontmatter(of: text).scalar("inbox").map { ["true", "yes", "on", "1"].contains($0.lowercased()) } ?? false
    }

    /// When a note is snoozed till, by its frontmatter: nil, not snoozed.
    public static func snoozedUntil(in text: String) -> Date? {
        guard let value = Frontmatter(of: text).scalar(snoozeKey) else { return nil }
        return stamp.date(from: value) ?? day.date(from: value)
    }

    /// When a link comes back, as said: "today at 18:00", "tomorrow at
    /// 8:00", "on Saturday at 9:00", "on November 27 at 8:00".
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(time)"
        }
        if date.timeIntervalSince(now) < 6 * 86400 { return "on \(date.formatted(.dateTime.weekday(.wide))) at \(time)" }
        return "on \(date.formatted(.dateTime.month(.wide).day())) at \(time)"
    }

    /// What the reader says with nothing left to read.
    public static func restDetail(next: Date?) -> String {
        next.map { "Snoozed links come back, the first \(when($0))." } ?? "The inbox has no links left to read."
    }

    /// A time as the frontmatter has it.
    public static func written(_ date: Date) -> String { stamp.string(from: date) }

    private static let stamp = formatter("yyyy-MM-dd'T'HH:mm")
    private static let day = formatter("yyyy-MM-dd")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// How long it is put off for.
    public enum Snooze: CaseIterable, Sendable {
        case laterToday, tomorrow, weekend, nextWeek, nextMonth

        public var title: String {
            switch self {
            case .laterToday: "Later Today"
            case .tomorrow: "Tomorrow"
            case .weekend: "This Weekend"
            case .nextWeek: "Next Week"
            case .nextMonth: "Next Month"
            }
        }

        public var symbol: String {
            switch self {
            case .laterToday: "clock"
            case .tomorrow: "sunrise"
            case .weekend: "sofa"
            case .nextWeek: "calendar"
            case .nextMonth: "calendar.badge.clock"
            }
        }

        /// When it comes back: in three hours; the next morning; Saturday's,
        /// or Monday's, morning; a month on, in the morning.
        public func until(from now: Date, calendar: Calendar = .current) -> Date {
            func morning(_ date: Date, hour: Int = 8) -> Date {
                calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date
            }
            func next(weekday: Int) -> Date {
                calendar.nextDate(after: now, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime) ?? now
            }
            switch self {
            case .laterToday: return now.addingTimeInterval(3 * 3600)
            case .tomorrow: return morning(calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            case .weekend: return morning(next(weekday: 7), hour: 9)
            case .nextWeek: return morning(next(weekday: 2))
            case .nextMonth: return morning(calendar.date(byAdding: .month, value: 1, to: now) ?? now)
            }
        }
    }
}
