import Foundation
import Testing
@testable import ReflectCore

/// Reflect's Tasks view grouping (group-tasks.ts), and ticking tasks off.
@Suite struct TasksTests {
    let today = Day(year: 2026, month: 9, day: 26)

    func task(_ text: String, path: String = "notes/n.md", day: Day? = nil, ordinal: Int = 0,
              pin: NoteEntry.Pin? = nil, modified: Date = .distantPast, title: String = "N") -> NoteTask {
        NoteTask(notePath: path, ordinal: ordinal, text: text, done: false, breadcrumbs: [],
                 dueDate: Tasks.dueDate(in: text), day: day, noteTitle: title, pin: pin, modified: modified)
    }

    @Test func findsOnlyRoundTasks() {
        let source = "- Plan\n  + [ ] pack\n  - [ ] a checklist item\n  + [x] book\n+ [ ] call [[2026-09-30]]\n"
        let entry = NoteIndex.entry(path: "daily/2026-09-20.md", source: source)
        let found = Tasks.tasks(in: source, path: "daily/2026-09-20.md", entry: entry)
        #expect(found.map(\.text) == ["pack", "book", "call [[2026-09-30]]"])
        #expect(found.map(\.done) == [false, true, false])
        #expect(found[0].breadcrumbs == ["Plan"])
        #expect(found[2].dueDate == Day(year: 2026, month: 9, day: 30))
        #expect(found[0].day == Day(year: 2026, month: 9, day: 20))
    }

    @Test func groupsAsReflectDoes() {
        let tasks = [
            task("past day, no due", day: Day(year: 2026, month: 9, day: 1)),               // current: not overdue
            task("due passed [[2026-09-20]]"),                                                // overdue
            task("due later [[2026-10-02]]", day: Day(year: 2026, month: 9, day: 1)),        // upcoming
            task("tomorrow's day", path: "daily/x.md", day: Day(year: 2026, month: 9, day: 27)), // upcoming
            task("undated, old note", path: "notes/old.md", modified: Date(timeIntervalSince1970: 1), title: "Old"),
            task("undated, new note", path: "notes/new.md", modified: Date(timeIntervalSince1970: 9), title: "New"),
            task("undated, pinned", path: "notes/pinned.md", pin: .order(1024), title: "Pinned"),
        ]
        let groups = Tasks.group(tasks, today: today)
        #expect(groups.map(\.label) == ["Current", "Overdue", "Upcoming", "Pinned", "New", "Old"])
        #expect(groups[0].tasks.map(\.text) == ["past day, no due"])
        #expect(groups[2].tasks.map(\.text) == ["tomorrow's day", "due later [[2026-10-02]]"])
    }

    @Test func breadcrumbsArePlainText() {
        let source = "- [[Weekly Note]] › **What needs doing?**\n  + [ ] a task\n"
        let found = Tasks.tasks(in: source, path: "notes/w.md", entry: NoteIndex.entry(path: "notes/w.md", source: source))
        #expect(found.first?.breadcrumbs == ["Weekly Note › What needs doing?"])
        #expect(InlineMarkup.plainText("see [the paper](https://x.org) and *this*") == "see the paper and this")
    }

    @Test func hidesALoneTasksParent() {
        #expect(Tasks.visibleBreadcrumbs(["Tasks"]) == [])
        #expect(Tasks.visibleBreadcrumbs(["TODO:"]) == [])
        #expect(Tasks.visibleBreadcrumbs(["Tasks", "Home"]) == ["Tasks", "Home"])
        #expect(Tasks.visibleBreadcrumbs(["Errands"]) == ["Errands"])
    }

    @Test func ticksTasksInTheirNote() {
        let source = "- Plan\n  + [ ] pack\n  - [ ] checklist\n  + [ ] book\n"
        #expect(Tasks.setting(done: true, ordinal: 1, in: source) == "- Plan\n  + [ ] pack\n  - [ ] checklist\n  + [x] book\n")
        #expect(Tasks.setting(done: true, ordinal: 5, in: source) == nil)
    }
}
