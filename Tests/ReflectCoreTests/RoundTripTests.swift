import Foundation
import Testing
@testable import ReflectCore

@Suite struct RoundTripTests {
    @Test(arguments: [
        "- a\n- b\n",
        "- a\n  - b\n    - c\n- d\n",
        "- a\n\n- b\n",
        "-\n",
        "- \n",
        "## [[Links]]\n\n- [[x|y]]\n",
        "a.m.:\n\n- lock\n",
        "+ [ ] call mum\n+ [x] done\n- [ ] checklist\n",
        "1. one\n2. two\n   - nested\n",
        "- item\n\n  a paragraph inside\n\n  - child\n",
        "- item\n  ```\n  code\n\n  more\n  ```\n- next\n",
        "---\nid: x\n---\n# Title\n\nBody\n",
        "- lazy\ncontinuation\n",
        "- a\n    - four\n",
        "no newline",
        "",
        "> quote\n> more\n",
        "---\n",
        "- a\r\n- b\r\n",
        "text  \n  \n- x\n",
    ])
    func roundTrips(_ source: String) {
        #expect(OutlineMarkdown.serialize(OutlineMarkdown.parse(source)) == source)
    }

    @Test func structure() {
        let outline = OutlineMarkdown.parse("- a\n  - b\n\n  para\n- c\n")
        #expect(outline.rows.map(\.depth) == [0, 1, 1, 0])
        #expect(outline.rows.map(\.kind) == [.bullet, .bullet, .paragraph, .bullet])
        #expect(outline.rows[2].gap == [""])
    }

    /// Every note in a real graph, when one is named in REFLECT_GRAPH.
    @Test func graph() throws {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_GRAPH"] else { return }
        let root = URL(fileURLWithPath: path)
        var failures: [String] = []
        var total = 0
        for directory in ["daily", "notes"] {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path)
            for file in files where file.hasSuffix(".md") {
                total += 1
                let source = try String(contentsOf: root.appendingPathComponent("\(directory)/\(file)"), encoding: .utf8)
                if !OutlineMarkdown.roundTrips(source) { failures.append("\(directory)/\(file)") }
            }
        }
        print("round trip: \(total - failures.count)/\(total); failing: \(failures.prefix(40))")
        #expect(failures.isEmpty)
    }
}

@Suite struct DumpTests {
    @Test func dump() throws {
        guard let path = ProcessInfo.processInfo.environment["REFLECT_DUMP"] else { return }
        let outline = OutlineMarkdown.parse(try String(contentsOfFile: path, encoding: .utf8))
        for row in outline.rows {
            print("DUMP \(String(repeating: "  ", count: row.depth))[\(row.kind)\(row.task.map { " \($0)" } ?? "") gap=\(row.gap.count)] \(row.text.replacingOccurrences(of: "\n", with: "⏎").prefix(60))")
        }
    }
}
