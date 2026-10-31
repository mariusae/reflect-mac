import Foundation
import Testing
import ReflectCore

@Suite struct MeetingNoteTests {
    @Test func aMeetingsNoteSaysWhenAndWho() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = Day(year: 2026, month: 10, day: 30)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 10, minute: 30))!
        let text = MeetingNote.source(title: "Design review, October 30", day: day, start: start, end: end,
                                      people: ["Ana Lima", "bob@example.com", " "], calendar: calendar)
        #expect(text == "# Design review, October 30\n- When: [[2026-10-30]] 10:00–10:30\n- With: [[Ana Lima]]\n- Notes\n")
    }
}
