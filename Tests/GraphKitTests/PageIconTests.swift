import AppKit
import Foundation
import Testing
@testable import GraphKit
import ReflectCore

@Suite struct PageIconTests {
    /// Every icon offered is a symbol there is, offered once, with a name.
    @Test func everyChoiceIsASymbol() {
        let symbols = PageIcon.all.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        for choice in PageIcon.all {
            #expect(NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil) != nil, "\(choice.symbol)")
            #expect(!choice.name.isEmpty)
        }
        #expect(PageIcon.name(of: "leaf") == "Leaf")
        #expect(PageIcon.name(of: "custom.symbol") == "custom.symbol")
    }

    /// Kept in the frontmatter as `icon:`; none, when it is empty.
    @Test func readFromItsFrontmatter() {
        #expect(PageIcon.symbol(of: PageFile.read("---\nicon: leaf\n---\nWords\n", fallbackTitle: "x")) == "leaf")
        #expect(PageIcon.symbol(of: PageFile.read("---\nicon: \"\"\n---\nWords\n", fallbackTitle: "x")) == nil)
        #expect(PageIcon.symbol(of: PageFile.read("Words\n", fallbackTitle: "x")) == nil)
        var page = PageFile.read("Words\n", fallbackTitle: "x")
        page[field: PageIcon.key] = .text("star")
        #expect(PageFile.write(page, over: "Words\n", fallbackTitle: "x") == "---\nicon: star\n---\nWords\n")
    }

    /// Prism's index has each note's icon, and finds a link's by its title,
    /// an alias, or a day — again once the note changes.
    @Test func theIndexKnowsEachNotesIcon() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes"), daily = root.appendingPathComponent("daily")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        try "---\nicon: leaf\naliases: [Yard]\n---\n# Garden\n".write(to: notes.appendingPathComponent("garden.md"), atomically: true, encoding: .utf8)
        try "# Plain\n".write(to: notes.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)
        try "---\nicon: star\n---\n- A good day\n".write(to: daily.appendingPathComponent("2026-11-04.md"), atomically: true, encoding: .utf8)
        let index = NoteIndex(root: root)
        index.scan()
        #expect(index.entry("notes/garden.md")?.icon == "leaf")
        #expect(index.icon(of: "garden") == "leaf")
        #expect(index.icon(of: " Yard ") == "leaf")
        #expect(index.icon(of: "Plain") == nil)
        #expect(index.icon(of: "2026-11-04") == "star")
        #expect(index.icon(of: "Nowhere") == nil)
        try "---\nicon: bolt\n---\n# Plain\n".write(to: notes.appendingPathComponent("plain.md"), atomically: true, encoding: .utf8)
        index.refresh("notes/plain.md")
        #expect(index.icon(of: "Plain") == "bolt")
    }
}
