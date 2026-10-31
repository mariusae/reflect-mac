#if os(macOS)
import Foundation
import ReflectCore
import Testing
@testable import GraphKit

/// Two devices with clones of one repository, editing the same tiddler.
@Suite(.serialized) struct SyncTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weft-sync-\(UUID())")

    func shell(_ arguments: [String], in folder: URL) throws {
        _ = try CommandLineGit(root: folder).run(arguments)
    }

    func device(_ name: String, remote: URL) throws -> URL {
        let folder = directory.appendingPathComponent(name)
        try shell(["clone", "--quiet", remote.path, folder.path], in: directory)
        try shell(["config", "user.name", "Test"], in: folder)
        try shell(["config", "user.email", "test@example.com"], in: folder)
        return folder
    }

    @Test @MainActor func editsToOneTiddlerOnTwoDevicesMergeWithoutConflict() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let remote = directory.appendingPathComponent("remote.git")
        try shell(["init", "--quiet", "--bare", "--initial-branch=main", remote.path], in: directory)
        let a = try device("a", remote: remote)

        let original = Page(title: "Fruit", tags: ["Food"], modified: Date(timeIntervalSince1970: 1_000_000),
                               text: "Apples.\n\nPears.\n")
        let wikiA = PageIndex(root: a)
        try wikiA.save(original)
        _ = try await Git(backend: CommandLineGit(root: a)).sync(.full)
        let b = try device("b", remote: remote)

        // Each device tags it, changes its time, and edits its own paragraph.
        var onA = original
        onA.tags.append("Sweet")
        onA.modified = Date(timeIntervalSince1970: 2_000_000)
        onA.text = "Apples, crisp.\n\nPears.\n"
        try wikiA.save(onA)
        let wikiB = PageIndex(root: b)
        try wikiB.load()
        var onB = try #require(wikiB["Fruit"])
        onB.tags.append("Green")
        onB.modified = Date(timeIntervalSince1970: 3_000_000)
        onB.text = "Apples.\n\nPears, soft.\n"
        try wikiB.save(onB)

        let syncA = GraphSync(git: Git(backend: CommandLineGit(root: a)))
        let syncB = GraphSync(git: Git(backend: CommandLineGit(root: b)))
        _ = try await syncB.git.sync(.full)
        let report = try await syncA.git.sync(.full)
        #expect(report.conflicted.isEmpty)

        try wikiA.load()
        let merged = try #require(wikiA["Fruit"])
        #expect(merged.tags == ["Food", "Sweet", "Green"])
        #expect(merged.modified == Date(timeIntervalSince1970: 3_000_000))
        #expect(merged.text == "Apples, crisp.\n\nPears, soft.\n")
    }
}
#endif
