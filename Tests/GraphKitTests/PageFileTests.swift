import Foundation
import Testing
@testable import GraphKit

@Suite struct PageFileTests {
    let sample = """
    ---
    id: 01jbxk3t6y8q2zp4m9v7c5r0wd
    title: HelloThere
    tags: [Welcome, Table of Contents]
    created: 2014-09-13T09:20:00Z
    modified: 2026-10-31T10:41:12.123Z
    caption: Hello
    ---
    Welcome to [[TiddlyWiki]].

    """

    @Test func readsTheFields() {
        let tiddler = PageFile.read(sample, fallbackTitle: "x")
        #expect(tiddler.title == "HelloThere")
        #expect(tiddler.id == "01jbxk3t6y8q2zp4m9v7c5r0wd")
        #expect(tiddler.tags == ["Welcome", "Table of Contents"])
        #expect(tiddler.created == TiddlyWikiDate.parse("20140913092000000"))
        #expect(tiddler.modified == TiddlyWikiDate.parse("20261031104112123"))
        #expect(tiddler.fields == [Page.Field("caption", .text("Hello"))])
        #expect(tiddler.text == "Welcome to [[TiddlyWiki]].\n")
    }

    @Test func writesBackTheSameBytes() {
        let odd = [
            sample,
            sample.replacingOccurrences(of: "\n", with: "\r\n"),
            "---\n# a comment\ntitle:   Spaced   \ntags:\n- one\n-   two\n\nweird: 'it''s'\n...\nbody",
            "---\ntitle: T\nnote: |\n  line one\n    indented\n\n  after a gap\n---\n",
            "---\n---\njust a body\n",
            "no frontmatter at all\n",
            "---\ntitle: never closed\n",
            "",
        ]
        for source in odd {
            let tiddler = PageFile.read(source, fallbackTitle: "fallback")
            #expect(PageFile.write(tiddler, over: source, fallbackTitle: "fallback") == source, "\(source.debugDescription)")
        }
    }

    @Test func changesOnlyWhatChanged() {
        var tiddler = PageFile.read(sample, fallbackTitle: "x")
        tiddler.tags.append("New")
        tiddler.text = "Changed.\n"
        tiddler[field: "caption"] = nil
        tiddler[field: "color"] = .text("#ff0000")
        #expect(PageFile.write(tiddler, over: sample) == """
        ---
        id: 01jbxk3t6y8q2zp4m9v7c5r0wd
        title: HelloThere
        tags: [Welcome, Table of Contents, New]
        created: 2014-09-13T09:20:00Z
        modified: 2026-10-31T10:41:12.123Z
        color: "#ff0000"
        ---
        Changed.

        """)
    }

    @Test func keepsADateWrittenAnotherWay() {
        let source = "---\ntitle: T\nmodified: 2026-10-31T10:41:12.000Z\n---\n"
        let tiddler = PageFile.read(source, fallbackTitle: "x")
        #expect(PageFile.write(tiddler, over: source) == source)
    }

    @Test func roundTripsAwkwardValues() {
        let values = ["", " leading", "trailing ", "a: b", "#hash", "- dash", "true", "42", "3.14", "it's \"quoted\"",
                      "back\\slash", "two\nlines\n", "no newline\nat end", "\n starts badly", "tab\there", "[bracket",
                      "ünïcødé", "x # not a comment"]
        for value in values {
            let tiddler = Page(title: value.isEmpty ? "empty" : value, tags: [value, "a, b", "[[x]]"].filter { !$0.isEmpty },
                                  fields: [Page.Field("f", .text(value)), Page.Field("l", .list([value, "y"]))])
            let source = PageFile.write(tiddler)
            let back = PageFile.read(source, fallbackTitle: "empty")
            #expect(back.fields == tiddler.fields, "\(value.debugDescription) → \(source)")
            #expect(back.tags == tiddler.tags, "\(value.debugDescription) → \(source)")
            #expect(back.title == tiddler.title.trimmingCharacters(in: .newlines) || value.contains("\n"))
        }
    }

    @Test func writesLongListsAnItemALine() {
        let tiddler = Page(title: "Contents", fields: [Page.Field("list", .list(["One", "Two", "Three", "Four", "Five"]))])
        #expect(PageFile.write(tiddler) == "---\ntitle: Contents\nlist:\n  - One\n  - Two\n  - Three\n  - Four\n  - Five\n---\n")
    }

    @Test func addsAHeaderWhereThereWasNone() {
        let tiddler = Page(title: "Plain", text: "body\n")
        #expect(PageFile.write(tiddler, over: "body\n") == "---\ntitle: Plain\n---\nbody\n")
        #expect(PageFile.write(tiddler, over: "---\n---\nbody\n") == "---\ntitle: Plain\n---\nbody\n")
    }

    @Test func fallsBackToTheFileName() {
        #expect(PageFile.read("just text", fallbackTitle: "name").title == "name")
    }
}

@Suite struct WikiTests {
    @Test func indexesLinksAndTags() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        try wiki.save(Page(title: "Contents", fields: [Page.Field("list", .list(["B"]))], text: "See [[A]] and ![[B]]."))
        try wiki.save(Page(title: "A", tags: ["Contents"], text: "`[[not a link]]` [[B|bee]]"))
        try wiki.save(Page(title: "B", tags: ["Contents"], text: "[[Nowhere]]"))

        let reread = PageIndex(root: root)
        try reread.load()
        #expect(reread.titles == ["A", "B", "Contents"])
        #expect(reread.backlinks(to: "B") == ["A", "Contents"])
        #expect(reread.missing() == ["Nowhere"])
        #expect(reread.tagged("Contents") == ["B", "A"])
        // Contents is a tag, so not an orphan, though nothing links to it.
        #expect(reread.orphans() == [])
    }

    @Test func savesUnderFreeNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        #expect(try wiki.save(Page(title: "Jermolene")).path == "notes/jermolene.md")
        #expect(try wiki.save(Page(title: "@Jermolene")).path == "notes/jermolene-2.md")
        // Renaming keeps the file.
        var renamed = try #require(wiki["Jermolene"])
        renamed.title = "Jeremy"
        #expect(try wiki.save(renamed, replacing: "Jermolene").path == "notes/jermolene.md")
        #expect(wiki["Jermolene"] == nil)
    }
}

@Suite struct MovingFileTests {
    @Test func aNewTiddlersFileFollowsItsTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moving-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let wiki = PageIndex(root: root)
        try wiki.save(Page(title: "New Page", text: "Hello"))
        var renamed = try #require(wiki["New Page"])
        renamed.title = "Greetings"
        #expect(try wiki.save(renamed, replacing: "New Page", movingFile: true).path == "notes/greetings.md")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/new-tiddler.md").path))
        // Without moving, a renamed tiddler keeps its file.
        var again = try #require(wiki["Greetings"])
        again.title = "Salutations"
        #expect(try wiki.save(again, replacing: "Greetings").path == "notes/greetings.md")
    }
}
