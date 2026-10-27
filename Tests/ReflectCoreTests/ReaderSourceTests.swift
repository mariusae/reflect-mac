import Foundation
import Testing
import ReflectCore
@testable import PrismCore

@Suite struct ReaderSourceTests {
    let note = """
    # Reading list

    - Two essays, and a paper
      - [How to Do Great Work](https://paulgraham.com/greatwork.html)
      - The paper: [paper.pdf](assets/paper.pdf), and a picture ![](assets/a.png)
      - And https://paulgraham.com/hwh.html, then [[Another note]], and https://paulgraham.com/greatwork.html again.
    """

    private func graph() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: root.appendingPathComponent("assets/paper.pdf"))
        return root
    }

    @Test func everyPageAndPDFInOrderOnce() throws {
        let sources = ReaderSource.all(in: note, root: try graph())
        #expect(sources.map(\.address) == ["https://paulgraham.com/greatwork.html", "assets/paper.pdf", "https://paulgraham.com/hwh.html"])
        #expect(sources.map(\.isPDF) == [false, true, false])
    }

    @Test func aLinkNotesOwnPageFirst() throws {
        let link = "# Page\n\n- See [elsewhere](https://example.com/b)\n- URL: <https://example.com/a>\n"
        #expect(ReaderSource.all(in: link, root: try graph()).map(\.address) == ["https://example.com/a", "https://example.com/b"])
    }

    @Test func aPDFNotThereOrOutsideAssetsIsNot() throws {
        let text = "- [gone](assets/gone.pdf) [out](assets/../secret.pdf) [elsewhere](/etc/x.pdf)"
        #expect(ReaderSource.all(in: text, root: try graph()).isEmpty)
    }

    @Test func highlightsGoUnderTheRowLinkingThere() {
        let once = WebCapture.highlighting("The second pass", in: note, of: "assets/paper.pdf")
        #expect(once.contains("  - The paper: [paper.pdf](assets/paper.pdf), and a picture ![](assets/a.png)\n    - The second pass\n"))
        #expect(WebCapture.highlighting("The second pass", in: once, of: "assets/paper.pdf") == once)
        #expect(WebCapture.highlights(in: once, of: "assets/paper.pdf") == ["The second pass"])
        #expect(WebCapture.highlights(in: once, of: "https://paulgraham.com/hwh.html").isEmpty)
    }
}
