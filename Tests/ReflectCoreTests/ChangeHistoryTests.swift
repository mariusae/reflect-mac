import Foundation
import Testing
@testable import ReflectCore
@testable import ReflectGit2

/// A repository with commits at given times, made with git itself.
private struct Repo {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        git("init", "-q")
    }

    @discardableResult
    func git(_ arguments: String..., at time: Int? = nil) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=T", "-c", "user.email=t@t"] + arguments
        var environment = ProcessInfo.processInfo.environment
        if let time { environment["GIT_COMMITTER_DATE"] = "\(time) +0000"; environment["GIT_AUTHOR_DATE"] = "\(time) +0000" }
        process.environment = environment
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func write(_ path: String, _ text: String) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    func commit(_ path: String, _ text: String, at time: Int) throws {
        try write(path, text)
        git("add", "-A")
        git("commit", "-q", "-m", "x", at: time)
    }
}

@Suite struct ChangeHistoryTests {
    @Test func lastCommitToTouchEachNote() throws {
        let repo = try Repo()
        try repo.commit("notes/a.md", "- a\n", at: 1_600_000_000)
        try repo.commit("notes/b.md", "- b\n", at: 1_610_000_000)
        try repo.commit("notes/a.md", "- a again\n", at: 1_620_000_000)
        let folder = repo.root.appendingPathComponent("store")
        let store = try #require(ChangeHistory(graph: repo.root, in: folder))
        let git = try #require(LibGit2Backend(root: repo.root))
        var times = store.update(from: git)
        #expect(times["notes/a.md"] == Date(timeIntervalSince1970: 1_620_000_000))
        #expect(times["notes/b.md"] == Date(timeIntervalSince1970: 1_610_000_000))
        // Only what is new read the next time, the rest kept.
        try repo.commit("notes/b.md", "- b again\n", at: 1_630_000_000)
        times = store.update(from: try #require(LibGit2Backend(root: repo.root)))
        #expect(times["notes/b.md"] == Date(timeIntervalSince1970: 1_630_000_000))
        #expect(times["notes/a.md"] == Date(timeIntervalSince1970: 1_620_000_000))
    }

    @Test func theIndexTakesThemButForWhatChangedSince() throws {
        let repo = try Repo()
        try repo.commit("notes/a.md", "- a\n", at: 1_600_000_000)
        try repo.commit("notes/b.md", "- b\n", at: 1_610_000_000)
        try repo.write("notes/b.md", "- b, edited, not committed\n")
        let index = NoteIndex(root: repo.root)
        index.scan()
        let git = try #require(LibGit2Backend(root: repo.root))
        let store = try #require(ChangeHistory(graph: repo.root, in: repo.root.appendingPathComponent("store")))
        index.useHistory(store.update(from: git), uncommitted: git.uncommittedPaths())
        #expect(index.entry("notes/a.md")?.modified == Date(timeIntervalSince1970: 1_600_000_000))
        // Edited since: its file's own time, today's.
        #expect((index.entry("notes/b.md")?.modified ?? .distantPast) > Date(timeIntervalSince1970: 1_700_000_000))
    }
}
