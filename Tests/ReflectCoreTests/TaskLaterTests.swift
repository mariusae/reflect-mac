import Testing
@testable import ReflectCore

@Suite struct TaskLaterTests {
    // 2026-10-30 is a Friday.
    let friday = Day(year: 2026, month: 10, day: 30)

    @Test func laterDays() {
        #expect(TaskLater.tomorrow.day(from: friday) == Day(year: 2026, month: 10, day: 31))
        #expect(TaskLater.weekend.day(from: friday) == Day(year: 2026, month: 10, day: 31))
        #expect(TaskLater.nextWeek.day(from: friday) == Day(year: 2026, month: 11, day: 2))
        // On a Saturday or a Sunday: the next weekend; next week, the coming Monday.
        let saturday = Day(year: 2026, month: 10, day: 31), sunday = Day(year: 2026, month: 11, day: 1)
        #expect(TaskLater.weekend.day(from: saturday) == Day(year: 2026, month: 11, day: 7))
        #expect(TaskLater.weekend.day(from: sunday) == Day(year: 2026, month: 11, day: 7))
        #expect(TaskLater.nextWeek.day(from: sunday) == Day(year: 2026, month: 11, day: 2))
        let monday = Day(year: 2026, month: 11, day: 2)
        #expect(TaskLater.nextWeek.day(from: monday) == Day(year: 2026, month: 11, day: 9))
    }

    @Test func openTasksFromTheWeekBeforeAreCarried() {
        func task(_ day: Day?, _ ordinal: Int, done: Bool = false, due: Day? = nil) -> NoteTask {
            NoteTask(notePath: day.map(GraphPaths.dailyPath(for:)) ?? "notes/project.md", ordinal: ordinal, text: "t", done: done,
                     breadcrumbs: [], dueDate: due, day: day, noteTitle: "", pin: nil, modified: .distantPast)
        }
        let carried = Tasks.carried([
            task(friday.adding(-1), 0), task(friday.adding(-1), 1, done: true), task(friday.adding(-3), 0),
            task(friday.adding(-9), 0), task(friday, 0), task(friday.adding(-2), 0, due: friday.adding(4)),
            task(nil, 0, due: friday), task(nil, 1, due: friday.adding(1)), task(nil, 2),
        ], today: friday)
        #expect(carried.map(\.day) == [friday.adding(-1), friday.adding(-3), nil])
        #expect(carried.last?.ordinal == 0)
    }
}
