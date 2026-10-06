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
    public init(message: String) { self.message = message }
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
/// Each step is done by a `GitBackend` — the `git` command line on the Mac —
/// one operation at a time on a serial queue, never on the main thread.
public final class Git: @unchecked Sendable {
    public let backend: any GitBackend
    public var root: URL { backend.root }
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

    public init(backend: any GitBackend) { self.backend = backend }

    /// One cycle of the sync.
    public func sync(_ mode: Mode) async throws -> SyncReport {
        try await turn { try self.cycle(mode) }
    }

    /// Asks a cycle under way to stop at its next safe point — between
    /// steps, never within a merge — as when the phone takes the app's time
    /// in the background back. What it committed stays; the next cycle goes on.
    public func stop() {
        lock.withLock { stopRequested = true }
    }

    private let lock = NSLock()
    private var stopRequested = false
    /// Whether the history's end was looked for, this run.
    private var checkedHistory = false

    /// Where a cycle may stop: between steps, everything committed so far
    /// kept, nothing left half done.
    private func checkpoint() throws {
        if lock.withLock({ stopRequested }) { throw GitError(message: "The sync stopped, to go on next time.") }
    }

    /// How many backups of the branch, from before merges, are kept.
    static let backupsKept = 30
    /// Where they are: references never pushed, never fetched.
    static let backupPrefix = "refs/sync-backups/"
    /// A lock older than this is left over from a git that is gone.
    static let staleLockAge: TimeInterval = 90

    // MARK: The cycle

    private func turn<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    func cycle(_ mode: Mode) throws -> SyncReport {
        lock.withLock { stopRequested = false }
        var report = SyncReport()
        report.parts += try repair()
        let commit = try commitAll(fallback: "Update notes")
        report.skippedLargeFiles = commit.skipped
        if let message = commit.message { report.parts.append("committed “\(message)”") }
        guard backend.hasRemote("origin") else { return report }  // the commit is the whole cycle

        if mode == .push {
            // Nothing written and nothing waiting: no need to ask the remote.
            if !commit.committed && commit.ahead == 0 { return report }
        } else {
            try checkpoint()
            try fetch()
            try checkpoint()
            let ahead = (try? divergence().ahead) ?? 0
            let merged = try mergeRemote(into: &report)
            let local = commit.committed || ahead > 0
            if !local && (merged == .upToDate || merged == .fastForward) { return report }
        }
        for _ in 0..<Self.maxPushAttempts {
            try checkpoint()
            switch try backend.push(branch: try branch()) {
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
        try backend.stageAll()
        let skipped = try withholdLargeFiles()
        let changes = try backend.stagedChanges()
        guard !changes.isEmpty else {
            return Commit(committed: false, message: nil, ahead: (try? divergence().ahead) ?? 0, skipped: skipped)
        }
        let message = describe(changes, fallback: fallback)
        try backend.commit(message: message)
        return Commit(committed: true, message: message, ahead: (try? divergence().ahead) ?? 0, skipped: skipped)
    }

    /// Unstages changed files at or over the size limit, and says which.
    private func withholdLargeFiles() throws -> [(path: String, size: Int)] {
        var skipped: [(path: String, size: Int)] = []
        for path in try backend.stagedWrittenPaths() {
            let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            guard let size = (attributes?[.size] as? NSNumber)?.intValue, size >= Self.maxFileBytes else { continue }
            try backend.unstage(path)
            skipped.append((path, size))
        }
        return skipped
    }

    private func describe(_ changes: [CommitMessage.Change], fallback: String) -> String {
        // Each note's text as staged, and as it was, read in one go.
        var requests: [(revision: String, path: String)] = []
        for change in changes where change.path.hasSuffix(".md") {
            requests.append((change.action == .delete ? "HEAD" : "", change.path))
            if let old = change.oldPath { requests.append(("HEAD", old)) }
        }
        var lookup: [String: String] = [:]
        for (request, text) in zip(requests, backend.contents(requests)) {
            if let text { lookup["\(request.revision):\(request.path)"] = text }
        }
        return CommitMessage.describe(changes, fallback: fallback) { path, old in
            lookup["\(old ? "HEAD" : ""):\(path)"]
        }
    }

    // MARK: The remote

    private func branch() throws -> String {
        guard let name = try backend.currentBranch() else {
            throw GitError(message: "The repository is on a detached HEAD; check out a branch with git first.")
        }
        return name
    }

    private func remoteRef() throws -> String { "refs/remotes/origin/\(try branch())" }

    private func fetch() throws {
        do {
            try backend.fetch()
        } catch {
            throw GitError(message: "Fetching failed: \(error.localizedDescription)")
        }
    }

    /// How far this branch and origin's copy of it have gone apart.
    private func divergence() throws -> (behind: Int, ahead: Int) {
        let remote = try remoteRef()
        guard backend.resolves(remote) else { return (0, backend.commitCount()) }
        return try backend.divergence(remote)
    }

    // MARK: Merging

    public enum MergeKind: Equatable, Sendable { case upToDate, fastForward, merged, mergedWithConflicts }

    /// Takes in origin's copy of the branch. Everything here was committed
    /// first, so nothing unsaved is in the way.
    private func mergeRemote(into report: inout SyncReport) throws -> MergeKind {
        try ensureCleanState()
        let remote = try remoteRef()
        // A new, empty remote has nothing to merge until the first push.
        guard backend.resolves(remote) else { return .upToDate }
        try findCommonHistory(with: remote)
        let (behind, ahead) = try divergence()
        guard behind > 0 else { return .upToDate }
        let before = backend.head()
        if let before { backUp(before) }

        let kind: MergeKind
        if ahead == 0 || before == nil {
            try backend.fastForward(to: remote)
            kind = .fastForward
        } else {
            switch try backend.merge(remote, message: "Merge changes from other devices") {
            case .merged:
                kind = .merged
            case .conflicted(let unmerged):
                // From here the repository is mid-merge; whatever happens, it
                // must not be left so, or every later sync would stop.
                do {
                    let left = try resolveConflicts(unmerged)
                    report.conflicted += left
                    try backend.commitMerge(message: left.isEmpty ? "Merge changes from other devices"
                                                                  : "Merge changes from other devices (conflicts to review)")
                } catch {
                    backend.abortMerge()
                    throw error
                }
                kind = report.conflicted.isEmpty ? .merged : .mergedWithConflicts
            }
        }
        if let before {
            report.changed += backend.changedPaths(from: before, to: "HEAD")
        }
        report.parts.append("\(behind) \(behind == 1 ? "change" : "changes") pulled"
                            + (kind == .mergedWithConflicts ? " with conflicts to review" : ""))
        return kind
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
        let topURL = try backend.topLevel()
        var conflicted: [String] = []
        for (path, stages) in entries.sorted(by: { $0.key < $1.key }) {
            let file = topURL.appendingPathComponent(path)
            switch (stages[2], stages[3]) {
            case let (ours?, theirs?):
                let mine = try backend.blob(ours), other = try backend.blob(theirs)
                if Self.isBinary(mine) || Self.isBinary(other) {
                    let copy = Self.conflictCopyPath(path)
                    try write(mine, to: file)
                    try write(other, to: topURL.appendingPathComponent(copy))
                    try backend.add(topLevelPaths: [path, copy])
                    conflicted += [path, copy]
                } else {
                    // Merged again, line ends aside: a space one device left
                    // at a line's end and the other took off is no change, and
                    // must not pull the line into the conflict — where keeping
                    // both sides would write it twice.
                    let base = try stages[1].map(backend.blob) ?? Data()
                    let merged = try backend.mergeText(ours: Self.trimmingLineEnds(mine), base: Self.trimmingLineEnds(base),
                                                       theirs: Self.trimmingLineEnds(other),
                                                       labels: (Self.ourLabel, "base", Self.theirLabel))
                    try write(merged, to: file)
                    try backend.add(topLevelPaths: [path])
                    if ConflictMarkers.detect(String(decoding: merged, as: UTF8.self)) { conflicted.append(path) }
                }
            case let (kept?, nil), let (nil, kept?):
                try write(try backend.blob(kept), to: file)
                try backend.add(topLevelPaths: [path])
                conflicted.append(path)
            case (nil, nil):
                try? FileManager.default.removeItem(at: file)
                try backend.remove(topLevelPath: path)
            }
        }
        return conflicted
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A text with the spaces and tabs at its lines' ends taken off.
    static func trimmingLineEnds(_ data: Data) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var line = line
            let carriage = line.hasSuffix("\r")
            if carriage { line = line.dropLast() }
            while let last = line.last, last == " " || last == "\t" { line = line.dropLast() }
            return carriage ? line + "\r" : line
        }
        return Data(lines.joined(separator: "\n").utf8)
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

    // MARK: Putting things right

    /// Puts right what a crash, a killed git or the system taking the app's
    /// time away can leave: locks no git holds, an operation in the middle,
    /// HEAD off its branch. A sync must never stop for good over something
    /// it can put right itself — on the phone there is no `git` to do it
    /// with. Says what it did.
    func repair() throws -> [String] {
        var done: [String] = []
        if let directory = try? backend.gitDirectory() {
            let removed = Self.removeStaleLocks(in: directory, olderThan: Self.staleLockAge)
            if !removed.isEmpty { done.append("cleared \(removed.count) stale \(removed.count == 1 ? "lock" : "locks")") }
        }
        // Once a run: a clone whose note of where its history stops was lost
        // — libgit2 lost it on fetches — noted again, or no merge can count back.
        if !checkedHistory {
            checkedHistory = true
            if let noted = try? backend.markMissingHistory(), noted > 0 {
                done.append("noted where the history stops")
            }
        }
        if let what = try backend.operationInProgress() {
            // Ours, left by a cycle that never finished — this sync settles
            // and commits every merge it starts — or another tool's: left as
            // its own --abort leaves it, nothing written lost.
            if let head = backend.head() { backUp(head) }
            try backend.abandonOperation()
            if let still = try backend.operationInProgress() {
                throw GitError(message: "The repository is in the middle of \(still), and it could not be left.")
            }
            done.append("left \(what) that was never finished")
            Log.shared.info("git", "Left \(what) that was never finished")
        }
        if try backend.currentBranch() == nil, let head = backend.head() {
            let branches = backend.branches()
            // A branch at HEAD, or one HEAD has gone on from: HEAD put back on
            // it, nothing else moved. One that has gone elsewhere is a person's
            // doing, and theirs to settle.
            let preferred = ["main", "master"]
            let name = branches.first { $0.value == head }?.key
                ?? (preferred + branches.keys.sorted()).first { name in
                    branches[name].map { backend.isAncestor($0, of: head) } ?? false
                }
            guard let name else {
                throw GitError(message: "The repository is on a detached HEAD that no branch leads to; check out a branch with git first.")
            }
            backUp(head)
            try backend.attachHead(to: name, at: head)
            done.append("put HEAD back on \(name)")
            Log.shared.info("git", "Put HEAD back on \(name)")
        }
        return done
    }

    /// Removes the lock files git leaves when it is stopped midway, once
    /// they are old enough that no git can still hold them. Says which.
    static func removeStaleLocks(in directory: URL, olderThan age: TimeInterval) -> [String] {
        let manager = FileManager.default
        var removed: [String] = []
        var candidates = ["index.lock", "HEAD.lock", "ORIG_HEAD.lock", "config.lock", "packed-refs.lock", "shallow.lock", "FETCH_HEAD.lock"]
            .map { directory.appendingPathComponent($0) }
        if let walker = manager.enumerator(at: directory.appendingPathComponent("refs"), includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "lock" { candidates.append(url) }
        }
        for url in candidates {
            guard let modified = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) > age else { continue }
            if (try? manager.removeItem(at: url)) != nil {
                removed.append(url.lastPathComponent)
                Log.shared.info("git", "Removed a stale lock, \(url.path)")
            }
        }
        return removed
    }

    /// Keeps the branch as it is now in a reference of its own, never
    /// pushed: whatever a merge then does, it can be undone. The oldest
    /// beyond `backupsKept` are let go.
    private func backUp(_ commit: String) {
        let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
        try? backend.setReference(Self.backupPrefix + stamp, to: commit)
        let all = backend.references(withPrefix: Self.backupPrefix).sorted()
        for old in all.dropLast(Self.backupsKept) { backend.deleteReference(old) }
    }

    /// The backups kept from before merges, newest first: their names and
    /// when each was made.
    public func backups() -> [(reference: String, date: Date)] {
        backend.references(withPrefix: Self.backupPrefix).sorted(by: >).compactMap { name in
            guard let ms = Double(name.dropFirst(Self.backupPrefix.count)) else { return nil }
            return (name, Date(timeIntervalSince1970: ms / 1000))
        }
    }

    /// A shallow clone — the phone's, of the latest commit alone — is
    /// fine till the remote moves on; then counting and merging walk back
    /// through history it lacks, and libgit2 stops at the first commit it
    /// cannot find. So the rest is fetched, once, the first time it does.
    private func findCommonHistory(with remote: String) throws {
        guard backend.isShallow(), backend.head() != nil, !backend.isAncestor(remote, of: "HEAD") else { return }
        try checkpoint()
        // libgit2 forgets the clone is shallow before it has the history,
        // and a fetch that fails then leaves a repository that thinks it has
        // commits it lacks — which no git can read after. The note of where
        // the history stops is kept, and put back if the fetch fails.
        let note = (try? backend.gitDirectory())?.appendingPathComponent("shallow")
        let kept = note.flatMap { try? Data(contentsOf: $0) }
        do {
            try backend.deepen(by: nil)
        } catch {
            if let note, let kept { try? kept.write(to: note, options: .atomic) }
            throw GitError(message: "Fetching the rest of the history failed: \(error.localizedDescription)")
        }
    }

    /// Refuses a repository some other tool left in the middle of something:
    /// guessing there could destroy what it was doing.
    private func ensureCleanState() throws {
        if let what = try backend.operationInProgress() {
            throw GitError(message: "The repository is in the middle of \(what); finish or abort it with git first.")
        }
        _ = try branch()
    }
}
