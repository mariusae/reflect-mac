import Foundation
import Testing
import ReflectCore

@Suite struct MentionsTests {
    @Test func wholeWordsOutsideLinksAndCode() {
        let text = "Lunch with Ana Lima, not Anatomy; see [[Ana Lima]] and `Ana Lima` there"
        let found = Mentions.ranges(of: ["Ana Lima"], in: text).map { (text as NSString).substring(with: $0) }
        #expect(found == ["Ana Lima"])
        #expect(Mentions.ranges(of: ["Ana"], in: "Anatomy, banana").isEmpty)
    }

    @Test func mentionsAreMadeLinks() {
        let source = "# Monday\n\n- Lunch with ana lima\n- Ana Lima again, and [[Ana Lima]]\n"
        let linked = Mentions.linking(["Ana Lima"], to: "Ana Lima", in: source)
        #expect(linked == "# Monday\n\n- Lunch with [[Ana Lima|ana lima]]\n- [[Ana Lima]] again, and [[Ana Lima]]\n")
        #expect(Mentions.linking(["Ana Lima"], to: "Ana Lima", in: linked!) == nil)
    }

    @Test func notesThatNameANoteAreFound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Ana Lima\n".write(to: root.appendingPathComponent("notes/ana.md"), atomically: true, encoding: .utf8)
        try "# Plans\n\n- Call Ana Lima\n".write(to: root.appendingPathComponent("notes/plans.md"), atomically: true, encoding: .utf8)
        try "# Met\n\n- With [[Ana Lima]]\n".write(to: root.appendingPathComponent("notes/met.md"), atomically: true, encoding: .utf8)
        let index = NoteIndex(root: root)
        index.scan()
        #expect(index.mentions(of: "notes/ana.md") == ["notes/plans.md"])
    }
}
