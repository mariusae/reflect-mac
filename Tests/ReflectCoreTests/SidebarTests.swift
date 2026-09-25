import Foundation
import Testing
@testable import ReflectCore

@Suite struct SidebarTests {
    @Test func readsPinsAsReflectDoes() {
        #expect(NoteIndex.pin("true") == .unordered)
        #expect(NoteIndex.pin("Yes") == .unordered)
        #expect(NoteIndex.pin("2048") == .order(2048))
        #expect(NoteIndex.pin("0") == .order(0))
        #expect(NoteIndex.pin("false") == nil)
        #expect(NoteIndex.pin("maybe") == nil)
        #expect(NoteIndex.pin(nil) == nil)
        let entry = NoteIndex.entry(path: "notes/a.md", source: "---\nid: x\npinned: 3072\n---\n# A\n")
        #expect(entry.pin == .order(3072))
    }

    @Test func findsTagsOutsideCodeAndLinks() {
        let body = """
            - Planning #Work and #work/q3, #café
            - `#notatag` and [#nor](https://x.com/#this) nor a#b
            ```
            #fenced
            ```
            # Heading is not a tag
            - #idea-2 at the end #Idea-2
            """
        #expect(NoteIndex.tags(in: body) == ["Work", "work/q3", "café", "idea-2"])
    }

    @Test func setsFrontmatterKeys() {
        let plain = "# Title\n\n- body\n"
        let pinned = Frontmatter.setting("pinned", to: "1024", in: plain)
        #expect(pinned == "---\npinned: 1024\n---\n# Title\n\n- body\n")
        // Back out again: nothing left, so no frontmatter either.
        #expect(Frontmatter.setting("pinned", to: nil, in: pinned) == plain)

        let withID = "---\nid: 01abc\naliases:\n  - One\n  - Two\ntitle: T\n---\nbody\n"
        #expect(Frontmatter.setting("pinned", to: "true", in: withID)
                == "---\nid: 01abc\naliases:\n  - One\n  - Two\ntitle: T\npinned: true\n---\nbody\n")
        #expect(Frontmatter.setting("aliases", to: nil, in: withID) == "---\nid: 01abc\ntitle: T\n---\nbody\n")
        #expect(Frontmatter.setting("title", to: "U", in: withID) == "---\nid: 01abc\naliases:\n  - One\n  - Two\ntitle: U\n---\nbody\n")
        #expect(Frontmatter.setting("missing", to: nil, in: withID) == withID)
    }

    @Test func ordersThePinnedShelf() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("pins-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        for (name, front) in [("b", "pinned: true"), ("a", "pinned: true"), ("c", "pinned: 2048"), ("d", "pinned: 1024"), ("e", "id: x")] {
            try "---\n\(front)\n---\n# \(name.uppercased())\n\n- #shared and #\(name)\n"
                .write(to: root.appendingPathComponent("notes/\(name).md"), atomically: true, encoding: .utf8)
        }
        let index = NoteIndex(root: root)
        index.scan()
        #expect(index.pinned.map(\.title) == ["D", "C", "A", "B"])
        #expect(index.nextPinOrder == 3072)
        #expect(index.tags.map(\.name) == ["a", "b", "c", "d", "e", "shared"])
        #expect(index.tags.first { $0.name == "shared" }?.count == 5)
        #expect(Set(index.notes(tagged: "SHARED").map(\.title)) == ["A", "B", "C", "D", "E"])
    }

    @Test func readsTheRealGraphsShelf() throws {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_GRAPH"] else { return }
        let index = NoteIndex(root: URL(fileURLWithPath: path))
        index.scan()
        #expect(index.pinned.count == 18)
        print("pinned:", index.pinned.map(\.title).joined(separator: " · "))
        print("tags:", index.tags.prefix(30).map { "\($0.name) (\($0.count))" }.joined(separator: " · "))
    }
}

@Suite struct PinOrderTests {
    func shelf(_ orders: [Int?]) -> [PinOrder.Pin] {
        orders.enumerated().map { PinOrder.Pin(path: "n\($0)", order: $1) }
    }

    @Test func movesBetweenNeighbours() {
        // n3 to the top: halfway to the first.
        #expect(PinOrder.move(shelf([1024, 2048, 3072, 4096]), from: 3, to: 0) == [.init(path: "n3", order: 512)])
        // n0 between n2 and n3.
        #expect(PinOrder.move(shelf([1024, 2048, 3072, 4096]), from: 0, to: 2) == [.init(path: "n0", order: 3584)])
        // n0 to the bottom: a fresh gap past the last.
        #expect(PinOrder.move(shelf([1024, 2048, 3072]), from: 0, to: 2) == [.init(path: "n0", order: 4096)])
    }

    @Test func numbersAfreshWhenNothingFits() {
        // No whole number between 1 and 2: the whole shelf, 1024 apart.
        let changed = PinOrder.move(shelf([1, 2, 3]), from: 2, to: 1)
        #expect(changed == [.init(path: "n0", order: 1024), .init(path: "n2", order: 2048), .init(path: "n1", order: 3072)])
    }

    @Test func numbersUnnumberedPins() {
        // `pinned: true` notes have no number: moving among them numbers the shelf.
        let changed = PinOrder.move(shelf([1024, nil, nil]), from: 2, to: 1)
        #expect(changed == [.init(path: "n2", order: 2048), .init(path: "n1", order: 3072)])
        #expect(PinOrder.order(.order(2048)) == 2048)
        #expect(PinOrder.order(.order(1.5)) == nil)
        #expect(PinOrder.order(.unordered) == nil)
        #expect(PinOrder.move(shelf([1024]), from: 0, to: 0).isEmpty)
    }
}
