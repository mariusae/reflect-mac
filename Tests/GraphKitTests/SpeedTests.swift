import Foundation
import Testing
import GraphKit

/// How long each question and each save takes on a real graph — read from
/// `GRAPH`, never written; saves into a copy at `SCRATCH_GRAPH`, if given.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GRAPH"] != nil)) struct SpeedTests {
    static func time(_ name: String, _ times: Int = 200, _ work: () throws -> Void) rethrows {
        let start = Date()
        for _ in 0..<times { try work() }
        print(String(format: "%@: %.1f µs", name, Date().timeIntervalSince(start) / Double(times) * 1_000_000))
    }

    @Test func everyQuestion() throws {
        let root = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["GRAPH"]! as NSString).expandingTildeInPath)
        let index = PageIndex(root: root)
        let loading = Date()
        try index.load()
        print(String(format: "load %d pages: %.0f ms", index.entries.count, Date().timeIntervalSince(loading) * 1000))
        let titles = Array(index.titles.shuffled().prefix(200))
        var i = 0
        func next() -> String { i += 1; return titles[i % titles.count] }
        Self.time("title(for:)") { _ = index.title(for: next().lowercased()) }
        Self.time("backlinks") { _ = index.backlinks(to: next()) }
        Self.time("links(from:)") { _ = index.links(from: next()) }
        Self.time("tags(of:)") { _ = index.tags(of: next()) }
        Self.time("recent(14)") { _ = index.recent(limit: 14) }
        Self.time("missing") { _ = index.missing() }
        Self.time("tags()") { _ = index.tags() }
        Self.time("conflicted") { _ = index.conflicted() }
        Self.time("references", 50) { _ = index.references(to: next()) }
        for query in ["m", "mo", "mon", "monarch", "i do worry", "plan", "the"] {
            Self.time("search “\(query)”", 50) { _ = index.search(query, limit: 14) }
            Self.time("find “\(query)”", 50) { _ = index.find(query, limit: 30) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SCRATCH_GRAPH"] != nil)) func everySave() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCRATCH_GRAPH"]!)
        let index = PageIndex(root: root)
        try index.load()
        let titles = Array(index.titles.filter { index.entries[$0]?.kind == .note }.shuffled().prefix(50))
        var i = 0
        try Self.time("save (edit)", 50) {
            i += 1
            var page = index[titles[i % titles.count]]!
            page.text += "\nEdited \(i)."
            try index.save(page)
        }
        try Self.time("save (new page)", 50) {
            i += 1
            try index.save(Page(title: "Speed Test \(i) \(UUID())", text: "A new page linking [[\(titles[i % titles.count])]]."))
        }
        try Self.time("rename", 10) {
            i += 1
            let old = titles[i % titles.count]
            guard var page = index[old] else { return }
            page.title = old + " Renamed"
            try index.save(page, replacing: old)
        }
    }
}
