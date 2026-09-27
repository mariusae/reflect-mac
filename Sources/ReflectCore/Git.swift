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
        guard backend.hasRemote("origin") else { return report }  // the commit is the whole cycle

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
        let (behind, ahead) = try divergence()
        guard behind > 0 else { return .upToDate }
        let before = backend.head()

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
                    report.conflicted += try resolveConflicts(unmerged)
                    try backend.commitMerge(message: "Merge changes from other devices (conflicts to review)")
                } catch {
                    backend.abortMerge()
                    throw error
                }
                kind = .mergedWithConflicts
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
                    let base = try stages[1].map(backend.blob) ?? Data()
                    try write(try backend.mergeText(ours: mine, base: base, theirs: other,
                                                    labels: (Self.ourLabel, "base", Self.theirLabel)), to: file)
                    try backend.add(topLevelPaths: [path])
                    conflicted.append(path)
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
        if let what = try backend.operationInProgress() {
            throw GitError(message: "The repository is in the middle of \(what); finish or abort it with git first.")
        }
        _ = try branch()
    }
}
