import Foundation
import Testing
@testable import GraphKit

@Suite struct MarkdownTests {
    @Test func blocks() {
        let markdown = """
        # Title

        A paragraph
        on two lines.

        - one
          - two
        1. first
        - [x] done

        > [!TIP]
        > Use **this**.

        > plain quote

        ```swift
        let x = 1
        ```

        ```tiddlywiki
        <$list filter="[tag[x]]"/>
        ```

        | A | B |
        | --- | --- |
        | [[X\\|y]] | 2 |

        ![[Embedded]]

        ![cat](assets/cat.png)<!-- {"width":120} -->

        ---
        """
        #expect(MarkdownBlock.parse(markdown) == [
            .heading(level: 1, text: "Title"),
            .paragraph("A paragraph\non two lines."),
            .list([.init(depth: 0, ordered: false, text: "one"), .init(depth: 1, ordered: false, text: "two"),
                   .init(depth: 0, ordered: true, text: "first"), .init(depth: 0, ordered: false, checked: true, text: "done")]),
            .callout(kind: "tip", blocks: [.paragraph("Use **this**.")]),
            .quote([.paragraph("plain quote")]),
            .code(language: "swift", text: "let x = 1"),
            .wikiText("<$list filter=\"[tag[x]]\"/>"),
            .table(header: ["A", "B"], rows: [["[[X|y]]", "2"]]),
            .embed("Embedded"),
            .image(alt: "cat", source: "assets/cat.png", width: 120),
            .rule,
        ])
    }

    @Test func inlineLinks() {
        let prepared = InlineMarkdown.prepared("See [[Hello There]], [[Target|shown]] and `[[code]]`, <u>under</u>.")
        #expect(prepared == "See [Hello There](weft://open?title=Hello%20There), [shown](weft://open?title=Target) and `[[code]]`, under.")
        #expect(InlineMarkdown.prepared("An <<.icon x>> and <$link/>.") == "An `<<.icon x>>` and `<$link/>`.")
        #expect(InlineMarkdown.title(from: InlineMarkdown.url(for: "a & b/c?")) == "a & b/c?")
    }
}
