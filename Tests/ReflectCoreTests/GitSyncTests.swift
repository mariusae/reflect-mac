import Foundation
import Testing
@testable import ReflectCore
import ReflectGit2

/// Reflect's own sync tests (`src-tauri/src/git/tests.rs`), run against this
/// implementation: a bare remote, and two devices with clones of it.
private final class Fixture {
    let directory: URL
    let remote: URL
    let deviceA: URL
    private(set) var deviceB: URL?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-sync-\(UUID().uuidString)")
        remote = directory.appendingPathComponent("remote.git")
        deviceA = directory.appendingPathComponent("a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try shell(["init", "--quiet", "--bare", "--initial-branch=main", remote.path], in: directory)
        try shell(["init", "--quiet", "--initial-branch=main", deviceA.path], in: directory)
        try configure(deviceA)
        try shell(["remote", "add", "origin", remote.path], in: deviceA)
        for folder in ["daily", "notes", "assets"] {
            try FileManager.default.createDirectory(at: deviceA.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// A second device: a clone of what the first has pushed.
    func secondDevice() throws -> URL {
        let path = directory.appendingPathComponent("b")
        try shell(["clone", "--quiet", remote.path, path.path], in: directory)
        try configure(path)
        deviceB = path
        return path
    }

    private func configure(_ repo: URL) throws {
        try shell(["config", "user.name", "Test"], in: repo)
        try shell(["config", "user.email", "test@example.com"], in: repo)
    }

    @discardableResult
    func shell(_ arguments: [String], in directory: URL) throws -> String {
        try CommandLineGit(root: directory).run(arguments)
    }
}

private func write(_ root: URL, _ path: String, _ text: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func read(_ root: URL, _ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

private func headMessage(_ root: URL) throws -> String {
    try CommandLineGit(root: root).run(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func headPaths(_ root: URL) throws -> [String] {
    try CommandLineGit(root: root).run(["ls-tree", "-r", "--name-only", "HEAD"]).split(separator: "\n").map(String.init)
}

private func isClean(_ root: URL) -> Bool {
    !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/MERGE_HEAD").path)
}

/// Which way the sync's steps are done: every sync test runs both ways, so
/// the phone's libgit2 syncs as the Mac's `git` does.
enum SyncBackend: String, CaseIterable, CustomStringConvertible {
    case commandLine, libgit2

    var description: String { rawValue }

    func git(_ root: URL) -> Git {
        switch self {
        case .commandLine: Git(root: root)
        case .libgit2: Git(backend: LibGit2Backend(root: root)!)
        }
    }
}

@Suite(.serialized) struct GitSyncTests {

    // MARK: Committing

    @Test(arguments: SyncBackend.allCases) func commitDescribesSingleNoteChanges(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        let git = backend.git(fixture.deviceA)
        try write(fixture.deviceA, "notes/project-atlas.md", "# Project Atlas\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add Project Atlas")
        try write(fixture.deviceA, "notes/project-atlas.md", "# Project Atlas\n\nNext step\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Update Project Atlas")
        try FileManager.default.removeItem(at: fixture.deviceA.appendingPathComponent("notes/project-atlas.md"))
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Delete Project Atlas")
    }

    @Test(arguments: SyncBackend.allCases) func commitUsesAuthoredSubjectsAndHidesPrivateOnes(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        let git = backend.git(fixture.deviceA)
        try write(fixture.deviceA, "notes/01arz3ndektsv4rrffq69g5fav.md", "---\ntitle: \"Project #1\"\n---\n# Ignored H1\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add Project #1")
        try write(fixture.deviceA, "notes/private-project.md", "---\nprivate: true\ntitle: Secret Plan\n---\n# Secret Heading\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add private note")
        try write(fixture.deviceA, "daily/2026-06-23.md", "- one\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add daily note for 2026-06-23")
    }

    @Test(arguments: SyncBackend.allCases) func commitDescribesRenamesAndBatches(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        let git = backend.git(fixture.deviceA)
        let body = "\n\n- stable body line one\n- stable body line two\n- stable body line three\n"
        try write(fixture.deviceA, "notes/original.md", "# Original Name" + body)
        _ = try git.cycle(.push)
        try FileManager.default.removeItem(at: fixture.deviceA.appendingPathComponent("notes/original.md"))
        try write(fixture.deviceA, "notes/renamed.md", "# Renamed Name" + body)
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Rename Original Name to Renamed Name")

        try write(fixture.deviceA, "daily/2026-06-23.md", "# Daily\n")
        try write(fixture.deviceA, "notes/project-atlas.md", "# Project Atlas\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add 2 notes")

        try write(fixture.deviceA, "notes/capture.md", "# Capture\n")
        try write(fixture.deviceA, "assets/screenshot.png", "not really a png\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add 1 note and 1 attachment")

        try write(fixture.deviceA, "notes/other.md", "# Other\n")
        try write(fixture.deviceA, "books/book.json", "{}\n")
        _ = try git.cycle(.push)
        #expect(try headMessage(fixture.deviceA) == "Add 1 note and 1 file")
    }

    @Test(arguments: SyncBackend.allCases) func commitLeavesOutTheIndexAndLargeFiles(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        try write(fixture.deviceA, ".reflect/index.sqlite", "index")
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        let big = fixture.deviceA.appendingPathComponent("assets/video.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        try FileHandle(forWritingTo: big).truncate(atOffset: UInt64(Git.maxFileBytes))
        let report = try backend.git(fixture.deviceA).cycle(.push)
        #expect(report.skippedLargeFiles.map(\.path) == ["assets/video.mov"])
        #expect(try headPaths(fixture.deviceA) == ["notes/a.md"])
    }

    @Test(arguments: SyncBackend.allCases) func commitWorksWhenTheIgnoreFileAlreadyLeavesOutTheIndex(_ backend: SyncBackend) throws {
        // Reflect writes `/.reflect/` into every graph's .gitignore.
        let fixture = try Fixture()
        try write(fixture.deviceA, ".gitignore", "# Reflect local index + caches (rebuildable; never committed)\n/.reflect/\n")
        try write(fixture.deviceA, ".reflect/index.sqlite", "index")
        try write(fixture.deviceA, "daily/2026-09-25.md", "- today\n")
        _ = try backend.git(fixture.deviceA).cycle(.full)
        #expect(try headPaths(fixture.deviceA) == [".gitignore", "daily/2026-09-25.md"])
    }

    // MARK: Merging

    /// Both devices start from `path` holding `text`, pushed by the first.
    private func shared(_ backend: SyncBackend, _ path: String, _ text: String) throws -> (Fixture, Git, Git, URL) {
        let fixture = try Fixture()
        try write(fixture.deviceA, path, text)
        let a = backend.git(fixture.deviceA)
        _ = try a.cycle(.push)
        let deviceB = try fixture.secondDevice()
        return (fixture, a, backend.git(deviceB), deviceB)
    }

    @Test(arguments: SyncBackend.allCases) func conflictingEditsAreCommittedWithLabelledMarkers(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/shared.md", "# Shared\n\noriginal line\n")
        try write(deviceB, "notes/shared.md", "# Shared\n\nedited on b\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "notes/shared.md", "# Shared\n\nedited on a\n")

        let report = try a.cycle(.full)
        #expect(report.conflicted == ["notes/shared.md"])
        #expect(report.changed.contains("notes/shared.md"))
        let content = try read(fixture.deviceA, "notes/shared.md")
        #expect(content == "# Shared\n\n<<<<<<< this device\nedited on a\n=======\nedited on b\n>>>>>>> other device\n")
        #expect(try headMessage(fixture.deviceA) == "Merge changes from other devices (conflicts to review)")
        #expect(isClean(fixture.deviceA))

        // Pushed, so the other device comes to the same marked-up note.
        _ = try b.cycle(.full)
        #expect(try read(deviceB, "notes/shared.md") == content)
    }

    /// As it happened on 2026-10-03: one device took a line's trailing
    /// space off and added a section at the end, the other added one there
    /// too. The line both kept must not be in the conflict — "Keep Both"
    /// then wrote it twice — and a merge left with no markers is not one
    /// to review.
    @Test(arguments: SyncBackend.allCases) func lineEndsDoNotMakeAConflict(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "daily/2026-10-03.md", "- Melvin birthday yesterday \n")
        try write(deviceB, "daily/2026-10-03.md", "- Melvin birthday yesterday\n- [[Links]]\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "daily/2026-10-03.md", "- Melvin birthday yesterday \n- Prism\n")

        _ = try a.cycle(.full)
        let content = try read(fixture.deviceA, "daily/2026-10-03.md")
        #expect(content.components(separatedBy: "Melvin birthday yesterday").count == 2)
        #expect(content.hasPrefix("- Melvin birthday yesterday\n"))

        // Only the line's end differs: no conflict at all.
        let (fixture2, c, d, deviceD) = try shared(backend, "notes/n.md", "- one \n- two\n")
        try write(deviceD, "notes/n.md", "- one\n- two\n")
        _ = try d.cycle(.push)
        try write(fixture2.deviceA, "notes/n.md", "- one \n- two\n- three\n")
        let report = try c.cycle(.full)
        #expect(report.conflicted.isEmpty)
        #expect(!ConflictMarkers.detect(try read(fixture2.deviceA, "notes/n.md")))
    }

    @Test(arguments: SyncBackend.allCases) func editVersusDeleteKeepsTheEdit(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/keep.md", "# Keep\n\noriginal\n")
        try write(deviceB, "notes/keep.md", "# Keep\n\nedited on b\n")
        _ = try b.cycle(.push)
        try FileManager.default.removeItem(at: fixture.deviceA.appendingPathComponent("notes/keep.md"))

        let report = try a.cycle(.full)
        #expect(report.conflicted == ["notes/keep.md"])
        #expect(try read(fixture.deviceA, "notes/keep.md").contains("edited on b"))
        #expect(try headPaths(fixture.deviceA).contains("notes/keep.md"))
        #expect(isClean(fixture.deviceA))
    }

    @Test(arguments: SyncBackend.allCases) func binaryConflictKeepsBothCopies(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        let image = fixture.deviceA.appendingPathComponent("assets/img.bin")
        try Data([0, 98, 97, 115, 101, 1]).write(to: image)
        let a = backend.git(fixture.deviceA)
        _ = try a.cycle(.push)
        let deviceB = try fixture.secondDevice()
        try Data([0, 66, 1]).write(to: deviceB.appendingPathComponent("assets/img.bin"))
        _ = try backend.git(deviceB).cycle(.push)
        try Data([0, 65, 1]).write(to: image)

        let report = try a.cycle(.full)
        #expect(Set(report.conflicted) == ["assets/img.bin", "assets/img (conflict).bin"])
        #expect(try Data(contentsOf: image) == Data([0, 65, 1]))
        #expect(try Data(contentsOf: fixture.deviceA.appendingPathComponent("assets/img (conflict).bin")) == Data([0, 66, 1]))
        #expect(isClean(fixture.deviceA))
    }

    @Test(arguments: SyncBackend.allCases) func renameRenameKeepsBothNames(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/orig.md", "# Original\n\nshared content that travels with the rename\n")
        try FileManager.default.moveItem(at: deviceB.appendingPathComponent("notes/orig.md"),
                                         to: deviceB.appendingPathComponent("notes/renamed-b.md"))
        _ = try b.cycle(.push)
        try FileManager.default.moveItem(at: fixture.deviceA.appendingPathComponent("notes/orig.md"),
                                         to: fixture.deviceA.appendingPathComponent("notes/renamed-a.md"))

        _ = try a.cycle(.full)
        let paths = try headPaths(fixture.deviceA)
        #expect(paths.contains("notes/renamed-a.md"))
        #expect(paths.contains("notes/renamed-b.md"))
        #expect(!paths.contains("notes/orig.md"))
        #expect(isClean(fixture.deviceA))
    }

    @Test(arguments: SyncBackend.allCases) func renameOnOneDeviceMergesWithAnEditOnTheOther(_ backend: SyncBackend) throws {
        let base = "# Meeting Notes\n\n- agenda point one\n- agenda point two\n- agenda point three\n"
        let (fixture, a, b, deviceB) = try shared(backend, "notes/01arz3ndektsv4rrffq69g5fav.md", base)
        try write(deviceB, "notes/01arz3ndektsv4rrffq69g5fav.md",
                  "# Meeting Notes\n\n- agenda point one\n- agenda point two EDITED ON B\n- agenda point three\n")
        _ = try b.cycle(.push)
        try FileManager.default.removeItem(at: fixture.deviceA.appendingPathComponent("notes/01arz3ndektsv4rrffq69g5fav.md"))
        try write(fixture.deviceA, "notes/meeting-notes.md", base)

        let report = try a.cycle(.full)
        #expect(report.conflicted.isEmpty)
        #expect(try read(fixture.deviceA, "notes/meeting-notes.md").contains("EDITED ON B"))
        #expect(!FileManager.default.fileExists(atPath: fixture.deviceA.appendingPathComponent("notes/01arz3ndektsv4rrffq69g5fav.md").path))
    }

    @Test(arguments: SyncBackend.allCases) func theSameNoteMadeOnTwoDevicesIsAConflictToReview(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/seed.md", "# Seed\n")
        try write(deviceB, "notes/meeting.md", "# Meeting\n\nnotes from device b\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "notes/meeting.md", "# Meeting\n\nnotes from device a\n")

        let report = try a.cycle(.full)
        #expect(report.conflicted == ["notes/meeting.md"])
        let content = try read(fixture.deviceA, "notes/meeting.md")
        #expect(content.contains("notes from device a") && content.contains("notes from device b"))
        #expect(ConflictMarkers.detect(content))
        #expect(isClean(fixture.deviceA))
    }

    @Test(arguments: SyncBackend.allCases) func aPushTurnedAwayMergesAndTriesAgain(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "daily/2026-06-23.md", "- one\n")
        try write(deviceB, "notes/b.md", "# B\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "notes/a.md", "# A\n")

        // A push-only cycle: no fetch first, so the push is turned away.
        let report = try a.cycle(.push)
        #expect(report.parts.contains("pushed"))
        _ = try b.cycle(.full)
        #expect(FileManager.default.fileExists(atPath: deviceB.appendingPathComponent("notes/a.md").path))
        #expect(try headMessage(fixture.deviceA) == "Merge changes from other devices")
    }

    // MARK: Putting things right

    /// HEAD off its branch — by a person's git, or a crash — but where the
    /// branch is, or ahead of it: put back on it, and the sync goes on.
    @Test(arguments: SyncBackend.allCases) func aDetachedHeadIsPutBackOnItsBranch(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        let git = backend.git(fixture.deviceA)
        _ = try git.cycle(.push)
        let cli = CommandLineGit(root: fixture.deviceA)
        try cli.run(["checkout", "--quiet", "--detach"])
        try write(fixture.deviceA, "notes/b.md", "# B\n")
        try cli.run(["add", "-A"])
        try cli.run(["commit", "--quiet", "-m", "Made while detached"])
        try write(fixture.deviceA, "notes/c.md", "# C\n")
        let report = try git.cycle(.full)
        #expect(report.parts.contains("put HEAD back on main"))
        #expect(try cli.currentBranch() == "main")
        #expect(try headPaths(fixture.deviceA).contains("notes/b.md"))
        #expect(try headPaths(fixture.deviceA).contains("notes/c.md"))
    }

    /// A HEAD no branch leads to is a person's doing: not guessed at.
    @Test(arguments: SyncBackend.allCases) func aDetachedHeadNoBranchLeadsToIsRefused(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        let git = backend.git(fixture.deviceA)
        _ = try git.cycle(.push)
        try write(fixture.deviceA, "notes/a.md", "# A\n\nmore\n")
        _ = try git.cycle(.push)
        let cli = CommandLineGit(root: fixture.deviceA)
        try cli.run(["checkout", "--quiet", "--detach", "HEAD~1"])
        try write(fixture.deviceA, "notes/b.md", "# B\n")
        try cli.run(["add", "-A"])
        try cli.run(["commit", "--quiet", "-m", "Gone another way"])
        #expect(throws: GitError.self) { try git.cycle(.full) }
    }

    /// A merge a crash left in the middle: left, as `--abort` leaves one,
    /// what was written since kept, and the sync goes on to merge again.
    @Test(arguments: SyncBackend.allCases) func aMergeLeftInTheMiddleIsLeftAndTheSyncGoesOn(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/shared.md", "# Shared\n\noriginal line\n")
        try write(deviceB, "notes/shared.md", "# Shared\n\nedited on b\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "notes/shared.md", "# Shared\n\nedited on a\n")
        let cli = CommandLineGit(root: fixture.deviceA)
        try cli.run(["commit", "--quiet", "-am", "Edited on a"])
        try cli.run(["fetch", "--quiet", "origin"])
        _ = try? cli.run(["merge", "--quiet", "origin/main"])
        #expect(!isClean(fixture.deviceA))
        // Written after the crash, before the next sync.
        try write(fixture.deviceA, "notes/later.md", "# Later\n")

        let report = try a.cycle(.full)
        #expect(report.parts.contains("left a merge that was never finished"))
        #expect(isClean(fixture.deviceA))
        #expect(try read(fixture.deviceA, "notes/later.md") == "# Later\n")
        #expect(try read(fixture.deviceA, "notes/shared.md")
                == "# Shared\n\n<<<<<<< this device\nedited on a\n=======\nedited on b\n>>>>>>> other device\n")
        #expect(try headPaths(fixture.deviceA).contains("notes/later.md"))
    }

    /// A lock a killed git left: cleared once old; a fresh one, which a git
    /// may yet hold, waited on.
    @Test(arguments: SyncBackend.allCases) func aStaleLockIsClearedAndAFreshOneIsNot(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        let git = backend.git(fixture.deviceA)
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        _ = try git.cycle(.push)
        let lock = fixture.deviceA.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        try write(fixture.deviceA, "notes/a.md", "# A\n\nmore\n")
        #expect(throws: (any Error).self) { try git.cycle(.push) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: lock.path)
        let report = try git.cycle(.push)
        #expect(report.parts.contains("cleared 1 stale lock"))
        #expect(try headMessage(fixture.deviceA) == "Update A")
    }

    /// Before each merge, the branch kept where it was, in a reference
    /// never pushed: whatever the merge does can be undone.
    @Test(arguments: SyncBackend.allCases) func aMergeKeepsABackupOfTheBranch(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/shared.md", "# Shared\n")
        try write(deviceB, "notes/b.md", "# B\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        try CommandLineGit(root: fixture.deviceA).run(["add", "-A"])
        try CommandLineGit(root: fixture.deviceA).run(["commit", "--quiet", "-m", "A"])
        let before = CommandLineGit(root: fixture.deviceA).head()
        _ = try a.cycle(.full)
        let backups = a.backups()
        #expect(backups.count == 1)
        let kept = try CommandLineGit(root: fixture.deviceA).run(["rev-parse", backups[0].reference]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(kept == before)
        // Never pushed.
        let remoteRefs = try CommandLineGit(root: fixture.remote).run(["for-each-ref", "--format=%(refname)"])
        #expect(!remoteRefs.contains("sync-backups"))
    }

    /// libgit2's merge left as `git merge --abort` leaves one: the files it
    /// conflicted back as they were, every other file as it is — once, a
    /// hard reset threw away what was written after the cycle's commit.
    @Test func libgit2LeavingAMergeKeepsOtherWriting() throws {
        let (fixture, a, b, deviceB) = try shared(.libgit2, "notes/shared.md", "# Shared\n\noriginal line\n")
        try write(deviceB, "notes/shared.md", "# Shared\n\nedited on b\n")
        _ = try b.cycle(.push)
        try write(fixture.deviceA, "notes/shared.md", "# Shared\n\nedited on a\n")
        try CommandLineGit(root: fixture.deviceA).run(["commit", "--quiet", "-am", "Edited on a"])
        let backend = LibGit2Backend(root: fixture.deviceA)!
        try backend.fetch()
        guard case .conflicted = try backend.merge("refs/remotes/origin/main", message: "m") else {
            Issue.record("expected a conflict")
            return
        }
        try write(fixture.deviceA, "notes/typed.md", "# Typed during the merge\n")
        try write(fixture.deviceA, "notes/later.md", "# Later\n")
        backend.abortMerge()
        #expect(try backend.operationInProgress() == nil)
        #expect(try read(fixture.deviceA, "notes/typed.md") == "# Typed during the merge\n")
        #expect(try read(fixture.deviceA, "notes/shared.md") == "# Shared\n\nedited on a\n")
    }

    /// Two devices writing and syncing at random, conflicts and all: in the
    /// end both have the same notes, nothing left mid-merge, and every line
    /// either ever wrote is in them — merged, or between markers.
    @Test(arguments: SyncBackend.allCases) func randomWritingOnTwoDevicesLosesNothing(_ backend: SyncBackend) throws {
        let (fixture, a, b, deviceB) = try shared(backend, "notes/n0.md", "# N0\n")
        let devices = [(fixture.deviceA, a, "a"), (deviceB, b, "b")]
        var written: [String: Set<String>] = [:]
        var rng = SystemRandomNumberGenerator()
        var serial = 0
        for _ in 0..<40 {
            let (root, git, name) = devices[Int.random(in: 0..<2, using: &rng)]
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let path = "notes/n\(Int.random(in: 0..<3, using: &rng)).md"
                var lines = TextMerge.lines((try? read(root, path)) ?? "").map(String.init)
                serial += 1
                let line = "- \(name) wrote \(serial)\n"
                lines.insert(line, at: Int.random(in: 0...lines.count, using: &rng))
                try write(root, path, lines.joined())
                written[path, default: []].insert(line)
            }
            _ = try git.cycle(Bool.random(using: &rng) ? .full : .push)
        }
        for _ in 0..<2 { for (_, git, _) in devices { _ = try git.cycle(.full) } }
        for (path, lines) in written {
            let onA = try read(fixture.deviceA, path), onB = try read(deviceB, path)
            #expect(onA == onB)
            let present = Set(TextMerge.lines(onA).map(String.init))
            for line in lines { #expect(present.contains(line), "\(line) lost from \(path)") }
        }
        #expect(isClean(fixture.deviceA) && isClean(deviceB))
    }

    /// A shallow clone whose note of where its history stops was lost —
    /// libgit2 lost it on fetches — has it again, and a fetch keeps it.
    @Test func aLostShallowNoteIsFoundAgainAndKept() throws {
        let fixture = try Fixture()
        let mac = Git(root: fixture.deviceA)
        for i in 0..<3 {
            try write(fixture.deviceA, "notes/shared.md", "# Shared\n\nversion \(i)\n")
            _ = try mac.cycle(.push)
        }
        let phoneRoot = fixture.directory.appendingPathComponent("phone")
        try fixture.shell(["clone", "--quiet", "--depth", "1", "file://" + fixture.remote.path, phoneRoot.path], in: fixture.directory)
        let note = phoneRoot.appendingPathComponent(".git/shallow")
        let original = try String(contentsOf: note, encoding: .utf8)
        try write(fixture.deviceA, "notes/more.md", "# More\n")
        _ = try mac.cycle(.push)
        let phone = LibGit2Backend(root: phoneRoot)!
        try phone.fetch()
        #expect(try String(contentsOf: note, encoding: .utf8) == original)
        try FileManager.default.removeItem(at: note)
        // Opened again, as the app is: libgit2 keeps what it read of the note.
        #expect(try LibGit2Backend(root: phoneRoot)!.markMissingHistory() == 1)
        #expect(try String(contentsOf: note, encoding: .utf8) == original)
        try fixture.shell(["fsck", "--connectivity-only", "--no-progress"], in: phoneRoot)
    }

    /// The phone's clone has only the latest commit; whatever the two then
    /// do, the merge finds where they parted.
    @Test(arguments: SyncBackend.allCases) func aShallowCloneMergesWhenTheyPart(_ backend: SyncBackend) throws {
        let fixture = try Fixture()
        let mac = Git(root: fixture.deviceA)
        for i in 0..<5 {
            try write(fixture.deviceA, "notes/shared.md", "# Shared\n\nversion \(i)\n")
            _ = try mac.cycle(.push)
        }
        let phoneRoot = fixture.directory.appendingPathComponent("phone")
        try fixture.shell(["clone", "--quiet", "--depth", "1", "file://" + fixture.remote.path, phoneRoot.path], in: fixture.directory)
        try fixture.shell(["config", "user.name", "Phone"], in: phoneRoot)
        try fixture.shell(["config", "user.email", "phone@example.com"], in: phoneRoot)
        let phone = backend.git(phoneRoot)
        try write(fixture.deviceA, "notes/mac.md", "# Mac\n")
        _ = try mac.cycle(.push)
        try write(phoneRoot, "notes/phone.md", "# Phone\n")
        guard backend == .commandLine else {
            // libgit2 fetches history only over the network, not from a
            // folder: here it must fail cleanly, the clone left as it was.
            #expect(throws: GitError.self) { try phone.cycle(.full) }
            #expect(LibGit2Backend(root: phoneRoot)!.isShallow())
            try fixture.shell(["fsck", "--connectivity-only", "--no-progress"], in: phoneRoot)
            return
        }
        _ = try phone.cycle(.full)
        #expect(!CommandLineGit(root: phoneRoot).isShallow())
        _ = try mac.cycle(.full)
        #expect(try read(phoneRoot, "notes/mac.md") == "# Mac\n")
        #expect(try read(fixture.deviceA, "notes/phone.md") == "# Phone\n")
    }

    /// The phone: a clone through libgit2, syncing with a Mac that
    /// uses `git` — both ways, through a conflict. (The phone clones only
    /// the latest commit, but libgit2 cannot do that from a folder.)
    @Test func aCloneSyncsWithTheMac() throws {
        let fixture = try Fixture()
        let mac = Git(root: fixture.deviceA)
        try write(fixture.deviceA, "notes/shared.md", "# Shared\n\noriginal line\n")
        _ = try mac.cycle(.push)
        try write(fixture.deviceA, "daily/2026-09-25.md", "- from the mac\n")
        _ = try mac.cycle(.push)

        let phoneRoot = fixture.directory.appendingPathComponent("phone")
        let phone = Git(backend: try LibGit2Backend.clone(fixture.remote.path, to: phoneRoot))
        #expect(try read(phoneRoot, "daily/2026-09-25.md") == "- from the mac\n")

        try write(phoneRoot, "notes/shared.md", "# Shared\n\nedited on the phone\n")
        try write(phoneRoot, "daily/2026-09-26.md", "- from the phone\n")
        _ = try phone.cycle(.push)
        try write(fixture.deviceA, "notes/shared.md", "# Shared\n\nedited on the mac\n")

        let report = try mac.cycle(.full)
        #expect(report.conflicted == ["notes/shared.md"])
        #expect(try read(fixture.deviceA, "daily/2026-09-26.md") == "- from the phone\n")

        _ = try phone.cycle(.full)
        #expect(try read(phoneRoot, "notes/shared.md") == read(fixture.deviceA, "notes/shared.md"))
        #expect(isClean(phoneRoot))
    }

    /// What the phone does first: only the latest commit, over HTTPS. Uses
    /// the network, so only with `REFLECT_NETWORK_TESTS=1`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REFLECT_NETWORK_TESTS"] == "1"))
    func aShallowCloneOverHTTPS() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = try LibGit2Backend.clone("https://github.com/libgit2/TestGitRepository", to: directory, depth: 1)
        #expect(backend.commitCount() == 1)
        #expect(try backend.currentBranch() != nil)
        let git = Git(backend: backend)
        _ = try git.cycle(.full)
    }

    @Test func conflictCopyPathsStayInTheirDirectory() {
        #expect(Git.conflictCopyPath("assets/img.png") == "assets/img (conflict).png")
        #expect(Git.conflictCopyPath("assets.v1/img") == "assets.v1/img (conflict)")
        #expect(Git.conflictCopyPath("assets.v1/img.png") == "assets.v1/img (conflict).png")
        #expect(Git.conflictCopyPath("topfile.bin") == "topfile (conflict).bin")
        #expect(Git.conflictCopyPath("noext") == "noext (conflict)")
        #expect(Git.conflictCopyPath("assets/.hidden") == "assets/.hidden (conflict)")
    }
}

@Suite struct ConflictMarkerTests {
    let source = "before\n<<<<<<< this device\nours\n=======\ntheirs\n>>>>>>> other device\nafter\n"

    @Test func detectParseCountAndResolve() {
        #expect(ConflictMarkers.detect(source))
        #expect(ConflictMarkers.blockCount(source) == 1)
        #expect(ConflictMarkers.labels(source)?.ours == "this device")
        #expect(ConflictMarkers.resolve(source, keeping: .ours) == "before\nours\nafter\n")
        #expect(ConflictMarkers.resolve(source, keeping: .theirs) == "before\ntheirs\nafter\n")
        #expect(ConflictMarkers.resolve(source, keeping: .both) == "before\nours\ntheirs\nafter\n")
        #expect(ConflictMarkers.segments(source) == [
            .text("before"),
            .conflict(ours: .init(label: "this device", text: "ours"), theirs: .init(label: "other device", text: "theirs")),
            .text("after\n"),
        ])
    }

    @Test func mentionsOfMarkersAreNotConflicts() {
        #expect(!ConflictMarkers.detect("<<<<<<< just prose\n"))
        #expect(!ConflictMarkers.detect("=======\n>>>>>>> b\n<<<<<<< a\n"))
    }

    @Test func anUnfinishedBlockStaysText() {
        let cut = "a\n<<<<<<< this device\nours\n======="
        #expect(ConflictMarkers.segments(cut) == [.text(cut)])
    }
}
