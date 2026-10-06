#if os(macOS)
import Foundation

/// The sync's steps done with the `git` command line, as the Mac has it.
public final class CommandLineGit: GitBackend, @unchecked Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The repository the graph sits in, or nil when it sits in none.
    public static func open(_ root: URL) -> CommandLineGit? {
        let git = CommandLineGit(root: root)
        guard (try? git.run(["rev-parse", "--show-toplevel"])) != nil else { return nil }
        return git
    }

    public func topLevel() throws -> URL {
        URL(fileURLWithPath: try run(["rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func operationInProgress() throws -> String? {
        let states = ["MERGE_HEAD": "a merge", "CHERRY_PICK_HEAD": "a cherry-pick", "REVERT_HEAD": "a revert",
                      "rebase-merge": "a rebase", "rebase-apply": "a rebase", "BISECT_LOG": "a bisect"]
        for (name, what) in states {
            let path = try run(["rev-parse", "--git-path", name]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return what }
        }
        return nil
    }

    public func currentBranch() throws -> String? {
        guard let name = try? run(["symbolic-ref", "--quiet", "--short", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    public func head() -> String? {
        let id = (try? run(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        return id.isEmpty ? nil : id
    }

    public func resolves(_ reference: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", reference])) != nil
    }

    public func hasRemote(_ name: String) -> Bool {
        ((try? run(["remote"])) ?? "").split(separator: "\n").contains(Substring(name))
    }

    public func commitCount() -> Int {
        Int((try? run(["rev-list", "--count", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "") ?? 0
    }

    public func divergence(_ reference: String) throws -> (behind: Int, ahead: Int) {
        let counts = try run(["rev-list", "--left-right", "--count", "\(reference)...HEAD"])
        let fields = counts.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard fields.count == 2 else { throw GitError(message: "git rev-list said \(counts)") }
        return (fields[0], fields[1])
    }

    // MARK: The index

    public func stageAll() throws {
        // `.reflect/` must never be committed, whatever the ignore file
        // says. It is taken back out rather than left out: naming an
        // ignored path to `git add`, even to exclude it, is an error.
        try run(["add", "-A", "--", "."])
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".reflect").path) {
            try run(["reset", "--quiet", "--", ".reflect"])
        }
    }

    public func stagedWrittenPaths() throws -> [String] {
        try run(["diff", "--cached", "--relative", "-z", "--name-only", "--diff-filter=AMRCT"])
            .split(separator: "\0").map(String.init)
    }

    public func unstage(_ path: String) throws {
        try run(["reset", "--quiet", "--", path])
    }

    public func stagedChanges() throws -> [CommitMessage.Change] {
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

    /// Read through one `git cat-file --batch`.
    public func contents(_ requests: [(revision: String, path: String)]) -> [String?] {
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

    public func commit(message: String) throws {
        try run(["commit", "--quiet", "--no-verify", "-m", message])
    }

    // MARK: The remote

    public func fetch() throws {
        try run(["fetch", "--quiet", "origin"], timeout: 60)
    }

    public func push(branch: String) throws -> GitPushOutcome {
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

    public func fastForward(to reference: String) throws {
        try run(["merge", "--ff-only", "--quiet", reference])
    }

    public func merge(_ reference: String, message: String) throws -> GitMergeOutcome {
        do {
            try run(["-c", "merge.conflictStyle=merge", "merge", "--no-edit", "--quiet", "-m", message, reference])
            return .merged
        } catch {
            let unmerged = (try? unmergedEntries()) ?? [:]
            guard !unmerged.isEmpty else {
                abortMerge()
                throw GitError(message: "Merging failed: \(error.localizedDescription)")
            }
            return .conflicted(unmerged)
        }
    }

    public func abortMerge() {
        _ = try? run(["merge", "--abort"])
    }

    public func commitMerge(message: String) throws {
        try run(["commit", "--quiet", "--no-verify", "--no-edit", "-m", message])
    }

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

    public func blob(_ id: String) throws -> Data {
        try runData(["cat-file", "blob", id])
    }

    public func add(topLevelPaths paths: [String]) throws {
        try run(["-C", try topLevel().path, "add", "--"] + paths)
    }

    public func remove(topLevelPath path: String) throws {
        try run(["-C", try topLevel().path, "rm", "--cached", "--quiet", "--ignore-unmatch", "--", path])
    }

    public func mergeText(ours: Data, base: Data, theirs: Data, labels: (ours: String, base: String, theirs: String)) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["ours", "base", "theirs"].map { directory.appendingPathComponent($0) }
        for (file, data) in zip(files, [ours, base, theirs]) { try data.write(to: file) }
        // merge-file exits with the number of conflicts; any number will do.
        return try runData(["merge-file", "-p", "-L", labels.ours, "-L", labels.base, "-L", labels.theirs] + files.map(\.path),
                           allowingStatus: 0...127)
    }

    public func changedPaths(from: String, to: String) -> [String] {
        (try? run(["diff", "--relative", "-z", "--name-only", from, to]))?.split(separator: "\0").map(String.init) ?? []
    }

    // MARK: Putting things right

    public func gitDirectory() throws -> URL {
        URL(fileURLWithPath: try run(["rev-parse", "--absolute-git-dir"]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func abandonOperation() throws {
        switch try operationInProgress() {
        case "a merge"?:
            if (try? run(["merge", "--abort"])) == nil { try run(["reset", "--merge"]) }
        case "a cherry-pick"?: try run(["cherry-pick", "--abort"])
        case "a revert"?: try run(["revert", "--abort"])
        case "a rebase"?: try run(["rebase", "--abort"])
        case "a bisect"?: try run(["bisect", "reset"])
        default: break
        }
    }

    public func branches() -> [String: String] {
        var found: [String: String] = [:]
        for line in ((try? run(["for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads"])) ?? "").split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { found[String(parts[1])] = String(parts[0]) }
        }
        return found
    }

    public func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        (try? run(["merge-base", "--is-ancestor", ancestor, descendant])) != nil
    }

    public func attachHead(to branch: String, at commit: String) throws {
        try run(["update-ref", "refs/heads/\(branch)", commit])
        try run(["symbolic-ref", "HEAD", "refs/heads/\(branch)"])
    }

    public func setReference(_ name: String, to commit: String) throws {
        try run(["update-ref", name, commit])
    }

    public func references(withPrefix prefix: String) -> [String] {
        ((try? run(["for-each-ref", "--format=%(refname)", prefix])) ?? "").split(separator: "\n").map(String.init)
    }

    public func deleteReference(_ name: String) {
        _ = try? run(["update-ref", "-d", name])
    }

    public func mergeBase(_ a: String, _ b: String) -> String? {
        let id = (try? run(["merge-base", a, b]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    public func isShallow() -> Bool {
        (try? run(["rev-parse", "--is-shallow-repository"]))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func deepen(by commits: Int?) throws {
        try run(["fetch", "--quiet", commits.map { "--deepen=\($0)" } ?? "--unshallow", "origin"], timeout: 120)
    }

    /// git keeps its note of a shallow clone's end itself.
    public func markMissingHistory() throws -> Int { 0 }

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
    public func run(_ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        String(decoding: try runData(arguments, timeout: timeout), as: UTF8.self)
    }

    func runData(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 30,
                 allowingStatus allowed: ClosedRange<Int32> = 0...0) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.quotePath=false"] + arguments
        process.currentDirectoryURL = root
        process.environment = Self.environment
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

extension Git {
    /// The repository the graph sits in, synced through the `git` command
    /// line, or nil when it sits in none.
    public static func open(_ root: URL) -> Git? {
        CommandLineGit.open(root).map(Git.init(backend:))
    }

    convenience init(root: URL) { self.init(backend: CommandLineGit(root: root)) }
}

extension Graph {
    /// The graph at a folder, synced through the `git` command line when the
    /// folder is in a repository.
    public convenience init(root: URL) {
        self.init(root: root, git: Git.open(root))
    }
}
#endif
