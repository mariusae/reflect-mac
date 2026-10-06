import Testing
@testable import ReflectCore

@Suite struct TimeBlockTests {
    @Test func stamps() throws {
        let a = try #require(TimeStamp.at(startOf: "9:00–10:30 Deep work"))
        #expect(a.start == 540 && a.end == 630 && a.range.length == 10 && a.fullRange.length == 11)
        let b = try #require(TimeStamp.at(startOf: "11am Standup"))
        #expect(b.start == 660 && b.end == nil && b.style.twelveHour)
        let c = try #require(TimeStamp.at(startOf: "11-1pm lunch"))
        #expect(c.start == 660 && c.end == 780)
        let d = try #require(TimeStamp.at(startOf: "14:00 to 15:30 Review"))
        #expect(d.start == 840 && d.end == 930 && d.style.separator == " to ")
        let e = try #require(TimeStamp.at(startOf: "09:00 - 9:30"))
        #expect(e.style.padded && e.end == 570 && e.fullRange.length == 12)
        let f = try #require(TimeStamp.at(startOf: "23:00–1:00 night"))
        #expect(f.end == 25 * 60)
        #expect(TimeStamp.at(startOf: "9 apples") == nil)
        let bare = try #require(TimeStamp.at(startOf: "11-1: there"))
        #expect(bare.isBare && bare.start == 660 && bare.end == 780 && bare.range.length == 4 && bare.fullRange.length == 6)
        #expect(TimeStamp.at(startOf: "9 shift") == nil)
        #expect(TimeStamp.at(startOf: "2026-10-05 meeting") == nil)
        #expect(TimeStamp.at(startOf: "3 tomorrow") == nil)
        #expect(TimeStamp.at(startOf: "25:00 x") == nil)
        #expect(TimeStamp.at(startOf: "9:00") != nil)
    }

    @Test func writing() throws {
        let a = try #require(TimeStamp.at(startOf: "9am–10:30am x"))
        #expect(a.written(start: 570, end: 690) == "9:30am–11:30am")
        let b = try #require(TimeStamp.at(startOf: "09:00 - 10:00"))
        #expect(b.written(start: 480, end: 1380) == "08:00 - 23:00")
    }

    @Test func timelines() {
        let rows: [Row] = [
            Row(kind: .bullet, depth: 0, text: "Plan"),
            Row(kind: .bullet, depth: 1, text: "9:00–10:30 Deep work"),
            Row(kind: .bullet, depth: 2, text: "chapter 3"),
            Row(kind: .bullet, depth: 1, text: "10:30 Email", task: .open),
            Row(kind: .bullet, depth: 1, text: "12:00–13:00 Lunch"),
            Row(kind: .bullet, depth: 1, text: ""),
            Row(kind: .bullet, depth: 0, text: "After"),
        ]
        let found = Timeline.find(rows)
        #expect(found.count == 1)
        let t = found[0]
        #expect(t.parent == 0 && t.blocks.count == 3)
        #expect(t.blocks[0].rows == 1..<3 && t.blocks[0].free == 0)
        #expect(t.blocks[1].end == 720 && t.blocks[1].free == 0)
        #expect(t.blocks[2].rows == 4..<6)
        let moved = t.moved(0, by: 15, resizing: false, alone: false, texts: rows.map(\.text))
        #expect(moved[1] == "9:15–10:45 Deep work" && moved[3] == "10:45 Email" && moved[4] == "12:15–13:15 Lunch")
        let resized = t.moved(1, by: 30, resizing: true, alone: false, texts: rows.map(\.text))
        #expect(resized[3] == "10:30–12:30 Email" && resized[4] == "12:30–13:30 Lunch")
        #expect(Timeline.find([Row(kind: .bullet, text: "P"), Row(kind: .bullet, depth: 1, text: "9:00 a"), Row(kind: .bullet, depth: 1, text: "b")]).isEmpty)
        // A bare range among plain times is one; bare ranges alone are counts.
        let mixed = Timeline.find([Row(kind: .bullet, text: "Blocks!"), Row(kind: .bullet, depth: 1, text: "10:00-11:00: hello", task: .open),
                                   Row(kind: .bullet, depth: 1, text: "11-1: there", task: .open)])
        #expect(mixed.count == 1 && mixed[0].blocks[1].end == 780)
        #expect(Timeline.find([Row(kind: .bullet, text: "Cake"), Row(kind: .bullet, depth: 1, text: "1-2 cups flour"),
                               Row(kind: .bullet, depth: 1, text: "2-3 eggs")]).isEmpty)
    }

    @Test func newBlocks() {
        // Under a row that is no timeline: its last child, one block alone a timeline.
        let plan = [Row(kind: .bullet, text: "Plan"), Row(kind: .bullet, depth: 1, text: "notes")]
        var made = Timeline.newBlock(in: plan, at: 0, now: 9 * 60 + 7)
        #expect(made.row == 2 && made.rows[2].text == "9:05–9:20 " && made.rows[2].depth == 1 && made.offset == 10)
        #expect(Timeline.find([Row(kind: .bullet, text: "Plan"), Row(kind: .bullet, depth: 1, text: "9:05–9:20 x")]).count == 1)
        // An empty row becomes the block.
        made = Timeline.newBlock(in: [Row(kind: .bullet, text: "")], at: 0, now: 600)
        #expect(made.row == 0 && made.rows[0].text == "10:00–10:15 ")
        // Among blocks, in order of time, written as they are.
        let blocks = [Row(kind: .bullet, text: "Day"),
                      Row(kind: .bullet, depth: 1, text: "9am–10am a", task: .open),
                      Row(kind: .bullet, depth: 2, text: "under a"),
                      Row(kind: .bullet, depth: 1, text: "2pm–3pm b", task: .open)]
        made = Timeline.newBlock(in: blocks, at: 2, now: 12 * 60 + 30)
        #expect(made.row == 3 && made.rows[3].text == "12:30pm–12:45pm " && made.rows[3].task == .open && made.rows[3].depth == 1)
        // Now taken: the next free time.
        made = Timeline.newBlock(in: blocks, at: 1, now: 9 * 60 + 20)
        #expect(made.row == 3 && made.rows[3].text == "10am–10:15am ")
        made = Timeline.newBlock(in: blocks, at: 1, now: 16 * 60)
        #expect(made.row == 4 && made.rows[4].text == "4pm–4:15pm ")
    }
}
