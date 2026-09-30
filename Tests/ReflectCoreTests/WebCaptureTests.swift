import Foundation
import Testing
@testable import ReflectCore

@Suite struct WebCaptureTests {
    let page = WebCapture.Page(url: "https://www.usenix.org/conference/osdi23/presentation/eriksen",
                               title: "Global Capacity Management With Flux | USENIX",
                               description: "A paper\non Flux.", highlights: ["First passage", "  Second\n\n passage  "],
                               screenshot: "assets/screenshot.png")

    @Test func theIdIsReflects() {
        // As Reflect wrote it for this page.
        #expect(WebCapture.id(for: page.url) == "link-ca743bd42c24825debdeb152ba375e69d0e281ccdbede0bf75a891e1710b7a92")
    }

    @Test func aNewNoteIsWrittenAsReflectWritesOne() {
        let note = WebCapture.note(for: page)
        #expect(note == """
        ---
        id: "link-ca743bd42c24825debdeb152ba375e69d0e281ccdbede0bf75a891e1710b7a92"
        ---

        # Global Capacity Management With Flux ｜ USENIX

        - URL: <https://www.usenix.org/conference/osdi23/presentation/eriksen>
        - Description: A paper on Flux.
        - Type: #link
        - Screenshot
          - ![](assets/screenshot.png)
        - Highlights
          - First passage
          - Second
            passage

        """)
        let entry = NoteIndex.entry(path: "notes/x.md", source: note)
        #expect(entry.title == "Global Capacity Management With Flux ｜ USENIX")
    }

    @Test func capturedAgainTheNoteTakesInWhatIsNew() {
        let first = WebCapture.note(for: WebCapture.Page(url: page.url, title: page.title, highlights: ["First passage"]))
        let merged = WebCapture.merging(page, into: first)
        #expect(merged.contains("- Description: A paper on Flux."))
        #expect(merged.components(separatedBy: "First passage").count == 2)
        #expect(merged.contains("  - Second\n    passage"))
        #expect(merged.contains("- Screenshot\n  - ![](assets/screenshot.png)\n- Highlights"))
        // Nothing new: nothing changes.
        #expect(WebCapture.merging(page, into: merged) == merged)
    }

    @Test func theDayLinksToItUnderLinks() {
        #expect(WebCapture.linking("Page", fromDay: "") == "- [[Links]]\n  - [[Page]]\n")
        let day = "- morning\n- [[Links]]\n  - [[Other]]\n- evening\n"
        let linked = WebCapture.linking("Page", fromDay: day)
        #expect(linked == "- morning\n- [[Links]]\n  - [[Other]]\n  - [[Page]]\n- evening\n")
        #expect(WebCapture.linking("Page", fromDay: linked) == linked)
    }

    @Test func titlesAreSafeToLinkTo() {
        #expect(WebCapture.title("[WIP] A | B\n  C", url: "https://x.com") == "(WIP) A ｜ B C")
        #expect(WebCapture.title("  ", url: "https://example.com/a") == "example.com")
    }

    @Test func savingWritesTheNoteAndTheDayAndFindsItAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        let graph = Graph(root: root, git: nil)
        let index = NoteIndex(root: root)
        index.scan()
        let day = Day(year: 2026, month: 9, day: 30)
        let path = try WebCapture.save(WebCapture.Page(url: page.url, title: page.title, highlights: ["One"]), in: graph, index: index, on: day)
        #expect(path == "notes/global-capacity-management-with-flux-usenix.md")
        #expect(graph.read(day) == "- [[Links]]\n  - [[Global Capacity Management With Flux ｜ USENIX]]\n")
        // Again, with more: the same note.
        let again = try WebCapture.save(WebCapture.Page(url: page.url, title: "Renamed", highlights: ["One", "Two"]), in: graph, index: index, on: day)
        #expect(again == path)
        #expect(graph.read(path: path)?.contains("  - One\n  - Two\n") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("notes").path).count == 1)
    }
}
