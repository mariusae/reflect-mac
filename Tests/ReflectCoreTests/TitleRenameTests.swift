import Foundation
import Testing
@testable import ReflectCore

/// Reflect's rename cases (packages/core/src/markdown/retitle.test.ts and
/// indexing/rename.test.ts), and the whole of a rename across a graph.
@Suite struct TitleRenameTests {
    func repoint(_ source: String, _ fromKey: String, _ to: String) -> String {
        TitleRename.retitleLinks(in: source, repoint: (fromKey, to), display: nil, subjectKeys: [])
    }

    @Test func rewritesLinks() {
        #expect(repoint("[[Foo]] and [[foo|bar]] and `[[Foo]]` and [[Other]]", "foo", "Baz")
                == "[[Baz]] and [[Baz|bar]] and `[[Foo]]` and [[Other]]")
        let unchanged = "see [[Alpha]] and [[Beta]]"
        #expect(repoint(unchanged, "gamma", "Delta") == unchanged)
        #expect(repoint("[[ Foo ]] and [[Foo]] and [[ foo|bar]]", "foo", "Baz") == "[[Baz]] and [[Baz]] and [[Baz|bar]]")
        #expect(repoint("[[Foo| bar ]]", "foo", "Baz") == "[[Baz| bar ]]")
        // Not in a fenced block.
        #expect(repoint("- [[Foo]]\n```\n[[Foo]]\n```\n", "foo", "Baz") == "- [[Baz]]\n```\n[[Foo]]\n```\n")
    }

    @Test func syncsDisplays() {
        let display = (from: "Old Title", to: "New Title")
        #expect(TitleRename.retitleLinks(in: "[[stable|Old Title]] [[stable|Mum]] [[stable|old title]] [[stable]]",
                                         repoint: nil, display: display, subjectKeys: ["stable"])
                == "[[stable|New Title]] [[stable|Mum]] [[stable|old title]] [[stable]]")
        #expect(TitleRename.retitleLinks(in: "[[other|Old Title]]", repoint: nil, display: display, subjectKeys: ["stable"])
                == "[[other|Old Title]]")
        #expect(TitleRename.retitleLinks(in: "[[Old Title]] and [[stable|Old Title]]\n", repoint: ("old title", "New Title"),
                                         display: display, subjectKeys: ["old title", "stable"])
                == "[[New Title]] and [[stable|New Title]]\n")
    }

    @Test func keepsOldTitlesAsAliases() {
        #expect(TitleRename.nextAliases(["First", "keeper"], from: "Second", to: "Third", previousAutoAliases: ["First"]) == ["keeper", "Second"])
        #expect(TitleRename.nextAliases(["old title"], from: "Old Title", to: "New", previousAutoAliases: []) == nil)
        #expect(TitleRename.nextAliases([], from: "Same", to: "same", previousAutoAliases: []) == nil)
        #expect(TitleRename.nextAliases([], from: "Old", to: "New", previousAutoAliases: []) == ["Old"])
        #expect(TitleRename.nextAliases([], from: "Tim MacCaw // Dad", to: "Timothy MacCaw // Dad", previousAutoAliases: [])
                == ["Tim MacCaw", "Tim MacCaw // Dad"])
        #expect(TitleRename.nextAliases([], from: "Tim MacCaw // Dad", to: "Tim MacCaw", previousAutoAliases: [])
                == ["Dad", "Tim MacCaw // Dad"])
        #expect(TitleRename.nextAliases(["Dad", "Tim MacCaw // Dad", "keeper"], from: "Tim MacCaw // Da", to: "Tim MacCaw // D",
                                        previousAutoAliases: ["Dad", "Tim MacCaw // Dad"]) == ["keeper", "Da", "Tim MacCaw // Da"])
        #expect(TitleRename.nextAliases(["DAD", "keeper"], from: "Bob", to: "Carol", previousAutoAliases: ["Dad"]) == ["DAD", "keeper", "Bob"])
        let first = TitleRename.nextAliases(["Dad"], from: "Tim // Dad", to: "Tim // Father", previousAutoAliases: [])
        #expect(first == ["Dad", "Tim // Dad"])
        #expect(TitleRename.nextAliases(first ?? [], from: "Tim // Father", to: "Tim // Pa", previousAutoAliases: ["Tim // Dad"])
                == ["Dad", "Father", "Tim // Father"])
    }

    @Test func writesAliasLists() {
        let note = "---\nid: 01abc\ntitle: T\n---\n# T\n"
        let written = Frontmatter.setting("aliases", toList: ["Old", "Tim: Dad", "yes"], in: note)
        #expect(written == "---\nid: 01abc\ntitle: T\naliases:\n  - Old\n  - \"Tim: Dad\"\n  - \"yes\"\n---\n# T\n")
        #expect(Frontmatter(raw: "aliases:\n  - Old\n  - \"Tim: Dad\"").list("aliases") == ["Old", "Tim: Dad"])
        #expect(Frontmatter.setting("aliases", toList: [], in: written) == note)
    }

    @Test func knowsManagedNotes() {
        #expect(TitleRename.isManaged(path: "notes/a.md", source: "---\nid: 01k5m2x7yzq4hj8cd9ef6gtvwb\n---\n# A\n"))
        #expect(!TitleRename.isManaged(path: "notes/a.md", source: "---\nid: \"258be6d9b3d348debe9ae5e3584b5662\"\n---\n# A\n"))
        #expect(!TitleRename.isManaged(path: "notes/sub/a.md", source: "---\nid: 01k5m2x7yzq4hj8cd9ef6gtvwb\n---\n"))
        #expect(!TitleRename.isManaged(path: "daily/2026-01-01.md", source: "---\nid: 01k5m2x7yzq4hj8cd9ef6gtvwb\n---\n"))
        #expect(TitleRename.authoredTitle(path: "notes/a.md", source: "# Heading\n") == "Heading")
        #expect(TitleRename.authoredTitle(path: "notes/a.md", source: "---\ntitle: Named\n---\n# Heading\n") == "Named")
        #expect(TitleRename.authoredTitle(path: "notes/a.md", source: "- just a bullet\n") == nil)
    }

    @Test func blankNotesHaveAnEmptyTitle() {
        let blank = "---\nid: 01k5m2x7yzq4hj8cd9ef6gtvwb\n---\n# \n"
        let outline = OutlineMarkdown.parse(blank)
        #expect(outline.rows.map(\.kind) == [.heading(1)])
        #expect(OutlineMarkdown.serialize(outline) == blank)
        #expect(TitleRename.authoredTitle(path: "notes/x.md", source: blank) == nil)
        #expect(Backlinks.isEmpty(outline.rows))
    }

    @Test func renamesAcrossAGraph() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("rename-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        for directory in ["notes", "daily"] {
            try manager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        func write(_ text: String, _ path: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        func read(_ path: String) -> String? { try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }
        try write("---\nid: x\n---\n# New Name\n", "notes/subject.md")
        try write("- met [[Old Name]] and [[old name|Old Name]] and [[Other]]\n", "daily/2026-01-01.md")
        try write("- untouched [[Something]]\n", "daily/2026-01-02.md")
        try write("# Other\n", "notes/other.md")
        let index = NoteIndex(root: root)
        index.scan()
        let result = index.retitleLinks(to: "notes/subject.md", from: "Old Name", to: "New Name", read: read, write: write)
        #expect(!result.collision && !result.destinationBlocked)
        #expect(result.rewritten == ["daily/2026-01-01.md"])
        #expect(read("daily/2026-01-01.md") == "- met [[New Name]] and [[New Name|New Name]] and [[Other]]\n")
        #expect(read("daily/2026-01-02.md") == "- untouched [[Something]]\n")

        // The old name another note's now: its links stay.
        try write("- about [[Taken]]\n", "daily/2026-01-03.md")
        try write("# Taken\n", "notes/taken.md")
        index.scan()
        let taken = index.retitleLinks(to: "notes/subject.md", from: "Taken", to: "New Name", read: read, write: write)
        #expect(taken.collision)
        #expect(read("daily/2026-01-03.md") == "- about [[Taken]]\n")

        // The new name another note's: nothing repointed.
        try write("- about [[Was]]\n", "daily/2026-01-04.md")
        index.scan()
        let blocked = index.retitleLinks(to: "notes/subject.md", from: "Was", to: "Other", read: read, write: write)
        #expect(blocked.destinationBlocked)
        #expect(read("daily/2026-01-04.md") == "- about [[Was]]\n")

        // Where a managed note moves: its slug, or the next free one.
        #expect(index.managedPath(for: "New Name", current: "notes/subject.md") == "notes/new-name.md")
        #expect(index.managedPath(for: "Other", current: "notes/subject.md") == "notes/other-2.md")
        #expect(index.managedPath(for: "Subject", current: "notes/subject.md") == "notes/subject.md")
    }
}
