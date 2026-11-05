import Foundation
import Testing
@testable import GraphKit
import ReflectCore

/// Finding pages by what they say: the words on disk, ranked, kept as pages
/// change — and, without them, the word index in memory, finding the same.
@Suite struct TextIndexTests {
    let day = { (n: Double) in Date(timeIntervalSince1970: n * 86400) }

    func graph(_ name: String) -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID())")
        return (root, root.appendingPathExtension("sqlite"))
    }

    func fill(_ index: PageIndex) throws {
        try index.save(Page(title: "Apple Orchard", modified: day(1), text: "- Rows of trees\n- Worry about frost in April\n- The cider press"))
        try index.save(Page(title: "Cider", modified: day(2), text: "Pressed from apples.\nThe orchard's best: Bramley."))
        try index.save(Page(title: "Frost Dates", tags: ["Garden"], modified: day(3), text: "Last frost: April 20.\nCover the blossom."))
        try index.save(Page(title: "Pear", modified: day(4), fields: [Page.Field("aliases", .list(["Poire"]))], text: "Soft fruit. Unlike apples."))
        try index.save(Page(title: "Café Notes", modified: day(5), fields: [Page.Field("task", .text("todo"))], text: "- [ ] Order the crème brûlée\n- Espresso machine"))
    }

    @Test func findsByWhatPagesSayBestFirst() throws {
        let (root, file) = graph("text")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.textIndex = words
        try index.load()
        try fill(index)
        words.settle()
        #expect(words.isReady)
        // Every word, anywhere; a title's words counting most.
        #expect(index.textMatches(TextQuery("frost")).first == "Frost Dates")
        #expect(Set(index.textMatches(TextQuery("frost"))) == ["Frost Dates", "Apple Orchard"])
        #expect(index.textMatches(TextQuery("frost april trees")) == ["Apple Orchard"])
        // Phrases as written; what is left out, left out.
        #expect(index.textMatches(TextQuery("\"cider press\"")) == ["Apple Orchard"])
        #expect(index.textMatches(TextQuery("frost -trees")) == ["Frost Dates"])
        // Accents and case aside; another name counts.
        #expect(index.textMatches(TextQuery("CREME brulee")) == ["Café Notes"])
        #expect(index.textMatches(TextQuery("poire")) == ["Pear"])
        // Whole words, unless the last is still being typed.
        #expect(index.textMatches(TextQuery("espress")).isEmpty)
        #expect(index.textMatches(TextQuery("espress", typing: true)) == ["Café Notes"])
        #expect(index.textMatches(TextQuery("espress ", typing: true)).isEmpty)
    }

    @Test func showsTheLinesSayingIt() throws {
        let (root, file) = graph("lines")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.textIndex = words
        try index.load()
        try fill(index)
        words.settle()
        let hits = index.searchText("frost")
        let orchard = try #require(hits.first { $0.title == "Apple Orchard" })
        // The line, plain — its marker gone — and the word marked in it.
        #expect(orchard.lines.map(\.text) == ["Worry about frost in April"])
        #expect(orchard.lines.first?.number == 1)
        let line = try #require(orchard.lines.first)
        let mark = try #require(line.marks.first)
        let start = line.text.index(line.text.startIndex, offsetBy: mark.lowerBound)
        #expect(line.text[start..<line.text.index(start, offsetBy: mark.count)] == "frost")
        // By name first: what is typed, as a title begins.
        #expect(index.searchText("fro").first?.title == "Frost Dates")
        #expect(index.searchText("fro").first?.byName == true)
        // A task's box isn't part of its line.
        #expect(index.searchText("brulee").first?.lines.first?.text == "Order the crème brûlée")
    }

    @Test func searchTakesTagsKindsAndDays() throws {
        let (root, file) = graph("ops")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.textIndex = words
        try index.load()
        try fill(index)
        words.settle()
        #expect(index.searchText("frost #garden").map(\.title) == ["Frost Dates"])
        #expect(index.searchText("frost -#garden").map(\.title) == ["Apple Orchard"])
        #expect(index.searchText("#garden").map(\.title) == ["Frost Dates"])
        #expect(index.searchText("is:todo").map(\.title) == ["Café Notes"])

        let query = Query(search: "worry \"cider press\" -pear #fruit -#soft is:todo -is:done title:app edited:yesterday edited:")
        #expect(query.textContains == "worry \"cider press\" -pear edited:")
        #expect(query.tags == ["fruit"] && query.excludedTags == ["soft"])
        #expect(query.flags == [.todo] && query.excludedFlags == [.done])
        #expect(query.titleContains == "app" && query.editedSinceDaysAgo == 1)
        #expect(Query(search: "edited:3").editedSinceDaysAgo == 3)
        #expect(Query(search: "is:nothing").textContains == "is:nothing")
    }

    @Test func aQueryRanksWhatPagesSay() throws {
        let (root, file) = graph("query")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.textIndex = words
        try index.load()
        try fill(index)
        words.settle()
        #expect(Query(text: "text: frost").run(in: index, this: "") == ["Frost Dates", "Apple Orchard"])
        #expect(Query(text: "text: frost\nsort: title").run(in: index, this: "") == ["Apple Orchard", "Frost Dates"])
        #expect(Query(text: "text: frost\ntag: Garden").run(in: index, this: "") == ["Frost Dates"])
        // As a river orders it: best first, still.
        #expect(Query(text: "text: frost").ordered(in: index).map(\.title) == ["Frost Dates", "Apple Orchard"])
        #expect(Query(text: "text: frost").place(of: "Apple Orchard", in: index).key == "000001")
    }

    @Test func keptAsPagesChangeAndCaughtUpWhenOpenedAgain() throws {
        let (root, file) = graph("kept")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.textIndex = words
        try index.load()
        try fill(index)
        // Changed, renamed, deleted.
        try index.save(Page(title: "Cider", modified: day(6), text: "Made in October."))
        try index.save(Page(title: "Perry", modified: day(7), text: "Soft fruit, pressed."), replacing: "Pear")
        try index.delete("Café Notes")
        words.settle()
        #expect(index.textMatches(TextQuery("bramley")).isEmpty)
        #expect(index.textMatches(TextQuery("october")) == ["Cider"])
        #expect(index.textMatches(TextQuery("pressed")) == ["Perry"])
        #expect(index.textMatches(TextQuery("espresso")).isEmpty)

        // Written while nothing kept it: an index opened again catches up.
        try Data("# Quince\nHard, and fragrant.\n".utf8).write(to: root.appendingPathComponent("notes/quince.md"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(index.entries["Frost Dates"]!.path))
        let again = PageIndex(root: root)
        let reopened = try #require(TextIndex(file: file))
        #expect(reopened.isReady)
        again.textIndex = reopened
        try again.load()
        reopened.settle()
        #expect(again.textMatches(TextQuery("fragrant")) == ["Quince"])
        #expect(again.textMatches(TextQuery("blossom")).isEmpty)
        #expect(again.textMatches(TextQuery("october")) == ["Cider"])
    }

    @Test func withoutTheWordsOnDiskTheSameIsFound() throws {
        let (root, file) = graph("same")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let ranked = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        ranked.textIndex = words
        try ranked.load()
        try fill(ranked)
        words.settle()
        let plain = PageIndex(root: root)
        try plain.load()
        for typed in ["frost", "frost april", "\"cider press\"", "frost -trees", "creme brulee", "poire", "apples", "espress"] {
            let query = TextQuery(typed)
            #expect(Set(ranked.textMatches(query)) == Set(plain.textMatches(query)), "\(typed)")
        }
        #expect(plain.searchText("frost").first { $0.title == "Apple Orchard" }?.lines.map(\.text) == ["Worry about frost in April"])
    }

    @Test func findsPagesByTheirPicturesText() throws {
        let (root, file) = graph("pictures")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: assets.appendingPathComponent("sign.png"))
        // Reflect's description of it, beside it: its text, without reading it.
        try Data("Welcome to the Lantern Waste".utf8).write(to: assets.appendingPathComponent("sign.png.reflect.md"))
        let pictures = ImageTextIndex(root: root, cache: root.appendingPathComponent(".cache"))
        _ = pictures.refresh()
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.pictures = pictures
        index.textIndex = words
        try index.load()
        try index.save(Page(title: "Trip", text: "- Saw this\n- ![](../assets/sign.png)"))
        try index.save(Page(title: "Lamp", text: "A lantern, lit."))
        words.settle()
        #expect(index.textMatches(TextQuery("waste")) == ["Trip"])
        // What it says counts before what its pictures do.
        #expect(index.textMatches(TextQuery("lantern")) == ["Lamp", "Trip"])
        let line = try #require(index.searchText("waste").first?.lines.first)
        #expect(line.picture == "assets/sign.png")
        #expect(line.text == "Welcome to the Lantern Waste")
    }

    @Test func findsPagesByWhatTheyAreAbout() throws {
        let (root, file) = graph("meaning")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: file) }
        let index = PageIndex(root: root)
        let words = try #require(TextIndex(file: file))
        index.textIndex = words
        try index.load()
        try index.save(Page(title: "Backyard", text: "Planted tomatoes, basil and roses. Pruning the shrubs and weeding the beds."))
        try index.save(Page(title: "Dinner", text: "Simmer the onions, add garlic and cumin, then bake the bread in the oven."))
        try index.save(Page(title: "Servers", text: "Upgrade the cluster, patch the database servers and monitor network latency."))
        // Written again together, as a graph is read: every word counted first.
        index.textIndex = nil
        let again = try #require(TextIndex(file: file.deletingLastPathComponent().appendingPathComponent("again-\(UUID()).sqlite")))
        defer { try? FileManager.default.removeItem(at: again.file) }
        index.textIndex = again
        again.settle()
        // Not their words: words like them.
        #expect(index.meaningMatches("gardening flowers").first == "Backyard")
        #expect(index.meaningMatches("cooking a meal").first == "Dinner")
        #expect(index.meaningMatches("computer infrastructure").first == "Servers")
        #expect(index.textMatches(TextQuery("gardening")).isEmpty)
        // As a river asks it.
        #expect(Query(text: "about: cooking").run(in: index, this: "").first == "Dinner")
        #expect(Query(text: "about: cooking").ordered(in: index).first?.title == "Dinner")
    }

    @Test func longLinesAreCutRoundWhatWasFound() {
        let long = String(repeating: "word ", count: 60) + "\u{1}needle\u{2}" + String(repeating: " more", count: 60)
        let line = PageIndex.line(3, marked: long)
        #expect(line.text.count <= 162)
        #expect(line.text.hasPrefix("…") && line.text.hasSuffix("…"))
        let mark = try! #require(line.marks.first)
        let start = line.text.index(line.text.startIndex, offsetBy: mark.lowerBound)
        #expect(line.text[start..<line.text.index(start, offsetBy: mark.count)] == "needle")
    }
}
