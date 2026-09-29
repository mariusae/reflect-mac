import Foundation
import Testing
@testable import ReflectCore

@Suite struct WeekTests {
    @Test func weeksAreISO() {
        #expect(Week(Day(year: 2026, month: 9, day: 28)).description == "2026-W40")   // a Monday
        #expect(Week(Day(year: 2026, month: 10, day: 4)).description == "2026-W40")   // its Sunday
        #expect(Week(Day(year: 2026, month: 10, day: 5)).description == "2026-W41")
        // The first days of a year can be the last week of the one before.
        #expect(Week(Day(year: 2027, month: 1, day: 1)).description == "2026-W53")
        #expect(Week(Day(year: 2024, month: 12, day: 30)).description == "2025-W01")
    }

    @Test func weeksReadTheirNames() {
        let week = Week("2026-W40")
        #expect(week?.monday == Day(year: 2026, month: 9, day: 28))
        #expect(week?.sunday == Day(year: 2026, month: 10, day: 4))
        #expect(Week("2026-w40") == week)
        #expect(Week("2025-W53") == nil)   // 2025 has 52 weeks
        #expect(Week("2026-W00") == nil)
        #expect(Week("2026-40") == nil)
        #expect(week?.adding(1).description == "2026-W41")
        #expect(week?.adding(-40).description == "2025-W52")
    }

    @Test func weeklyNotesAreNamedAndFound() {
        #expect(GraphPaths.weeklyPath(for: Week("2026-W40")!) == "weekly/2026-W40.md")
        #expect(GraphPaths.week(fromWeeklyPath: "weekly/2026-W40.md") == Week("2026-W40"))
        let entry = NoteIndex.entry(path: "weekly/2026-W40.md", source: "- plans\n")
        #expect(entry.title == "Week 40, 2026")
        #expect(entry.aliases.contains("2026-W40"))
        let titled = NoteIndex.entry(path: "weekly/2026-W40.md", source: "# Launch week\n")
        #expect(titled.title == "Launch week")
    }
}
