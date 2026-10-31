import Foundation
import Testing
@testable import GraphKit

/// A real graph, read and never written: `GRAPH=~/reflect swift test --filter RealGraph`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GRAPH"] != nil)) struct RealGraphTests {
    let root = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["GRAPH"]! as NSString).expandingTildeInPath)

    @Test func readsEveryPageQuicklyAndAsWritten() throws {
        let index = PageIndex(root: root)
        let start = Date()
        try index.load()
        let loading = Date().timeIntervalSince(start)
        var unchanged = 0, changed: [String] = []
        for entry in index.entries.values {
            let written = PageFile.write(entry.page, over: entry.source, fallbackTitle: PageFolder.fallbackTitle(for: entry.path),
                                         fixedTitle: PageFolder.titleIsFixed(entry.path))
            if written == entry.source { unchanged += 1 } else { changed.append(entry.path) }
        }
        let resolving = Date()
        for title in index.titles.prefix(2000) { _ = index.backlinks(to: title); _ = index.title(for: title.lowercased()) }
        print(String(format: "%d pages in %.2f s; %d written back unchanged; backlinks and names for 2000 in %.2f s",
                     index.entries.count, loading, unchanged, Date().timeIntervalSince(resolving)))
        #expect(changed.isEmpty, "\(changed.prefix(5))")
        // As Quick Open asks, a letter at a time.
        _ = index.search("x")
        let searching = Date()
        var typed = ""
        for letter in "monarch planning" {
            typed.append(letter)
            _ = index.search(typed, limit: 14)
            _ = index.recent(limit: 14)
        }
        print(String(format: "16 keystrokes searched in %.1f ms", Date().timeIntervalSince(searching) * 1000))
        let finding = Date()
        typed = ""
        var found: [PageIndex.Found] = []
        for letter in ProcessInfo.processInfo.environment["FIND"] ?? "i do worry" {
            typed.append(letter)
            found = index.find(typed, limit: 30)
        }
        print(String(format: "found by words, a letter at a time, in %.1f ms:", Date().timeIntervalSince(finding) * 1000))
        for hit in found.prefix(5) { print("  \(hit.phrase ? "“”" : "  ") \(hit.title) — \(hit.line)") }
    }
}
