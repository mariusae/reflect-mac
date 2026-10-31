import Foundation
import Testing
@testable import GraphKit

/// docs/markdown.md's examples, as files: every app's reading and writing
/// of them holds to these.
@Suite struct FixtureTests {
    let root = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

    func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func page(_ path: String) throws -> Page {
        PageFile.read(try source(path), fallbackTitle: PageFolder.fallbackTitle(for: path), fixedTitle: PageFolder.titleIsFixed(path))
    }

    @Test(arguments: ["notes/project-atlas.md", "notes/people/ada-lovelace.md", "notes/person.md", "daily/2026-10-31.md",
                      "notes/imported.md", "notes/windows-note.md"])
    func everyFileIsWrittenBackAsItWasRead(_ path: String) throws {
        let text = try source(path)
        let read = try page(path)
        #expect(PageFile.write(read, over: text, fallbackTitle: PageFolder.fallbackTitle(for: path),
                               fixedTitle: PageFolder.titleIsFixed(path)) == text)
    }

    @Test func titles() throws {
        // A heading titles a note, and is not part of its text.
        let atlas = try page("notes/project-atlas.md")
        #expect(atlas.title == "Project Atlas // Planning")
        #expect(atlas.text.hasPrefix("- Kick-off with"))
        // Frontmatter's title wins; a day is its date, whatever heads it.
        #expect(try page("notes/imported.md").title == "HelloThere")
        let day = try page("daily/2026-10-31.md")
        #expect(day.title == "2026-10-31")
        #expect(day.text.hasPrefix("# Saturday"))
        #expect(try page("notes/windows-note.md").title == "Windows Note")
    }

    @Test func renamingRewritesTheHeading() throws {
        let text = try source("notes/project-atlas.md")
        var atlas = PageFile.read(text, fallbackTitle: "project-atlas")
        atlas.title = "Project Atlas"
        let written = PageFile.write(atlas, over: text, fallbackTitle: "project-atlas")
        #expect(written == text.replacingOccurrences(of: "# Project Atlas // Planning", with: "# Project Atlas"))
    }

    @Test func aNewNoteIsTitledByAHeading() {
        let page = Page(title: "Fresh", id: "01abc", fields: [Page.Field("wiki", .text("true"))], text: "Body.\n")
        #expect(PageFile.write(page, fallbackTitle: "fresh", headingTitle: true) == "---\nid: 01abc\nwiki: true\n---\n# Fresh\n\nBody.\n")
        #expect(PageFile.write(Page(title: "2026-11-01", text: "- A day\n"), fallbackTitle: "2026-11-01", fixedTitle: true) == "- A day\n")
    }

    @Test func theExtensionsAreBlocks() throws {
        let blocks = MarkdownBlock.parse(try page("notes/people/ada-lovelace.md").text)
        #expect(blocks.contains(.callout(kind: "tip", blocks: [.paragraph("Her notes are longer than the paper they annotate.")])))
        #expect(blocks.contains(.query(Query(text: "links to: {this}\nshow: list"))))
        #expect(blocks.contains { if case .table = $0 { true } else { false } })
        let atlas = MarkdownBlock.parse(try page("notes/project-atlas.md").text)
        guard case .list(let items) = atlas.first else { Issue.record("not a list"); return }
        #expect(items.map(\.checked) == [nil, nil, false, true, nil, nil])
    }

    @Test func theGraph() throws {
        let index = PageIndex(root: root)
        try index.load()
        #expect(index.titles == ["2026-10-31", "Ada Lovelace", "HelloThere", "Person", "Project Atlas // Planning", "Windows Note"])
        // Links lead by title, alias or part of a `//` title, case aside.
        #expect(index.title(for: "atlas") == "Project Atlas // Planning")
        #expect(index.title(for: "Planning") == "Project Atlas // Planning")
        #expect(index.title(for: "ada lovelace") == "Ada Lovelace")
        #expect(index.title(for: "2026-11-05") == "2026-11-05")
        #expect(index.title(for: "Nobody") == nil)
        #expect(index.backlinks(to: "Project Atlas // Planning") == ["2026-10-31"])
        #expect(index.backlinks(to: "Ada Lovelace") == ["2026-10-31", "Project Atlas // Planning"])
        #expect(index.missing() == ["Analytical Engine", "Charles Babbage", "TiddlyWiki"])
        // Tags are the frontmatter's and the inline #tags, together.
        #expect(index.tagged("planning") == ["2026-10-31", "Project Atlas // Planning"])
        #expect(index.tags(of: "Ada Lovelace") == ["Person"])
        // The wiki is metadata: a flag, queried.
        #expect(index["Ada Lovelace"]?.isWiki == true && index["Project Atlas // Planning"]?.isWiki == false)
        #expect(Query(text: "wiki: yes").run(in: index, this: "x") == ["Ada Lovelace", "Person"])
        #expect(Query(text: "tag: {this}").run(in: index, this: "Person") == ["Ada Lovelace"])
        #expect(index.schema(for: index["Ada Lovelace"]!).map(\.name) == ["birthday", "company", "status", "met"])
    }
}
