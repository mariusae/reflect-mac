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
        #expect(TimeStamp.at(startOf: "9-5 shift") == nil)
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
    }
}
