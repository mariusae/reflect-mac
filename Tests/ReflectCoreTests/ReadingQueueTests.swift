import Foundation
import Testing
import ReflectCore
@testable import PrismCore

@Suite struct ReadingQueueTests {
    private func graph(_ files: [String: String]) throws -> (NoteIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let index = NoteIndex(root: root)
        index.scan()
        return (index, root)
    }

    private let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!

    @Test func theInboxsLinksOldestSavedFirstSnoozedAndUnreadableLeftOut() throws {
        let (index, root) = try graph([
            "notes/newer.md": "---\ninbox: true\n---\n# Newer\n\n- URL: <https://example.com/newer>\n",
            "notes/older.md": "---\ninbox: true\n---\n# Older\n\n- URL: <https://example.com/older>\n",
            "notes/snoozed.md": "---\ninbox: true\nsnoozed_until: 2026-11-02T08:00\n---\n# Snoozed\n\n- URL: <https://example.com/s>\n",
            "notes/woke.md": "---\ninbox: true\nsnoozed_until: 2026-10-01T08:00\n---\n# Woke\n\n- See https://example.com/w\n",
            "notes/plain.md": "---\ninbox: true\n---\n# Plain\n\n- Nothing to read here\n",
            "notes/done.md": "# Done\n\n- URL: <https://example.com/done>\n",
            "daily/2026-10-20.md": "- [[Links]]\n  - [[Newer]]\n",
            "daily/2026-10-02.md": "- [[Links]]\n  - [[Older]]\n",
            "daily/2026-10-05.md": "- [[Woke]]\n",
            "daily/2026-10-25.md": "- [[Older]] again\n",
        ])
        let (items, next) = ReadingQueue.items(index: index, root: root, now: now)
        #expect(items.map(\.path) == ["notes/older.md", "notes/woke.md", "notes/newer.md"])
        #expect(next.map(ReadingQueue.written) == "2026-11-02T08:00")
    }

    @Test func snoozesComeBackInTheMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // A Tuesday, at noon.
        let written = { (snooze: ReadingQueue.Snooze) in
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: snooze.until(from: self.now, calendar: calendar))
        }
        #expect(written(.laterToday) == "2026-10-27T15:00:00Z")
        #expect(written(.tomorrow) == "2026-10-28T08:00:00Z")
        #expect(written(.weekend) == "2026-10-31T09:00:00Z")
        #expect(written(.nextWeek) == "2026-11-02T08:00:00Z")
        #expect(written(.nextMonth) == "2026-11-27T08:00:00Z")
    }
}
