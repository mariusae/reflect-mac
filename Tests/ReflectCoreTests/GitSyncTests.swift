import Foundation
import Testing
@testable import ReflectCore

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
        try Git(root: directory).run(arguments)
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
    try Git(root: root).run(["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func headPaths(_ root: URL) throws -> [String] {
    try Git(root: root).run(["ls-tree", "-r", "--name-only", "HEAD"]).split(separator: "\n").map(String.init)
}

private func isClean(_ root: URL) -> Bool {
    !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/MERGE_HEAD").path)
}

@Suite(.serialized) struct GitSyncTests {

    // MARK: Committing

    @Test func commitDescribesSingleNoteChanges() throws {
        let fixture = try Fixture()
        let git = Git(root: fixture.deviceA)
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

    @Test func commitUsesAuthoredSubjectsAndHidesPrivateOnes() throws {
        let fixture = try Fixture()
        let git = Git(root: fixture.deviceA)
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

    @Test func commitDescribesRenamesAndBatches() throws {
        let fixture = try Fixture()
        let git = Git(root: fixture.deviceA)
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

    @Test func commitLeavesOutTheIndexAndLargeFiles() throws {
        let fixture = try Fixture()
        try write(fixture.deviceA, ".reflect/index.sqlite", "index")
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        let big = fixture.deviceA.appendingPathComponent("assets/video.mov")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        try FileHandle(forWritingTo: big).truncate(atOffset: UInt64(Git.maxFileBytes))
        let report = try Git(root: fixture.deviceA).cycle(.push)
        #expect(report.skippedLargeFiles.map(\.path) == ["assets/video.mov"])
        #expect(try headPaths(fixture.deviceA) == ["notes/a.md"])
    }

    @Test func commitWorksWhenTheIgnoreFileAlreadyLeavesOutTheIndex() throws {
        // Reflect writes `/.reflect/` into every graph's .gitignore.
        let fixture = try Fixture()
        try write(fixture.deviceA, ".gitignore", "# Reflect local index + caches (rebuildable; never committed)\n/.reflect/\n")
        try write(fixture.deviceA, ".reflect/index.sqlite", "index")
        try write(fixture.deviceA, "daily/2026-09-25.md", "- today\n")
        _ = try Git(root: fixture.deviceA).cycle(.full)
        #expect(try headPaths(fixture.deviceA) == [".gitignore", "daily/2026-09-25.md"])
    }

    // MARK: Merging

    /// Both devices start from `path` holding `text`, pushed by the first.
    private func shared(_ path: String, _ text: String) throws -> (Fixture, Git, Git, URL) {
        let fixture = try Fixture()
        try write(fixture.deviceA, path, text)
        let a = Git(root: fixture.deviceA)
        _ = try a.cycle(.push)
        let deviceB = try fixture.secondDevice()
        return (fixture, a, Git(root: deviceB), deviceB)
    }

    @Test func conflictingEditsAreCommittedWithLabelledMarkers() throws {
        let (fixture, a, b, deviceB) = try shared("notes/shared.md", "# Shared\n\noriginal line\n")
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

    @Test func editVersusDeleteKeepsTheEdit() throws {
        let (fixture, a, b, deviceB) = try shared("notes/keep.md", "# Keep\n\noriginal\n")
        try write(deviceB, "notes/keep.md", "# Keep\n\nedited on b\n")
        _ = try b.cycle(.push)
        try FileManager.default.removeItem(at: fixture.deviceA.appendingPathComponent("notes/keep.md"))

        let report = try a.cycle(.full)
        #expect(report.conflicted == ["notes/keep.md"])
        #expect(try read(fixture.deviceA, "notes/keep.md").contains("edited on b"))
        #expect(try headPaths(fixture.deviceA).contains("notes/keep.md"))
        #expect(isClean(fixture.deviceA))
    }

    @Test func binaryConflictKeepsBothCopies() throws {
        let fixture = try Fixture()
        let image = fixture.deviceA.appendingPathComponent("assets/img.bin")
        try Data([0, 98, 97, 115, 101, 1]).write(to: image)
        let a = Git(root: fixture.deviceA)
        _ = try a.cycle(.push)
        let deviceB = try fixture.secondDevice()
        try Data([0, 66, 1]).write(to: deviceB.appendingPathComponent("assets/img.bin"))
        _ = try Git(root: deviceB).cycle(.push)
        try Data([0, 65, 1]).write(to: image)

        let report = try a.cycle(.full)
        #expect(Set(report.conflicted) == ["assets/img.bin", "assets/img (conflict).bin"])
        #expect(try Data(contentsOf: image) == Data([0, 65, 1]))
        #expect(try Data(contentsOf: fixture.deviceA.appendingPathComponent("assets/img (conflict).bin")) == Data([0, 66, 1]))
        #expect(isClean(fixture.deviceA))
    }

    @Test func renameRenameKeepsBothNames() throws {
        let (fixture, a, b, deviceB) = try shared("notes/orig.md", "# Original\n\nshared content that travels with the rename\n")
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

    @Test func renameOnOneDeviceMergesWithAnEditOnTheOther() throws {
        let base = "# Meeting Notes\n\n- agenda point one\n- agenda point two\n- agenda point three\n"
        let (fixture, a, b, deviceB) = try shared("notes/01arz3ndektsv4rrffq69g5fav.md", base)
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

    @Test func theSameNoteMadeOnTwoDevicesIsAConflictToReview() throws {
        let (fixture, a, b, deviceB) = try shared("notes/seed.md", "# Seed\n")
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

    @Test func aPushTurnedAwayMergesAndTriesAgain() throws {
        let (fixture, a, b, deviceB) = try shared("daily/2026-06-23.md", "- one\n")
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

    @Test func aDetachedHeadIsRefused() throws {
        let fixture = try Fixture()
        try write(fixture.deviceA, "notes/a.md", "# A\n")
        let git = Git(root: fixture.deviceA)
        _ = try git.cycle(.push)
        try git.run(["checkout", "--quiet", "--detach"])
        #expect(throws: GitError.self) { try git.cycle(.full) }
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
