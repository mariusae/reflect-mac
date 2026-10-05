import Foundation
import Testing
@testable import PrismCore

struct RecentEditsTests {
    @Test func recordsChangedRowsWithAncestors() {
        var recent = RecentEdits()
        let old = "- Project\n    - idea one\n- Other\n"
        let new = "- Project\n    - idea one\n    - idea two\n- Other changed\n"
        recent.note("notes/a.md", from: old, to: new)
        #expect(recent.edits.map(\.text) == ["idea two", "Other changed"])
        #expect(recent.edits[0].ancestors == ["Project"])
        // Typed on: the same row, its latest words.
        recent.note("notes/a.md", from: new, to: new.replacingOccurrences(of: "idea two", with: "idea two more"))
        #expect(recent.edits.map(\.text) == ["idea two more", "Other changed"])
        #expect(recent.matching("project").map(\.text) == ["idea two more"])
        #expect(RecentEdits.locate(recent.edits[0], in: new.replacingOccurrences(of: "idea two", with: "idea two more")) == 2)
    }
}

struct RecentEditsTitleTests {
    @Test func matchesTheNoteName() {
        var recent = RecentEdits()
        recent.note("notes/monarch.md", from: "", to: "- a row\n")
        #expect(recent.matching("monarch", title: { _ in "Monarch" }).count == 1)
        #expect(recent.matching("monarch").isEmpty)
    }
}
