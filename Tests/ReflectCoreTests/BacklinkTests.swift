import Foundation
import Testing
@testable import ReflectCore

/// Reflect's block-context cases (packages/core/src/indexing/block-context.test.ts),
/// as rows: each line is a row's depth in spaces, then its text.
@Suite struct BacklinkTests {
    func contexts(_ source: String, keys: Set<String> = ["target"]) -> [String] {
        Backlinks.contexts(in: OutlineMarkdown.parse(source), mentions: { keys.contains(Backlinks.key($0)) })
            .map { $0.rows.map { String(repeating: "  ", count: $0.depth) + $0.text }.joined(separator: "\n") }
    }

    @Test func paragraphs() {
        #expect(contexts("intro line\n\nfirst wrapped line with [[Target]]\nsecond wrapped line\n\nafter\n")
                == ["first wrapped line with [[Target]]\nsecond wrapped line"])
        #expect(contexts("---\ntitle: Note\n---\n\na paragraph with [[Target]] inside\n") == ["a paragraph with [[Target]] inside"])
        #expect(contexts("> quoted [[Target]] mention\n> second quoted line\n") == ["quoted [[Target]] mention\nsecond quoted line"])
    }

    @Test func headings() {
        let content = "# Title\n\nintro\n\n## Meeting [[Target]]\n\nnotes for the meeting\n\n- a bullet\n\n### Sub\n\nunrelated\n"
        #expect(contexts(content) == ["Meeting [[Target]]\nnotes for the meeting\na bullet"])
        #expect(contexts("## Heading [[Target]]\n\nlast paragraph\n") == ["Heading [[Target]]\nlast paragraph"])
        // The note's title: the heading alone.
        #expect(contexts("# Meeting with [[Target]]\n\nagenda item one\n\nagenda item two\n") == ["Meeting with [[Target]]"])
        #expect(contexts("# Title\n\nintro\n\n# Second [[Target]]\n\nsection body\n") == ["Second [[Target]]\nsection body"])
        #expect(contexts("---\ntitle: Custom\n---\n\n# Heading [[Target]]\n\nsection body\n") == ["Heading [[Target]]\nsection body"])
    }

    @Test func lists() {
        #expect(contexts("- kickoff with [[Target]]\n  - prep the agenda\n  - book the room\n- unrelated sibling\n")
                == ["kickoff with [[Target]]\n  prep the agenda\n  book the room"])
        #expect(contexts("- [[Target]] kickoff\n  + [ ] prep agenda\n  + [x] send invite\n")
                == ["[[Target]] kickoff\n  prep agenda\n  send invite"])
        #expect(contexts("- parent line\n  - mention of [[Target]]\n    - grandchild detail\n  - unrelated sibling\n")
                == ["parent line\n  mention of [[Target]]\n    grandchild detail"])
        // Branches that mention it come together, once.
        #expect(contexts("- parent line\n  - first [[Target]] mention\n  - also [[Target]] here\n  - nothing relevant\n")
                == ["parent line\n  first [[Target]] mention\n  also [[Target]] here"])
        #expect(contexts("- parent line\n  - one [[Project X]]\n  - two [[projx]]\n  - three [[Other Note]]\n", keys: ["project x", "projx"])
                == ["parent line\n  one [[Project X]]\n  two [[projx]]"])
        #expect(contexts("- parent line\n  - one [[Target]]\n  - two [[target]]\n") == ["parent line\n  one [[Target]]\n  two [[target]]"])
        // Reflect's case starts the nested list at 2, which strict CommonMark —
        // as this parser reads, to write notes back as they were — takes for
        // more of the parent's text; nested as CommonMark sees it:
        #expect(contexts("1. parent line\n   1. mention of [[Target]]\n   2. unrelated\n") == ["parent line\n  mention of [[Target]]"])
        #expect(contexts("- first paragraph\n\n  second [[Target]] paragraph\n") == ["first paragraph\n  second [[Target]] paragraph"])
        #expect(contexts("- top item\n  - middle item\n    - deep [[Target]] mention\n  - other branch\n")
                == ["middle item\n  deep [[Target]] mention"])
    }

    @Test func findsLinkingNotesNewestFirst() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("backlinks-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        for directory in ["notes", "daily", "templates"] {
            try manager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try write("notes/target.md", "---\naliases: [TG]\n---\n# Target\n\n- self [[Target]]\n")
        try write("notes/other.md", "# Other\n\n- about [[tg]] by alias\n- and [[Nothing]]\n")
        try write("daily/2026-09-01.md", "- met about [[Target]]\n")
        try write("daily/2026-09-03.md", "- again [[target]] and [[target]]\n")
        try write("templates/meeting.md", "- [[Target]]\n")
        try write("daily/2026-09-02.md", "- see [[2026-09-01]]\n")
        let index = NoteIndex(root: root)
        index.scan()
        let sources = index.backlinks(to: "notes/target.md")
        // Days by their day, newest first; notes by when written; no templates.
        let days = sources.map(\.path).filter { $0.hasPrefix("daily/") }
        #expect(days == ["daily/2026-09-03.md", "daily/2026-09-01.md"])
        #expect(Set(sources.map(\.path)) == ["daily/2026-09-03.md", "daily/2026-09-01.md", "notes/other.md", "notes/target.md"])
        #expect(sources.first { $0.path == "daily/2026-09-03.md" }?.contexts.count == 1)
        #expect(sources.first { $0.path == "notes/other.md" }?.contexts.map(\.link) == ["[[tg]]"])
        #expect(index.backlinks(to: "daily/2026-09-01.md").map(\.path) == ["daily/2026-09-02.md"])
    }
}
