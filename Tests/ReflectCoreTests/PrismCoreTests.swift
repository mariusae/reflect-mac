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
