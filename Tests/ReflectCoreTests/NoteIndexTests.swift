import Foundation
import Testing
@testable import ReflectCore

@Suite struct NoteIndexTests {
    @Test func titlesAsReflectDerivesThem() {
        #expect(NoteIndex.entry(path: "notes/a.md", source: "---\ntitle: \"Project #1\"\n---\n# Ignored\n").title == "Project #1")
        #expect(NoteIndex.entry(path: "notes/a.md", source: "- intro\n\n# Launch Review\n").title == "Launch Review")
        #expect(NoteIndex.entry(path: "notes/meeting-notes.md", source: "- x\n").title == "meeting-notes")
        #expect(NoteIndex.entry(path: "daily/2026-09-25.md", source: "- x\n").title == "2026-09-25")
        let entry = NoteIndex.entry(path: "notes/a.md", source: "---\naliases:\n  - Old Name\n  - pjx\n---\n# Apex // Design\n")
        #expect(entry.aliases == ["Old Name", "pjx", "Apex", "Design"])
        #expect(NoteIndex.entry(path: "notes/b.md", source: "---\naliases: [A, \"B c\"]\nprivate: true\n---\n").aliases == ["A", "B c"])
        #expect(NoteIndex.entry(path: "notes/b.md", source: "---\nprivate: yes\n---\n").isPrivate)
    }

    @Test func linksResolveByDateThenTitleThenAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("index-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("# Apex\n".utf8).write(to: root.appendingPathComponent("notes/apex.md"))
        try Data("---\naliases: [apex design]\n---\n# Design Doc\n".utf8).write(to: root.appendingPathComponent("notes/design.md"))
        let index = NoteIndex(root: root)
        index.scan()
        #expect(index.resolve("  APEX ") == "notes/apex.md")
        #expect(index.resolve("Apex Design") == "notes/design.md")
        #expect(index.resolve("2026-09-25") == "daily/2026-09-25.md")
        #expect(index.resolve("nothing") == nil)
        #expect(index.matches("des").first?.entry.path == "notes/design.md")
        #expect(index.matches("dd").first?.entry.path == "notes/design.md")
        #expect(index.containing("design doc").map(\.path) == ["notes/design.md"])
    }

    @Test func namesRankWholeThenStartThenWords() {
        #expect(NoteIndex.score("apex", "apex")! > NoteIndex.score("apex design", "apex")!)
        #expect(NoteIndex.score("apex design", "apex")! > NoteIndex.score("the apex", "apex")!)
        #expect(NoteIndex.score("the apex design", "apex des")! > NoteIndex.score("capexdes", "apex des") ?? 0)
        #expect(NoteIndex.score("abc", "xyz") == nil)
        #expect(NoteIndex.score("design doc", "dd") != nil)
        #expect(NoteIndex.score("apex design", "apdes") != nil)
        #expect(NoteIndex.score("may 2023 ipnext capacity workshop", "apex") == nil)
    }

    @Test func newNotesAreMadeAsReflectMakesThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("create-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try NoteCreation.create(title: "Weekly Plan", in: root) == "notes/weekly-plan.md")
        #expect(try NoteCreation.create(title: "Weekly Plan", in: root) == "notes/weekly-plan-2.md")
        let text = try String(contentsOf: root.appendingPathComponent("notes/weekly-plan.md"), encoding: .utf8)
        #expect(text.hasPrefix("---\nid: ") && text.hasSuffix("\n---\n# Weekly Plan\n"))
        let id = NoteCreation.ulid()
        #expect(id.count == 26 && id == id.lowercased())
        #expect(NoteIndex.entry(path: "notes/weekly-plan.md", source: text).title == "Weekly Plan")
    }

    @Test func reflectsOwnIndexWhenThere() {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_GRAPH"],
              let index = ReflectSearchIndex(root: URL(fileURLWithPath: path)) else { return }
        let hits = index.search("apex")
        print("FTS hits: \(hits.prefix(3).map { "\($0.title): \($0.snippet)" })")
        #expect(!hits.isEmpty)
    }
}

@Suite struct NoteIndexScale {
    @Test func scansARealGraph() {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_GRAPH"] else { return }
        let index = NoteIndex(root: URL(fileURLWithPath: path))
        let start = Date()
        index.scan()
        let scanned = Date().timeIntervalSince(start)
        let found = Date()
        let matches = index.matches("apex")
        print(String(format: "scan %.0f ms, %d notes; match %.1f ms: %@", scanned * 1000, index.all.count,
                     Date().timeIntervalSince(found) * 1000, matches.prefix(4).map(\.entry.title).description))
    }
}
