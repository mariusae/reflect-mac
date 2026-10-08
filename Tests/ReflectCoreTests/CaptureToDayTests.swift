import Testing
@testable import ReflectCore

@Suite struct CaptureToDayTests {
    let page = WebCapture.Page(url: "https://example.com/a", title: "A page")

    @Test func atTheTopOfTheDay() {
        #expect(WebCapture.prepending(page, toDay: "- Coffee with Ana\n") == "- [A page](https://example.com/a)\n- Coffee with Ana\n")
    }

    @Test func aDayWithNoNoteYet() {
        #expect(WebCapture.prepending(page, toDay: "") == "- [A page](https://example.com/a)\n")
    }

    @Test func highlightsUnderIt() {
        var page = page
        page.highlights = ["One passage", "  "]
        #expect(WebCapture.prepending(page, toDay: "- x\n") == "- [A page](https://example.com/a)\n  - One passage\n- x\n")
    }

    @Test func frontmatterAndTitleStayFirst() {
        let day = "---\nid: \"x\"\n---\n# Tuesday\n\n- x\n"
        #expect(WebCapture.prepending(page, toDay: day) == "---\nid: \"x\"\n---\n# Tuesday\n\n- [A page](https://example.com/a)\n- x\n")
    }

    @Test func awkwardTitlesAndAddresses() {
        let odd = WebCapture.Page(url: "https://en.wikipedia.org/wiki/Swift_(language)", title: "Swift [lang]")
        #expect(WebCapture.prepending(odd, toDay: "") == "- [Swift (lang)](<https://en.wikipedia.org/wiki/Swift_(language)>)\n")
        let untitled = WebCapture.Page(url: "https://example.com/a", title: "")
        #expect(WebCapture.prepending(untitled, toDay: "").hasPrefix("- [example.com"))
    }
}
