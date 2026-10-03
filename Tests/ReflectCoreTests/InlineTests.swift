import Foundation
import Testing
@testable import ReflectCore

private func spans(_ text: String) -> [InlineSpan] {
    InlineMarkup.spans(in: text as NSString, range: NSRange(location: 0, length: (text as NSString).length))
}

/// The text with its hidden markup taken out: what is on screen.
private func shown(_ text: String) -> String {
    let string = text as NSString
    var result = ""
    var location = 0
    for run in InlineMarkup.hiddenRuns(in: string, range: NSRange(location: 0, length: string.length)) {
        result += string.substring(with: NSRange(location: location, length: run.location - location))
        location = NSMaxRange(run)
    }
    return result + string.substring(from: location)
}

@Suite struct InlineMarkupTests {
    @Test func hidesMarkup() {
        #expect(shown("a **bold** b") == "a bold b")
        #expect(shown("an *em* and _em_") == "an em and em")
        #expect(shown("~~gone~~ `x`") == "gone x")
        #expect(shown("[text](https://a.b/c_d_e)") == "text")
        #expect(shown("[[Some Note]] and [[target|label]]") == "Some Note and label")
        #expect(shown("<https://a.b> x<!-- {\"w\":1} -->") == "https://a.b x")
        #expect(shown("**bold [link](u) more**") == "bold link more")
    }

    @Test func anAddressInALinkIsTheLink() {
        // One link, not a link and an address inside it: one pill.
        #expect(spans("URL: <https://anthropic.com/research/x>").map(\.kind) == [.link("https://anthropic.com/research/x")])
        #expect(spans("[https://a.b/c](https://a.b/c)").map(\.kind) == [.link("https://a.b/c")])
        #expect(spans("see https://a.b/c").map(\.kind) == [.url("https://a.b/c")])
    }

    @Test func leavesWhatIsNotMarkup() {
        #expect(shown("https://x.com/a_b_c_d") == "https://x.com/a_b_c_d")
        #expect(shown("`**not bold**`") == "**not bold**")
        #expect(shown("2 * 3 * 4") == "2 * 3 * 4")
        #expect(shown("snake_case_name") == "snake_case_name")
        #expect(shown("#tag") == "#tag")
    }

    @Test func imagesAreHiddenWholeWithTheirSize() {
        #expect(shown("a ![alt](assets/x.png)<!-- {\"width\":425,\"height\":270} --> b") == "a  b")
        #expect(spans("![](assets/x.png)<!-- {\"height\":211} -->").first?.kind
                == .image(ImageReference(source: "assets/x.png", height: 211)))
        #expect(spans("![A b](https://x/y.jpg)").first?.kind == .image(ImageReference(source: "https://x/y.jpg", alt: "A b")))
    }

    @Test func imagesAreOneStepAndOneDelete() {
        let text = "a ![](i.png)<!-- {\"width\":1} --> b" as NSString
        let all = NSRange(location: 0, length: text.length)
        let found = InlineMarkup.spans(in: text, range: all)
        let image = found.first(where: \.isImage)!.range
        #expect(InlineEditing.step(from: 2, forward: true, text: text, within: all, spans: found) == NSMaxRange(image))
        #expect(InlineEditing.step(from: NSMaxRange(image), forward: false, text: text, within: all, spans: found) == 2)
        #expect(InlineEditing.deletion(at: NSMaxRange(image), forward: false, text: text, within: all, spans: found) == image)
        #expect(InlineEditing.tail(at: 2, spans: found) == nil)
    }

    @Test func linkTargets() {
        #expect(spans("[[a|b]]").first?.kind == .wikiLink("a"))
        #expect(spans("[t](http://u)").first?.kind == .link("http://u"))
    }
}

@Suite struct InlineEditingTests {
    // "a **b** c": a=0, ' '=1, ** at 2-3, b=4, ** at 5-6, ' '=7, c=8
    let text = "a **bc** d" as NSString
    var all: NSRange { NSRange(location: 0, length: text.length) }
    var found: [InlineSpan] { InlineMarkup.spans(in: text, range: all) }

    @Test func stepsStopInsideAndOutside() {
        // outside before (2) → inside start (4) → c... → inside end (6) → outside after (8)
        var stops: [Int] = [1]
        while stops.last! < text.length {
            stops.append(InlineEditing.step(from: stops.last!, forward: true, text: text, within: all, spans: found))
        }
        #expect(stops == [1, 2, 4, 5, 6, 8, 9, 10])
        var back: [Int] = [10]
        while back.last! > 0 {
            back.append(InlineEditing.step(from: back.last!, forward: false, text: text, within: all, spans: found))
        }
        #expect(back == [10, 9, 8, 6, 5, 4, 2, 1, 0])
    }

    @Test func tailsPointAwayFromMarkup() {
        #expect(InlineEditing.tail(at: 2, spans: found) == .left)   // outside before
        #expect(InlineEditing.tail(at: 4, spans: found) == .right)  // inside start
        #expect(InlineEditing.tail(at: 6, spans: found) == .left)   // inside end
        #expect(InlineEditing.tail(at: 8, spans: found) == .right)  // outside after
        #expect(InlineEditing.tail(at: 5, spans: found) == nil)
    }

    @Test func deletingSkipsMarkup() {
        // From outside after: the last shown character, c.
        #expect(InlineEditing.deletion(at: 8, forward: false, text: text, within: all, spans: found) == NSRange(location: 5, length: 1))
        // From inside start: the space before the span.
        #expect(InlineEditing.deletion(at: 4, forward: false, text: text, within: all, spans: found) == NSRange(location: 1, length: 1))
        // Forward from outside before: b.
        #expect(InlineEditing.deletion(at: 2, forward: true, text: text, within: all, spans: found) == NSRange(location: 4, length: 1))
    }

    @Test func lastCharacterTakesTheSpan() {
        let text = "x **b** y" as NSString
        let all = NSRange(location: 0, length: text.length)
        let found = InlineMarkup.spans(in: text, range: all)
        #expect(InlineEditing.deletion(at: 7, forward: false, text: text, within: all, spans: found) == NSRange(location: 2, length: 5))
    }

    @Test func editsKeepMarkupOfSpansTheyCut() {
        // Deleting from inside "bc" to the end keeps the closing **.
        let pieces = InlineEditing.deletablePieces(of: NSRange(location: 5, length: 5), spans: found)
        #expect(pieces == [NSRange(location: 5, length: 1), NSRange(location: 8, length: 2)])
        // Taking the whole span takes its markup.
        #expect(InlineEditing.deletablePieces(of: NSRange(location: 1, length: 8), spans: found) == [NSRange(location: 1, length: 8)])
    }
}

@Suite struct RealImageLineTests {
    @Test func pastedImageWithSize() {
        let line = "![](assets/pasted-1790045733506.png)<!-- {\"width\":425,\"height\":270} -->"
        let found = InlineMarkup.spans(in: line as NSString, range: NSRange(location: 0, length: (line as NSString).length))
        #expect(found.map(\.kind) == [.image(ImageReference(source: "assets/pasted-1790045733506.png", width: 425, height: 270))])
    }
}

@Suite struct HighlightTests {
    private func kinds(_ text: String) -> [InlineSpan.Kind] {
        let ns = text as NSString
        return InlineMarkup.spans(in: ns, range: NSRange(location: 0, length: ns.length)).map(\.kind)
    }

    @Test func highlightsAreFound() {
        #expect(kinds("a ==marked words== b") == [.highlight])
        #expect(kinds("==**bold** in it==") == [.highlight, .strong])
        #expect(InlineMarkup.plainText("a ==marked== b") == "a marked b")
    }

    @Test func runsOfEqualsAreNot() {
        #expect(kinds("=======") == [])
        #expect(kinds("a == b and c == d") == [])
        #expect(kinds("=== not this ===") == [])
    }
}
