import Foundation
import Testing
@testable import ReflectCore

@Suite struct SearchTimingTests {
    @Test func timesEachStage() throws {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_TIMING_GRAPH"] else { return }
        let root = URL(fileURLWithPath: path)
        let index = NoteIndex(root: root)
        index.scan()
        let search = ReflectSearchIndex(root: root)
        let pictures = ImageTextIndex(root: root, cache: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.mariusae.ReflectMac/PictureText"))
        _ = pictures.refresh()
        func time(_ name: String, _ work: () -> Int) {
            let start = Date()
            let count = work()
            print(String(format: "%@: %.1f ms (%d)", name, Date().timeIntervalSince(start) * 1000, count))
        }
        // The notes linked to most, and a day.
        for path in ["notes/links.md", "notes/zachary-devito.md", "daily/2026-09-24.md"] {
            time("backlinks \(path)") { index.backlinks(to: path).reduce(0) { $0 + $1.contexts.count } }
        }
        time("tasks, open") { index.tasks().count }
        time("tasks, grouped") { Tasks.group(index.tasks(), today: .today).count }
        for query in ["k", "ko", "kod", "the", "a b"] {
            print("— \(query)")
            time("date detector") {
                let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
                return detector?.firstMatch(in: query, range: NSRange(location: 0, length: (query as NSString).length)) == nil ? 0 : 1
            }
            time("titles") { index.matches(query, limit: 20).count }
            time("content fts") { search?.search(query, limit: 25).count ?? -1 }
            time("content scan") { index.containing(query, limit: 25).count }
            time("pictures") { pictures.search(query).count }
            time("pictures→notes") { pictures.search(query).prefix(20).reduce(0) { $0 + index.notes(showing: $1.path).count } }
        }
    }
}
