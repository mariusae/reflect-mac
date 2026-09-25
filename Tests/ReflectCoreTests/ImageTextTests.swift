import Foundation
import Testing
@testable import ReflectCore

@Suite struct ImageTextTests {
    @Test func findsPicturesByTheirText() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("pictures-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        try manager.createDirectory(at: assets, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("daily"), withIntermediateDirectories: true)
        try Data("png".utf8).write(to: assets.appendingPathComponent("chart.png"))
        try Data("png".utf8).write(to: assets.appendingPathComponent("My Shot.png"))
        try Data("pdf".utf8).write(to: assets.appendingPathComponent("paper.pdf"))
        // Reflect's description of a picture is its text.
        try "---\nreflectAsset: true\nsourceHash: abc\n---\nA bar chart of **Quarterly Revenue**.\n"
            .write(to: assets.appendingPathComponent("chart.png.reflect.md"), atomically: true, encoding: .utf8)
        try "- ![](assets/chart.png)\n".write(to: root.appendingPathComponent("daily/2026-09-01.md"), atomically: true, encoding: .utf8)
        try "- ![](assets/My%20Shot.png)\n".write(to: root.appendingPathComponent("daily/2026-09-02.md"), atomically: true, encoding: .utf8)

        let cache = root.appendingPathComponent("cache")
        let pictures = ImageTextIndex(root: root, cache: cache)
        let pending = pictures.refresh()
        // Only the picture with no description is to be read; not the PDF.
        #expect(pending.map(\.path) == ["assets/My Shot.png"])
        #expect(pictures.text("assets/chart.png") == "A bar chart of **Quarterly Revenue**.")
        pictures.store("Error: connection refused\nretrying", for: pending[0])

        let hits = pictures.search("connection REFUSED")
        #expect(hits.map(\.path) == ["assets/My Shot.png"])
        #expect(hits.first?.snippet == "Error: \u{1}connection\u{2} \u{1}refused\u{2} retrying")
        #expect(pictures.search("quarterly").map(\.path) == ["assets/chart.png"])
        #expect(pictures.search("nowhere").isEmpty)

        // Read once, kept: a new index finds nothing left to read.
        let again = ImageTextIndex(root: root, cache: cache)
        #expect(again.refresh().isEmpty)
        #expect(again.text("assets/My Shot.png") == "Error: connection refused\nretrying")

        let notes = NoteIndex(root: root)
        notes.scan()
        #expect(notes.notes(showing: "assets/My Shot.png") == ["daily/2026-09-02.md"])
        #expect(notes.notes(showing: "assets/chart.png") == ["daily/2026-09-01.md"])
    }
}
