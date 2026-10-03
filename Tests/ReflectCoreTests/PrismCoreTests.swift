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
