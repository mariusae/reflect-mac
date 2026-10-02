import Foundation
import Testing
@testable import ReflectCore

@Suite struct OutlineFindTests {
    let rows = OutlineMarkdown.parse("""
    # Plans

    - Projects
      - Alpha
        - [ ] ship alpha
        - notes on alpha
      - Beta
    - Personal
      - Alpha centauri trip

    ## Later

    - someday
    """).rows

    @Test func everyRowHasItsPath() {
        let entries = OutlineFind.entries(rows)
        let alpha = entries.first { $0.text == "Alpha" }!
        #expect(alpha.path == ["Plans", "Projects"])
        #expect(alpha.children == 2)
        #expect(entries.first { $0.text == "someday" }?.path == ["Plans", "Later"])
    }

    @Test func foldedRowsAreFound() {
        var folded = rows
        let projects = folded.firstIndex { $0.text == "Projects" }!
        OutlineEditing.fold(&folded, at: projects)
        let entries = OutlineFind.entries(folded)
        #expect(entries.contains { $0.text == "ship alpha" && $0.path == ["Plans", "Projects", "Alpha"] })
    }

    @Test func aQueryMatchesTheRowAndItsPath() {
        let entries = OutlineFind.entries(rows)
        // Both words in the row's own text, or in it and where it is.
        #expect(OutlineFind.find("proj alph", in: entries).first?.text == "Alpha")
        #expect(OutlineFind.find("personal alpha", in: entries).first?.text == "Alpha centauri trip")
        // A word only in the path is not enough.
        #expect(!OutlineFind.find("projects", in: entries).contains { $0.text == "Beta" })
        // The row itself, before rows that only mention it deeper down.
        #expect(OutlineFind.find("alpha", in: entries).first?.text == "Alpha")
    }

    @Test func emptyQueriesShowALevel() {
        let entries = OutlineFind.entries(rows)
        // Under the title that holds the whole note.
        #expect(OutlineFind.find("", in: entries).map(\.text) == ["Projects", "Personal", "Later"])
        let projects = entries.first { $0.text == "Projects" }!.index
        #expect(OutlineFind.find("", in: entries, within: projects).map(\.text) == ["Alpha", "Beta"])
        #expect(OutlineFind.find("ship", in: entries, within: projects).map(\.text) == ["ship alpha"])
    }
}

@Suite struct RowIndexTests {
    @Test func rowsAreFoundAcrossNotesByTheirNotesToo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-rows-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# Plans\n\n- Projects\n  - Alpha\n    - ship it\n".write(to: notes.appendingPathComponent("plans.md"), atomically: true, encoding: .utf8)
        try "# Trips\n\n- Alpha centauri\n".write(to: notes.appendingPathComponent("trips.md"), atomically: true, encoding: .utf8)
        let index = NoteIndex(root: root)
        index.scan()
        let rows = RowIndex(index: index)
        rows.update()

        let alpha = rows.find("alpha")
        #expect(Set(alpha.map(\.entry.text)) == ["Alpha", "Alpha centauri"])
        // The note's title is part of where a row is.
        #expect(rows.find("plans alpha").map(\.entry.text) == ["Alpha"])
        #expect(rows.find("trips alpha").first?.noteTitle == "Trips")
        #expect(rows.find("alpha", excluding: "notes/plans.md").map(\.entry.text) == ["Alpha centauri"])

        // A changed note is taken in again.
        try "# Trips\n\n- Beta prime\n".write(to: notes.appendingPathComponent("trips.md"), atomically: true, encoding: .utf8)
        Thread.sleep(forTimeInterval: 1.1)
        try "# Trips\n\n- Beta prime\n".write(to: notes.appendingPathComponent("trips.md"), atomically: true, encoding: .utf8)
        index.refresh("notes/trips.md")
        rows.update()
        #expect(rows.find("centauri").isEmpty)
        #expect(rows.find("beta").first?.noteTitle == "Trips")
    }
}
