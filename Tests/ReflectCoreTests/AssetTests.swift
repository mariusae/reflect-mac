import Foundation
import Testing
@testable import ReflectCore

@Suite struct AssetTests {
    @Test func namesAsReflectDoes() {
        #expect(Assets.fileName(for: "Q3 Report (final).PDF") == "q3-report-final.pdf")
        #expect(Assets.fileName(for: "archive.tar.gz") == "archive-tar.gz")
        #expect(Assets.fileName(for: ".env") == "env")
        #expect(Assets.fileName(for: "???") == "untitled")
        #expect(Assets.fileName(for: "Eriksen Marius 202601081259370828.pdf") == "eriksen-marius-202601081259370828.pdf")
        #expect(Assets.slug("con") == "con-note")
        #expect(Assets.pastedName(extension: "png", at: Date(timeIntervalSince1970: 1790045733.506)) == "pasted-1790045733506.png")
    }

    @Test func neverWritesOverAFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try Assets.add(Data("one".utf8), named: "report.pdf", to: root) == "assets/report.pdf")
        #expect(try Assets.add(Data("two".utf8), named: "report.pdf", to: root) == "assets/report-2.pdf")
        #expect(try Assets.add(Data("three".utf8), named: "report.pdf", to: root) == "assets/report-3.pdf")
        #expect(try String(contentsOf: root.appendingPathComponent("assets/report.pdf"), encoding: .utf8) == "one")
    }
}
