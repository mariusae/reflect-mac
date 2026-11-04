import Foundation
import ReflectCore
import Testing
@testable import GraphKit

@Suite struct UntitledTests {
    private func graph() throws -> (PageIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("untitled-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let wiki = PageIndex(root: root)
        try wiki.load()
        return (wiki, root)
    }

    private func file(_ path: String, in root: URL) -> String? {
        try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func names() {
        let name = Untitled.newName(at: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(Untitled.isName(name))
        #expect(Untitled.isPath("notes/\(name).md"))
        #expect(!Untitled.isPath("daily/\(name).md"))
        #expect(!Untitled.isName("untitled"))
        #expect(!Untitled.isName("untitled-2026-11-04-103122"))
        #expect(!Untitled.isName("Untitled-2026-11-04-103122-7f3a"))
        #expect(Untitled.isName("untitled-2026-11-04-103122-7f3a"))
        #expect(Assets.slug(name) == name)
        #expect(Untitled.date(of: name) == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func shownAsItsFirstLine() {
        #expect(Untitled.name(of: "") == nil)
        #expect(Untitled.name(of: "\n\n  \n") == nil)
        #expect(Untitled.name(of: "Groceries for the weekend\nmilk") == "Groceries for the weekend")
        #expect(Untitled.name(of: "# A heading\nmore") == "A heading")
        #expect(Untitled.name(of: "- [ ] Call **Ana** about [[Costa Rica|the trip]]") == "Call Ana about the trip")
        #expect(Untitled.name(of: "![](assets/a.png)\n\n---\nAfter the picture") == "After the picture")
        #expect(Untitled.name(of: "```\ncode\n```\nWords") == "Words")
        let long = String(repeating: "word ", count: 30)
        #expect(Untitled.name(of: long)!.count <= 60)
    }

    @Test func madeRetitledAndUntitledAgain() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = wiki.newUntitledName()
        // Made untitled: named by its file; its heading only words.
        try wiki.save(Page(title: name, text: "# Not a title\n\nJust jotting.\n"))
        let path = "notes/\(name).md"
        #expect(file(path, in: root) == "# Not a title\n\nJust jotting.\n")
        #expect(wiki[name]?.text == "# Not a title\n\nJust jotting.\n")
        #expect(wiki.shown(name) == "Not a title")
        #expect(wiki.entries[name]?.isUntitled == true)
        #expect(wiki.search("not a ti").first == name)
        #expect(wiki.title(for: name) == name)
        // Linked to by its name.
        try wiki.save(Page(title: "Elsewhere", text: "See [[\(name)]].\n"))
        #expect(wiki.backlinks(to: name) == ["Elsewhere"])

        // Read again from its file, the same.
        let fresh = PageIndex(root: root)
        try fresh.load()
        #expect(fresh[name]?.text == "# Not a title\n\nJust jotting.\n")
        #expect(fresh.shown(name) == "Not a title")

        // Given a title: to the file it names, headed by it; linked to by it.
        var page = wiki[name]!
        page.title = "Weekend Plans"
        try wiki.save(page, replacing: name)
        try wiki.relink(from: name, to: "Weekend Plans")
        #expect(file(path, in: root) == nil)
        #expect(file("notes/weekend-plans.md", in: root) == "# Weekend Plans\n\n# Not a title\n\nJust jotting.\n")
        #expect(wiki["Weekend Plans"]?.text == "# Not a title\n\nJust jotting.\n")
        #expect(wiki.entries["Weekend Plans"]?.isUntitled == false)
        #expect(wiki["Elsewhere"]?.text == "See [[Weekend Plans]].\n")

        // Its title taken away: untitled again, under a new name.
        page = wiki["Weekend Plans"]!
        let again = wiki.newUntitledName()
        page.title = again
        try wiki.save(page, replacing: "Weekend Plans")
        try wiki.relink(from: "Weekend Plans", to: again)
        #expect(file("notes/weekend-plans.md", in: root) == nil)
        #expect(file("notes/\(again).md", in: root) == "# Not a title\n\nJust jotting.\n")
        #expect(wiki.shown(again) == "Not a title")
        #expect(wiki["Elsewhere"]?.text == "See [[\(again)]].\n")
    }

    @Test func titledAsAnotherFileIsNamedKeepsBoth() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data("# Plans\n".utf8).write(to: root.appendingPathComponent("notes/plans.md"))
        try wiki.load()
        let name = wiki.newUntitledName()
        try wiki.save(Page(title: name, id: "01abc", tags: ["Jot"], text: "Plans, again\n"))
        var page = wiki[name]!
        page.title = "plans!"
        try wiki.save(page, replacing: name)
        #expect(file("notes/plans.md", in: root) == "# Plans\n")
        #expect(file("notes/plans-2.md", in: root) == "---\nid: 01abc\ntags: [Jot]\n---\n# plans!\n\nPlans, again\n")
    }

    @Test func frontmatterEmptiedGoes() {
        var page = PageFile.read("---\nid: 01abc\n---\nWords\n", fallbackTitle: "x")
        page.id = nil
        #expect(PageFile.write(page, over: "---\nid: 01abc\n---\nWords\n", fallbackTitle: "x") == "Words\n")
        // An empty one written so, left so.
        #expect(PageFile.write(PageFile.read("---\n---\nWords\n", fallbackTitle: "x"), over: "---\n---\nWords\n", fallbackTitle: "x") == "---\n---\nWords\n")
    }

    @Test func untitledKeepsItsFrontmatter() throws {
        let (wiki, root) = try graph()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = wiki.newUntitledName()
        try wiki.save(Page(title: name, id: "01xyz", tags: ["Inbox"], fields: [.init("wiki", .text("true"))], text: "Words\n"))
        #expect(file("notes/\(name).md", in: root) == "---\nid: 01xyz\ntags: [Inbox]\nwiki: true\n---\nWords\n")
        var page = wiki[name]!
        page.title = "Named"
        try wiki.save(page, replacing: name)
        page = wiki["Named"]!
        page.title = wiki.newUntitledName()
        try wiki.save(page, replacing: "Named")
        #expect(file("notes/\(page.title).md", in: root) == "---\nid: 01xyz\ntags: [Inbox]\nwiki: true\n---\nWords\n")
    }
}
