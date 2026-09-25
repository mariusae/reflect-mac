import Foundation

/// What a sync did, for whoever asked. Empty when nothing moved.
public struct SyncReport: Sendable, CustomStringConvertible {
    public var parts: [String] = []
    /// Files a merge wrote, so what is on screen may be out of date.
    public var changed: [String] = []
    /// Files a merge left conflict markers in, or a conflict copy beside.
    public var conflicted: [String] = []
    /// Files whose changes were too large to commit, with their sizes.
    public var skippedLargeFiles: [(path: String, size: Int)] = []
    public var pulled: Bool { !changed.isEmpty }
    public var quiet: Bool { parts.isEmpty }
    public var description: String { parts.joined(separator: ", ") }
}

public struct GitError: Error, LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

/// The graph's repository, kept in step as Reflect keeps it.
///
/// A cycle commits everything written, then — on a full sync — fetches and
/// merges what other devices pushed, then pushes. A push turned away because
/// another device got there first is met with another fetch and merge, up to
/// three times. A merge never stops the sync: where both sides changed a
/// note, both are written into it between conflict markers and the merge is
/// committed as it is, for the note's writer to settle; the repository is
/// never left in the middle of a merge. These are the rules of Reflect's
/// sync engine and its `merge.rs`, so the two apps can share a repository.
///
/// Everything runs through the `git` command line, one operation at a time
/// on a serial queue, never on the main thread.
public final class Git: @unchecked Sendable {
    public let root: URL
    private let queue = DispatchQueue(label: "reflect.git", qos: .utility)

    /// A cycle's reach: `push` commits and pushes what was written, without
    /// asking the remote for anything unless it has moved on; `full` also
    /// takes in what other devices wrote.
    public enum Mode: Sendable { case push, full }

    /// Reflect's labels for the two sides of a conflict.
    public static let ourLabel = ConflictMarkers.ourLabel
    public static let theirLabel = ConflictMarkers.theirLabel
    /// Files this large are not committed: a remote like GitHub refuses
    /// them, and one video must not stop the backup of everything else.
    public static let maxFileBytes = 95 * 1024 * 1024
    static let maxPushAttempts = 3

    /// The repository the graph sits in, or nil when it sits in none.
    public static func open(_ root: URL) -> Git? {
        let git = Git(root: root)
        guard (try? git.run(["rev-parse", "--show-toplevel"])) != nil else { return nil }
        return git
    }

    init(root: URL) { self.root = root }

    /// One cycle of the sync.
    public func sync(_ mode: Mode) async throws -> SyncReport {
        try await turn { try self.cycle(mode) }
    }

    // MARK: The cycle

    private func turn<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    func cycle(_ mode: Mode) throws -> SyncReport {
        var report = SyncReport()
        let commit = try commitAll(fallback: "Update notes")
        report.skippedLargeFiles = commit.skipped
        if let message = commit.message { report.parts.append("committed “\(message)”") }
        guard hasOrigin else { return report }  // the commit is the whole cycle

        if mode == .push {
            // Nothing written and nothing waiting: no need to ask the remote.
            if !commit.committed && commit.ahead == 0 { return report }
        } else {
            try fetch()
            let ahead = (try? divergence().ahead) ?? 0
            let merged = try mergeRemote(into: &report)
            let local = commit.committed || ahead > 0
            if !local && (merged == .upToDate || merged == .fastForward) { return report }
        }
        for _ in 0..<Self.maxPushAttempts {
            switch try push() {
            case .pushed:
                report.parts.append("pushed")
                return report
            case .rejected(let message):
                throw GitError(message: "The remote rejected the backup: \(message)")
            case .behind:
                // Another device pushed first: take its changes, and try again.
                try fetch()
                _ = try mergeRemote(into: &report)
            }
        }
        throw GitError(message: "The backup repository kept changing while syncing; it will be tried again on the next edit.")
    }

    // MARK: Committing

    struct Commit {
        var committed: Bool
        var message: String?
        var ahead: Int
        var skipped: [(path: String, size: Int)]
    }

    private func commitAll(fallback: String) throws -> Commit {
        try ensureCleanState()
        // `.reflect/` is the index, rebuilt on each device; it must never be
        // committed, whatever the ignore file says. It is taken back out
        // rather than left out: naming an ignored path to `git add`, even to
        // exclude it, is an error.
        try run(["add", "-A", "--", "."])
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".reflect").path) {
            try run(["reset", "--quiet", "--", ".reflect"])
        }
        let skipped = try withholdLargeFiles()
        let changes = try stagedChanges()
        guard !changes.isEmpty else {
            return Commit(committed: false, message: nil, ahead: (try? divergence().ahead) ?? 0, skipped: skipped)
        }
        let message = describe(changes, fallback: fallback)
        try run(["commit", "--quiet", "--no-verify", "-m", message])
        return Commit(committed: true, message: message, ahead: (try? divergence().ahead) ?? 0, skipped: skipped)
    }

    /// Unstages changed files at or over the size limit, and says which.
    private func withholdLargeFiles() throws -> [(path: String, size: Int)] {
        let staged = try run(["diff", "--cached", "--relative", "-z", "--name-only", "--diff-filter=AMRCT"])
            .split(separator: "\0").map(String.init)
        var skipped: [(path: String, size: Int)] = []
        for path in staged {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            guard let size = (attributes?[.size] as? NSNumber)?.intValue, size >= Self.maxFileBytes else { continue }
            try run(["reset", "--quiet", "--", path])
            skipped.append((path, size))
        }
        return skipped
    }

    /// What the index would commit, renames found.
    func stagedChanges() throws -> [CommitMessage.Change] {
        let status = try run(["diff", "--cached", "--relative", "-z", "--name-status", "-M"])
        var fields = status.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)[...]
        var changes: [CommitMessage.Change] = []
        while let code = fields.popFirst(), !code.isEmpty {
            switch code.first {
            case "A":
                if let path = fields.popFirst() { changes.append(.init(action: .add, path: path)) }
            case "C":
                _ = fields.popFirst()
                if let path = fields.popFirst() { changes.append(.init(action: .add, path: path)) }
            case "D":
                if let path = fields.popFirst() { changes.append(.init(action: .delete, path: path)) }
            case "R":
                if let old = fields.popFirst(), let new = fields.popFirst() {
                    changes.append(.init(action: .rename, path: new, oldPath: old))
                }
            default:
                if let path = fields.popFirst() { changes.append(.init(action: .update, path: path)) }
            }
        }
        return changes
    }

    private func describe(_ changes: [CommitMessage.Change], fallback: String) -> String {
        // Each note's text as staged, and as it was, read in one go.
        var requests: [(revision: String, path: String)] = []
        for change in changes where change.path.hasSuffix(".md") {
            requests.append((change.action == .delete ? "HEAD" : "", change.path))
            if let old = change.oldPath { requests.append(("HEAD", old)) }
        }
        var lookup: [String: String] = [:]
        for (request, text) in zip(requests, contents(requests)) {
            if let text { lookup["\(request.revision):\(request.path)"] = text }
        }
        return CommitMessage.describe(changes, fallback: fallback) { path, old in
            lookup["\(old ? "HEAD" : ""):\(path)"]
        }
    }

    /// Files as they stand at revisions (an empty revision is the index),
    /// through one `git cat-file --batch`. A file that cannot be read is nil.
    func contents(_ requests: [(revision: String, path: String)]) -> [String?] {
        guard !requests.isEmpty else { return [] }
        let input = requests.map { "\($0.revision):./\($0.path)\n" }.joined()
        guard let output = try? runData(["cat-file", "--batch"], input: Data(input.utf8)) else {
            return requests.map { _ in nil }
        }
        var results: [String?] = []
        var index = output.startIndex
        for _ in requests {
            guard let newline = output[index...].firstIndex(of: 0x0a) else { results.append(nil); continue }
            let header = String(decoding: output[index..<newline], as: UTF8.self).split(separator: " ")
            index = output.index(after: newline)
            guard header.count == 3, header[1] != "missing", let size = Int(header[2]) else {
                results.append(nil)
                continue
            }
            let end = output.index(index, offsetBy: size)
            results.append(String(decoding: output[index..<end], as: UTF8.self))
            index = output.index(after: end)
        }
        return results
    }

    // MARK: The remote

    private var hasOrigin: Bool {
        ((try? run(["remote"])) ?? "").split(separator: "\n").contains("origin")
    }

    private func branch() throws -> String {
        guard let name = try? run(["symbolic-ref", "--quiet", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw GitError(message: "The repository is on a detached HEAD; check out a branch with git first.")
        }
        return name
    }

    private func remoteRef() throws -> String { "refs/remotes/origin/\(try branch())" }

    private func remoteExists() throws -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", try remoteRef()])) != nil
    }

    private func fetch() throws {
        do {
            try run(["fetch", "--quiet", "origin"], timeout: 60)
        } catch {
            throw GitError(message: "Fetching failed: \(error.localizedDescription)")
        }
    }

    /// How far this branch and origin's copy of it have gone apart.
    private func divergence() throws -> (behind: Int, ahead: Int) {
        guard try remoteExists() else {
            let count = Int((try? run(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") ?? 0
            return (0, count)
        }
        let counts = try run(["rev-list", "--left-right", "--count", "\(try remoteRef())...HEAD"])
        let fields = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 2 else { throw GitError(message: "git rev-list said \(counts)") }
        return (fields[0], fields[1])
    }

    enum PushOutcome { case pushed, behind, rejected(String) }

    private func push() throws -> PushOutcome {
        let branch = try branch()
        do {
            try run(["push", "--porcelain", "origin", "refs/heads/\(branch):refs/heads/\(branch)"], timeout: 60)
            return .pushed
        } catch let error as GitError {
            let lowered = error.message.lowercased()
            if lowered.contains("non-fast-forward") || lowered.contains("fetch first") || lowered.contains("cannot lock ref") {
                return .behind
            }
            return .rejected(error.message)
        }
    }

    // MARK: Merging

    public enum MergeKind: Equatable, Sendable { case upToDate, fastForward, merged, mergedWithConflicts }

    /// Takes in origin's copy of the branch. Everything here was committed
    /// first, so nothing unsaved is in the way.
    private func mergeRemote(into report: inout SyncReport) throws -> MergeKind {
        try ensureCleanState()
        // A new, empty remote has nothing to merge until the first push.
        guard try remoteExists() else { return .upToDate }
        let remote = try remoteRef()
        let (behind, ahead) = try divergence()
        guard behind > 0 else { return .upToDate }
        let before = (try? run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""

        let kind: MergeKind
        if ahead == 0 || before.isEmpty {
            try run(["merge", "--ff-only", "--quiet", remote])
            kind = .fastForward
        } else {
            do {
                try run(["-c", "merge.conflictStyle=merge", "merge", "--no-edit", "--quiet",
                         "-m", "Merge changes from other devices", remote])
                kind = .merged
            } catch {
                let unmerged = (try? unmergedEntries()) ?? [:]
                guard !unmerged.isEmpty else {
                    abortMerge()
                    throw GitError(message: "Merging failed: \(error.localizedDescription)")
                }
                // From here the repository is mid-merge; whatever happens, it
                // must not be left so, or every later sync would stop.
                do {
                    report.conflicted += try resolveConflicts(unmerged)
                    try run(["commit", "--quiet", "--no-verify", "--no-edit",
                             "-m", "Merge changes from other devices (conflicts to review)"])
                } catch {
                    abortMerge()
                    throw error
                }
                kind = .mergedWithConflicts
            }
        }
        if !before.isEmpty {
            report.changed += (try? run(["diff", "--relative", "-z", "--name-only", before, "HEAD"]))?
                .split(separator: "\0").map(String.init) ?? []
        }
        report.parts.append("\(behind) \(behind == 1 ? "change" : "changes") pulled"
                            + (kind == .mergedWithConflicts ? " with conflicts to review" : ""))
        return kind
    }

    private func abortMerge() {
        _ = try? run(["merge", "--abort"])
    }

    /// The index's conflicts: for each path, the blob at each stage — 1 the
    /// common ancestor, 2 this device's, 3 the other device's.
    private func unmergedEntries() throws -> [String: [Int: String]] {
        var entries: [String: [Int: String]] = [:]
        for record in try run(["ls-files", "-u", "-z", "--full-name"]).split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { continue }
            entries[String(record[record.index(after: tab)...]), default: [:]][stage] = String(fields[1])
        }
        return entries
    }

    /// Settles each conflict so the merge can be committed, as Reflect does:
    ///
    /// - both changed a text file: both sides into the file, between markers;
    /// - one changed what the other deleted: the changed file is kept, since
    ///   a sync must never quietly delete what someone wrote;
    /// - both changed a binary file: this device's stays, and the other's is
    ///   put beside it as `name (conflict).ext`;
    /// - both deleted it: it stays deleted.
    ///
    /// Returns the paths, from the repository's top, that need a person.
    private func resolveConflicts(_ entries: [String: [Int: String]]) throws -> [String] {
        let top = try run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let topURL = URL(fileURLWithPath: top)
        var conflicted: [String] = []
        for (path, stages) in entries.sorted(by: { $0.key < $1.key }) {
            let file = topURL.appendingPathComponent(path)
            switch (stages[2], stages[3]) {
            case let (ours?, theirs?):
                let mine = try blob(ours), other = try blob(theirs)
                if Self.isBinary(mine) || Self.isBinary(other) {
                    let copy = Self.conflictCopyPath(path)
                    try write(mine, to: file)
                    try write(other, to: topURL.appendingPathComponent(copy))
                    try run(["-C", top, "add", "--", path, copy])
                    conflicted += [path, copy]
                } else {
                    let base = try stages[1].map(blob) ?? Data()
                    try write(try mergeFile(ours: mine, base: base, theirs: other), to: file)
                    try run(["-C", top, "add", "--", path])
                    conflicted.append(path)
                }
            case let (kept?, nil), let (nil, kept?):
                try write(try blob(kept), to: file)
                try run(["-C", top, "add", "--", path])
                conflicted.append(path)
            case (nil, nil):
                try? FileManager.default.removeItem(at: file)
                try run(["-C", top, "rm", "--cached", "--quiet", "--ignore-unmatch", "--", path])
            }
        }
        return conflicted
    }

    private func blob(_ id: String) throws -> Data {
        try runData(["cat-file", "blob", id])
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Both sides in one text, differing lines between markers labelled
    /// `this device` and `other device`.
    private func mergeFile(ours: Data, base: Data, theirs: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["ours", "base", "theirs"].map { directory.appendingPathComponent($0) }
        for (file, data) in zip(files, [ours, base, theirs]) { try data.write(to: file) }
        // merge-file exits with the number of conflicts; any number will do.
        return try runData(["merge-file", "-p", "-L", Self.ourLabel, "-L", "base", "-L", Self.theirLabel] + files.map(\.path),
                           allowingStatus: 0...127)
    }

    /// Git's own test: a NUL in the first 8000 bytes.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }

    /// `assets/img.png` → `assets/img (conflict).png`. Only the file's own
    /// name is split, so a dot in a directory's name stays put.
    public static func conflictCopyPath(_ path: String) -> String {
        let slash = path.lastIndex(of: "/")
        let directory = slash.map { String(path[...$0]) } ?? ""
        let file = slash.map { String(path[path.index(after: $0)...]) } ?? path
        if let dot = file.lastIndex(of: "."), dot != file.startIndex {
            return directory + file[..<dot] + " (conflict)" + file[dot...]
        }
        return directory + file + " (conflict)"
    }

    /// Refuses a repository some other tool left in the middle of something:
    /// guessing there could destroy what it was doing.
    private func ensureCleanState() throws {
        let states = ["MERGE_HEAD": "a merge", "CHERRY_PICK_HEAD": "a cherry-pick", "REVERT_HEAD": "a revert",
                      "rebase-merge": "a rebase", "rebase-apply": "a rebase", "BISECT_LOG": "a bisect"]
        for (name, what) in states {
            let path = try run(["rev-parse", "--git-path", name]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                throw GitError(message: "The repository is in the middle of \(what); finish or abort it with git first.")
            }
        }
        _ = try branch()
    }

    // MARK: Running git

    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        // An app launched from the Finder has launchd's PATH, which knows
        // nothing of Homebrew — where credential helpers and git-lfs live.
        let extra = ["/opt/homebrew/bin", "/usr/local/bin"]
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extra + [path]).joined(separator: ":")
        // Nobody is at a terminal to answer a prompt; fail instead of hanging.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Merge and commit messages are given; no editor is to be opened.
        env["GIT_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        return env
    }()

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        String(decoding: try runData(arguments, timeout: timeout), as: UTF8.self)
    }

    func runData(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 30,
                 allowingStatus allowed: ClosedRange<Int32> = 0...0) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = Git.environment
        let stdin = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        // Drain both pipes as they fill, so a chatty command cannot block on
        // a full pipe while we wait for it to exit.
        var output = Data(), errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            output = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errors = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let started = Date()
        try process.run()
        if let input {
            DispatchQueue.global().async {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let deadline = DispatchWorkItem { [weak process] in process?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        group.wait()

        let succeeded = allowed.contains(process.terminationStatus) && process.terminationReason == .exit
        let said = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let command = "git " + arguments.joined(separator: " ")
        let timing = String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000)
        guard succeeded else {
            let detail = [errors, output].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
            let reason = process.terminationReason == .uncaughtSignal ? "timed out" : detail
            // Some commands are asked in order to fail — "is there such a
            // branch?" — so a failure here is noted, not an error; the sync
            // says when one is.
            Log.shared.info("git", "\(command) — exit \(process.terminationStatus), \(timing)", detail: reason)
            throw GitError(message: "\(command): \(reason)")
        }
        Log.shared.info("git", "\(command) — \(timing)", detail: said)
        return output
    }
}
