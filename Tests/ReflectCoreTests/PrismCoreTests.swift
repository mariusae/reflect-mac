import Foundation
import Testing
import ReflectCore
@testable import PrismCore

@Suite struct PrismCoreTests {
    private let note = """
    # Project

    - Plans
      - Ask about [[Monarch]] today
        - a detail
      - Something else
    - [[Monarch]] at the top
    ## Monarch notes
    - after the heading
    """

    @Test func slicesAreTheRowsWithWhatIsUnderThem() {
        let slices = NoteSlice.slices(holding: ["[[Monarch]]"], path: "notes/p.md", in: note)
        #expect(slices.map(\.rows.count) == [2, 1])
        #expect(slices[0].crumbs == ["Plans"])
        #expect(slices[0].rows[0].depth == 0)
    }

    @Test func aSliceWrittenBackChangesOnlyItself() throws {
        let slice = try #require(NoteSlice.slices(holding: ["[[Monarch]]"], path: "notes/p.md", in: note).first)
        var edited = slice.rows.map { row -> Row in
            var row = row
            row.depth += slice.depth
            return row
        }
        edited[0].text += " (edited)"
        let written = try #require(slice.writing(edited, into: note))
        #expect(written == note.replacingOccurrences(of: "today", with: "today (edited)"))
    }

    @Test func aHeadingFoundIsItselfAloneAndATitleIsNot() {
        let slices = NoteSlice.slices(finding: ["monarch", "project"], path: "notes/p.md", in: note)
        // Not "# Project", the title; "## Monarch notes" alone, not its section.
        #expect(slices.map { $0.rows.map(\.text) } == [
            ["Ask about [[Monarch]] today", "a detail"], ["[[Monarch]] at the top"], ["Monarch notes"],
        ])
    }

    @Test func weeksComeBeforeTheirDays() {
        #expect(Timeline.day(of: .note("weekly/2026-W40.md")) == Day(year: 2026, month: 9, day: 28))
        #expect(Timeline.day(of: .note("notes/x.md")) == nil)
        #expect(NoteSearch.words("  two  words ") == ["two", "words"])
    }

    @Test func flagsReadTheFrontmatter() {
        let entry = NoteIndex.entry(path: "notes/a.md", source: "---\ninbox: true\npinned: 3\n---\n# A\n")
        #expect(NoteFlags(entry, isEmptyTopic: false) == [.inbox, .pinned])
        #expect(NoteFlags(entry, isEmptyTopic: true).contains(.topic))
    }
}

@Suite struct OutlineKeysTests {
    private func rows(_ markdown: String) -> [Row] { OutlineMarkdown.parse(markdown).rows }
    private func markdown(_ rows: [Row]) -> String { OutlineMarkdown.serialize(Outline(rows: rows)) }

    @Test func returnSplitsARowAndCarriesItsType() throws {
        let split = try #require(OutlineKeys.split(rows("- [ ] buy milk\n"), at: .init(row: 0, offset: 4)))
        #expect(markdown(split.rows) == "- [ ] buy \n- [ ] milk\n")
        #expect(split.caret == .init(row: 1, offset: 0))
        let numbered = try #require(OutlineKeys.split(rows("1. one\n"), at: .init(row: 0, offset: 3)))
        #expect(markdown(numbered.rows) == "1. one\n2. \n")
    }

    @Test func returnAtTheStartOpensARowAbove() throws {
        let split = try #require(OutlineKeys.split(rows("- a\n- b\n"), at: .init(row: 1, offset: 0)))
        #expect(split.rows.map(\.text) == ["a", "", "b"])
        #expect(split.caret == .init(row: 2, offset: 0))
    }

    @Test func returnAfterAHeadingIsAPlainRow() throws {
        let split = try #require(OutlineKeys.split(rows("## Plans\n"), at: .init(row: 0, offset: 5)))
        #expect(split.rows[1].kind == .bullet)
    }

    @Test func returnAtTheEndOfAParentIsItsFirstChild() throws {
        let split = try #require(OutlineKeys.split(rows("- parent\n  - child\n"), at: .init(row: 0, offset: 6)))
        #expect(split.rows[1].depth == 1)
    }

    @Test func deleteAtTheStartUndoesTheTypeFirst() throws {
        let plain = try #require(OutlineKeys.plain(rows("- [ ] task\n"), at: 0))
        #expect(plain[0].task == nil)
        #expect(OutlineKeys.plain(rows("- plain\n"), at: 0) == nil)
    }

    @Test func markdownTypedSetsTheRowType() throws {
        var typed = rows("- \n")
        typed[0].text = "## Title"
        #expect(try #require(OutlineKeys.smartType(typed, at: 0, typed: "##"))[0].kind == .heading(2))
        typed[0].text = "[]buy"
        let check = try #require(OutlineKeys.smartType(typed, at: 0, typed: "[]"))
        #expect(check[0].task == .open && check[0].text == "buy")
        typed[0].text = "3.x"
        #expect(try #require(OutlineKeys.smartType(typed, at: 0, typed: "3."))[0].number == 3)
        typed[0].text = "hello"
        #expect(OutlineKeys.smartType(typed, at: 0, typed: "hello") == nil)
    }
}

@Suite struct LinkSuggestionsTests {
    @Test func anAtStartsALinkOnlyAtAWordsStart() {
        #expect(LinkSuggestions.trigger(in: "say @" as NSString, typedAt: 4) == .at)
        #expect(LinkSuggestions.trigger(in: "@" as NSString, typedAt: 0) == .at)
        #expect(LinkSuggestions.trigger(in: "me@" as NSString, typedAt: 2) == nil)
        #expect(LinkSuggestions.trigger(in: "a [[" as NSString, typedAt: 3) == .brackets)
        #expect(LinkSuggestions.trigger(in: "[[[" as NSString, typedAt: 2) == nil)
    }

    @Test func theQueryEndsWhenItIsNoLongerAName() {
        let text = "hi @Mon" as NSString
        #expect(LinkSuggestions.query(in: text, start: 4, caret: 7, trigger: .at) == "Mon")
        #expect(LinkSuggestions.query(in: "hi @Mon." as NSString, start: 4, caret: 8, trigger: .at) == nil)
        #expect(LinkSuggestions.query(in: text, start: 4, caret: 3, trigger: .at) == nil)
        #expect(LinkSuggestions.query(in: "[[two words" as NSString, start: 2, caret: 11, trigger: .brackets) == "two words")
    }

    @Test func aChoiceGoesInAsALink() {
        let at = LinkSuggestions.Candidate(title: "Monarch", name: "Monarch", isDay: false)
        let put = LinkSuggestions.accepting(at, in: "hi @Mon there" as NSString, start: 4, caret: 7, trigger: .at)
        #expect(put.range == NSRange(location: 3, length: 4))
        #expect(put.text == "[[Monarch]]")
        let closed = LinkSuggestions.accepting(at, in: "[[Mo]]" as NSString, start: 2, caret: 4, trigger: .brackets)
        #expect(closed.range == NSRange(location: 0, length: 6))
    }

    @Test func daysAndNotesAreFoundByName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try "# Monarch\n".write(to: root.appendingPathComponent("notes/monarch.md"), atomically: true, encoding: .utf8)
        try "# Money\n".write(to: root.appendingPathComponent("notes/money.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = NoteIndex(root: root)
        index.scan()
        let today = Day(year: 2026, month: 10, day: 3)
        let found = LinkSuggestions.candidates("mona", index: index, today: today)
        #expect(found.map(\.name) == ["Monarch"])
        let days = LinkSuggestions.candidates("tom", index: index, today: today)
        #expect(days.first == .init(title: "Tomorrow", name: "2026-10-04", isDay: true))
    }
}

@Suite struct TimelineGapTests {
    let today = Day(year: 2026, month: 10, day: 3)

    @Test func daysWithoutNotesAreAGapBetweenThoseWith() throws {
        let days: Set<Day> = [Day(year: 2026, month: 9, day: 20), Day(year: 2026, month: 9, day: 24)]
        let entries = Timeline.entries(days: days, weeks: [], today: today)
        let gaps = entries.compactMap(\.gap)
        #expect(gaps == [TimelineGap(from: Day(year: 2026, month: 9, day: 21), to: Day(year: 2026, month: 9, day: 23)),
                         TimelineGap(from: Day(year: 2026, month: 9, day: 25), to: Day(year: 2026, month: 10, day: 2))])
        #expect(gaps[1].count == 8)
        // In its place: after the day before it, before the day after.
        #expect(entries.map { $0.gap != nil ? "gap" : $0.day!.description } == ["2026-09-20", "gap", "2026-09-24", "gap", "2026-10-03"])
    }

    @Test func aGapBreaksAtAWeeksNoteSoTheWeekStaysBeforeItsMonday() {
        let days: Set<Day> = [Day(year: 2026, month: 9, day: 25)]
        let monday = Day(year: 2026, month: 9, day: 28)
        let entries = Timeline.entries(days: days, weeks: [("weekly/2026-W40.md", monday)], today: today)
        #expect(entries.map { $0.gap.map { "\($0.from)…\($0.to)" } ?? $0.path } == [
            "daily/2026-09-25.md", "2026-09-26…2026-09-27", "weekly/2026-W40.md", "2026-09-28…2026-10-02", "daily/2026-10-03.md",
        ])
    }

    @Test func openingAGapShowsItsLastDaysAndLeavesTheRest() throws {
        let days: Set<Day> = [Day(year: 2026, month: 9, day: 1)]
        let gap = try #require(Timeline.entries(days: days, weeks: [], today: today).compactMap(\.gap).first)
        let revealed = Timeline.reveal(gap)
        #expect(revealed.count == Timeline.revealCount)
        #expect(revealed.first == Day(year: 2026, month: 10, day: 2))
        let after = Timeline.entries(days: days, weeks: [], today: today, revealed: Set(revealed))
        #expect(after.compactMap(\.gap) == [TimelineGap(from: Day(year: 2026, month: 9, day: 2), to: Day(year: 2026, month: 9, day: 25))])
        #expect(after.filter { $0.day != nil }.count == 9)
    }
}

@Suite struct DayQueryTests {
    let today = Day(year: 2026, month: 10, day: 3) // a Saturday

    @Test func wordsForDays() {
        #expect(DayQuery.day("today", today: today) == today)
        #expect(DayQuery.day("Yesterday", today: today) == Day(year: 2026, month: 10, day: 2))
        #expect(DayQuery.day("tomorrow", today: today) == Day(year: 2026, month: 10, day: 4))
        #expect(DayQuery.day("2025-12-31", today: today) == Day(year: 2025, month: 12, day: 31))
    }

    @Test func weekdays() {
        #expect(DayQuery.day("friday", today: today) == Day(year: 2026, month: 10, day: 9))
        #expect(DayQuery.day("last friday", today: today) == Day(year: 2026, month: 10, day: 2))
        #expect(DayQuery.day("next sat", today: today) == Day(year: 2026, month: 10, day: 10))
        #expect(DayQuery.day("saturday", today: today) == today)
        #expect(DayQuery.day("last saturday", today: today) == Day(year: 2026, month: 9, day: 26))
    }

    @Test func countsOfDaysAndWeeks() {
        #expect(DayQuery.day("3 days ago", today: today) == Day(year: 2026, month: 9, day: 30))
        #expect(DayQuery.day("in two weeks", today: today) == Day(year: 2026, month: 10, day: 17))
        #expect(DayQuery.day("a month ago", today: today) == Day(year: 2026, month: 9, day: 3))
        #expect(DayQuery.day("2 days from now", today: today) == Day(year: 2026, month: 10, day: 5))
        #expect(DayQuery.day("last week", today: today) == Day(year: 2026, month: 9, day: 26))
    }

    @Test func datesAsWritten() {
        #expect(DayQuery.day("march 5 2024", today: today) == Day(year: 2024, month: 3, day: 5))
        #expect(DayQuery.day("monarch", today: today) == nil)
        #expect(DayQuery.day("mon", today: today) == Day(year: 2026, month: 10, day: 5))
    }
}
