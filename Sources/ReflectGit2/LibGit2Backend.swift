import Foundation
import ReflectCore
import libgit2

/// The sync's steps done by libgit2, for where there is no `git` to run —
/// the phone. Each does what `CommandLineGit`'s does, so the sync's rules,
/// which are `Git`'s, come out the same: the sync tests run on both.
///
/// Not safe to use from two threads at once; the sync calls it on its own
/// serial queue.
public final class LibGit2Backend: GitBackend, @unchecked Sendable {
    /// A user name and password — for GitHub, `x-access-token` and a token.
    public struct Credentials: Sendable {
        public var username: String
        public var password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }
    }

    public let root: URL
    private let repository: OpaquePointer
    /// The working tree's top, with a trailing slash.
    private let workdir: String
    /// Where the root is within the working tree: "" or "some/folder/".
    private let prefix: String
    private let auth: Auth

    /// Asked for credentials when the remote wants them. Nil for none.
    public var credentials: (@Sendable () -> Credentials?)? {
        get { auth.provide }
        set { auth.provide = newValue }
    }
    /// Who commits are by, when the repository's configuration does not say.
    public var identity: (name: String, email: String) = ("Reflect", "reflect@localhost")

    private static let initialized: Void = { _ = git_libgit2_init() }()

    /// The repository the folder is in, or nil when it is in none.
    public init?(root: URL) {
        _ = Self.initialized
        var repository: OpaquePointer?
        guard git_repository_open_ext(&repository, root.path, 0, nil) == 0, let repository,
              let top = git_repository_workdir(repository).map({ String(cString: $0) }) else { return nil }
        self.repository = repository
        self.root = root
        workdir = top.hasSuffix("/") ? top : top + "/"
        let resolved = root.resolvingSymlinksInPath().path + "/"
        let resolvedTop = URL(fileURLWithPath: workdir).resolvingSymlinksInPath().path + "/"
        prefix = resolved.hasPrefix(resolvedTop) ? String(resolved.dropFirst(resolvedTop.count)) : ""
        auth = Auth()
    }

    deinit { git_repository_free(repository) }

    /// Clones a remote into a new folder — only its latest commit, when
    /// `depth` is 1 — and opens it.
    public static func clone(_ url: String, to directory: URL, depth: Int32 = 0,
                             credentials: (@Sendable () -> Credentials?)? = nil) throws -> LibGit2Backend {
        _ = initialized
        let auth = Auth()
        auth.provide = credentials
        var options = git_clone_options()
        git_clone_options_init(&options, UInt32(GIT_CLONE_OPTIONS_VERSION))
        options.fetch_opts.depth = depth
        auth.install(&options.fetch_opts.callbacks)
        var cloned: OpaquePointer?
        let code = withExtendedLifetime(auth) { git_clone(&cloned, url, directory.path, &options) }
        guard code == 0 else { throw GitError(message: "Cloning failed: \(lastError())") }
        git_repository_free(cloned)
        guard let backend = LibGit2Backend(root: directory) else {
            throw GitError(message: "The clone at \(directory.path) could not be opened.")
        }
        backend.credentials = credentials
        return backend
    }

    // MARK: Where things stand

    public func topLevel() throws -> URL { URL(fileURLWithPath: workdir, isDirectory: true) }

    public func operationInProgress() throws -> String? {
        switch git_repository_state_t(UInt32(git_repository_state(repository))) {
        case GIT_REPOSITORY_STATE_NONE: nil
        case GIT_REPOSITORY_STATE_MERGE: "a merge"
        case GIT_REPOSITORY_STATE_REVERT, GIT_REPOSITORY_STATE_REVERT_SEQUENCE: "a revert"
        case GIT_REPOSITORY_STATE_CHERRYPICK, GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE: "a cherry-pick"
        case GIT_REPOSITORY_STATE_BISECT: "a bisect"
        default: "a rebase"
        }
    }

    public func currentBranch() throws -> String? {
        var head: OpaquePointer?
        guard git_reference_lookup(&head, repository, "HEAD") == 0 else { return nil }
        defer { git_reference_free(head) }
        guard git_reference_type(head) == GIT_REFERENCE_SYMBOLIC,
              let target = git_reference_symbolic_target(head).map({ String(cString: $0) }),
              target.hasPrefix("refs/heads/") else { return nil }
        return String(target.dropFirst("refs/heads/".count))
    }

    public func head() -> String? { id(of: "HEAD").map(Self.string) }

    public func resolves(_ reference: String) -> Bool {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repository, reference) == 0 else { return false }
        git_object_free(object)
        return true
    }

    public func hasRemote(_ name: String) -> Bool {
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repository, name) == 0 else { return false }
        git_remote_free(remote)
        return true
    }

    public func commitCount() -> Int {
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, repository) == 0 else { return 0 }
        defer { git_revwalk_free(walk) }
        guard git_revwalk_push_head(walk) == 0 else { return 0 }
        var id = git_oid()
        var count = 0
        while git_revwalk_next(&id, walk) == 0 { count += 1 }
        return count
    }

    public func divergence(_ reference: String) throws -> (behind: Int, ahead: Int) {
        guard var local = id(of: "HEAD") else { throw GitError(message: "HEAD names no commit yet") }
        var upstream = try resolved(reference)
        var ahead = 0, behind = 0
        try check(git_graph_ahead_behind(&ahead, &behind, repository, &local, &upstream), "Counting commits")
        return (behind, ahead)
    }

    // MARK: Putting things right

    public func gitDirectory() throws -> URL {
        URL(fileURLWithPath: String(cString: git_repository_path(repository)), isDirectory: true)
    }

    public func abandonOperation() throws {
        let state = git_repository_state_t(UInt32(git_repository_state(repository)))
        switch state {
        case GIT_REPOSITORY_STATE_NONE:
            return
        case GIT_REPOSITORY_STATE_REBASE, GIT_REPOSITORY_STATE_REBASE_MERGE, GIT_REPOSITORY_STATE_REBASE_INTERACTIVE,
             GIT_REPOSITORY_STATE_APPLY_MAILBOX, GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE:
            var rebase: OpaquePointer?
            if git_rebase_open(&rebase, repository, nil) == 0 {
                defer { git_rebase_free(rebase) }
                try check(git_rebase_abort(rebase), "Leaving the rebase")
            } else {
                git_repository_state_cleanup(repository)
            }
        default:
            // A merge, a cherry-pick, a revert: left as a merge is.
            abortMerge()
        }
    }

    public func branches() -> [String: String] {
        var found: [String: String] = [:]
        var iterator: OpaquePointer?
        guard git_branch_iterator_new(&iterator, repository, GIT_BRANCH_LOCAL) == 0 else { return [:] }
        defer { git_branch_iterator_free(iterator) }
        var reference: OpaquePointer?
        var type = GIT_BRANCH_LOCAL
        while git_branch_next(&reference, &type, iterator) == 0 {
            defer { git_reference_free(reference) }
            var name: UnsafePointer<CChar>?
            guard git_branch_name(&name, reference) == 0, let name, let target = git_reference_target(reference) else { continue }
            found[String(cString: name)] = Self.string(target)
        }
        return found
    }

    public func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
        guard var a = try? resolved(ancestor), var d = try? resolved(descendant) else { return false }
        if git_oid_equal(&a, &d) != 0 { return true }
        return git_graph_descendant_of(repository, &d, &a) == 1
    }

    public func attachHead(to branch: String, at commit: String) throws {
        try setReference("refs/heads/\(branch)", to: commit)
        try check(git_repository_set_head(repository, "refs/heads/\(branch)"), "Putting HEAD on \(branch)")
    }

    public func setReference(_ name: String, to commit: String) throws {
        var id = try resolved(commit)
        var made: OpaquePointer?
        try check(git_reference_create(&made, repository, name, &id, 1, "sync"), "Writing \(name)")
        git_reference_free(made)
    }

    public func references(withPrefix prefix: String) -> [String] {
        var iterator: UnsafeMutablePointer<git_reference_iterator>?
        guard git_reference_iterator_glob_new(&iterator, repository, prefix + "*") == 0 else { return [] }
        defer { git_reference_iterator_free(iterator) }
        var names: [String] = []
        var name: UnsafePointer<CChar>?
        while git_reference_next_name(&name, iterator) == 0, let name { names.append(String(cString: name)) }
        return names
    }

    public func deleteReference(_ name: String) {
        git_reference_remove(repository, name)
    }

    public func mergeBase(_ a: String, _ b: String) -> String? {
        guard var one = try? resolved(a), var two = try? resolved(b) else { return nil }
        var base = git_oid()
        guard git_merge_base(&base, repository, &one, &two) == 0 else { return nil }
        return Self.string(base)
    }

    public func isShallow() -> Bool { git_repository_is_shallow(repository) == 1 }

    public func markMissingHistory() throws -> Int {
        var odb: OpaquePointer?
        try check(git_repository_odb(&odb, repository), "Opening the objects")
        defer { git_odb_free(odb) }
        // Every commit reachable from the branches and the remote's, each
        // looked at once: those with a parent not here are where it stops.
        var queue: [git_oid] = []
        for name in references(withPrefix: "refs/heads/") + references(withPrefix: "refs/remotes/") {
            if let id = id(of: name) { queue.append(id) }
        }
        var seen = Set<String>(), ends = Set<String>()
        while var id = queue.popLast() {
            guard seen.insert(Self.string(id)).inserted else { continue }
            var commit: OpaquePointer?
            guard git_commit_lookup(&commit, repository, &id) == 0 else { continue }
            defer { git_commit_free(commit) }
            for n in 0..<git_commit_parentcount(commit) {
                guard let parent = git_commit_parent_id(commit, n) else { continue }
                if git_odb_exists(odb, parent) == 1 { queue.append(parent.pointee) } else { ends.insert(Self.string(id)) }
            }
        }
        guard !ends.isEmpty else { return 0 }
        let note = URL(fileURLWithPath: String(cString: git_repository_path(repository))).appendingPathComponent("shallow")
        let noted = Set(((try? String(contentsOf: note, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        let missing = ends.subtracting(noted)
        guard !missing.isEmpty else { return 0 }
        try (noted.union(ends).sorted().joined(separator: "\n") + "\n").write(to: note, atomically: true, encoding: .utf8)
        Log.shared.info("git", "Noted \(missing.count) commits whose history is not here")
        return missing.count
    }

    public func deepen(by commits: Int?) throws {
        let remote = try origin()
        defer { git_remote_free(remote) }
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        // A depth counts from the tips: the history now, and so many more.
        options.depth = commits.map { Int32(clamping: commitCount() + $0) } ?? Int32(GIT_FETCH_DEPTH_UNSHALLOW.rawValue)
        auth.install(&options.callbacks)
        let code = withExtendedLifetime(auth) { git_remote_fetch(remote, nil, &options, nil) }
        Log.shared.info("git", "libgit2 deepen origin by \(commits.map(String.init) ?? "all") — \(code == 0 ? "done" : Self.lastError())")
        try check(code, "Fetching more history")
    }

    // MARK: The index

    public func stageAll() throws {
        let index = try openIndex()
        defer { git_index_free(index) }
        // `.reflect/`, the index each device rebuilds, is never committed.
        let skip = Skip(prefix + ".reflect")
        let matched: git_index_matched_path_cb = { path, _, payload in
            guard let path, let payload else { return 0 }
            let skip = Unmanaged<Skip>.fromOpaque(payload).takeUnretainedValue()
            let name = String(cString: path)
            return name == skip.path || name.hasPrefix(skip.path + "/") ? 1 : 0
        }
        let payload = Unmanaged.passUnretained(skip).toOpaque()
        try withPathspec { spec in
            try check(git_index_add_all(index, spec, GIT_INDEX_ADD_DEFAULT.rawValue, matched, payload), "Staging")
            try check(git_index_update_all(index, spec, matched, payload), "Staging")
        }
        try check(git_index_write(index), "Writing the index")
    }

    public func stagedWrittenPaths() throws -> [String] {
        try stagedDeltas(renames: false).compactMap { delta in
            [GIT_DELTA_ADDED, GIT_DELTA_MODIFIED, GIT_DELTA_TYPECHANGE].contains(delta.status) ? relative(delta.new) : nil
        }
    }

    public func unstage(_ path: String) throws {
        let full = prefix + path
        if let head = headCommit() {
            defer { git_commit_free(head) }
            try withStrings([full]) { spec in
                try check(git_reset_default(repository, head, spec), "Unstaging \(path)")
            }
        } else {
            let index = try openIndex()
            defer { git_index_free(index) }
            try check(git_index_remove_bypath(index, full), "Unstaging \(path)")
            try check(git_index_write(index), "Writing the index")
        }
    }

    public func stagedChanges() throws -> [CommitMessage.Change] {
        try stagedDeltas(renames: true).compactMap { delta -> CommitMessage.Change? in
            switch delta.status {
            case GIT_DELTA_ADDED, GIT_DELTA_COPIED:
                return relative(delta.new).map { .init(action: .add, path: $0) }
            case GIT_DELTA_DELETED:
                return relative(delta.old).map { .init(action: .delete, path: $0) }
            case GIT_DELTA_RENAMED:
                guard let new = relative(delta.new) else { return nil }
                guard let old = relative(delta.old) else { return .init(action: .add, path: new) }
                return .init(action: .rename, path: new, oldPath: old)
            default:
                return relative(delta.new).map { .init(action: .update, path: $0) }
            }
        }
    }

    public func contents(_ requests: [(revision: String, path: String)]) -> [String?] {
        let index = try? openIndex()
        defer { if let index { git_index_free(index) } }
        return requests.map { request in
            let full = prefix + request.path
            var blob: OpaquePointer?
            if request.revision.isEmpty {
                guard let index, let entry = git_index_get_bypath(index, full, 0) else { return nil }
                var id = entry.pointee.id
                guard git_blob_lookup(&blob, repository, &id) == 0 else { return nil }
            } else {
                guard git_revparse_single(&blob, repository, "\(request.revision):\(full)") == 0 else { return nil }
                guard git_object_type(blob) == GIT_OBJECT_BLOB else {
                    git_object_free(blob)
                    return nil
                }
            }
            defer { git_blob_free(blob) }
            return String(decoding: Self.data(of: blob), as: UTF8.self)
        }
    }

    public func commit(message: String) throws {
        try commitIndex(message: message, parents: headCommit().map { [$0] } ?? [])
    }

    // MARK: The remote

    public func fetch() throws {
        // libgit2 rewrites a shallow clone's note of where its history stops
        // when a fetch brings commits in — as empty — and the repository
        // then claims history it lacks. Kept, and put back.
        let note = URL(fileURLWithPath: String(cString: git_repository_path(repository))).appendingPathComponent("shallow")
        let kept = try? Data(contentsOf: note)
        defer {
            if let kept, !kept.isEmpty, (try? Data(contentsOf: note)) != kept { try? kept.write(to: note, options: .atomic) }
        }
        let remote = try origin()
        defer { git_remote_free(remote) }
        var options = git_fetch_options()
        git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION))
        auth.install(&options.callbacks)
        let code = withExtendedLifetime(auth) { git_remote_fetch(remote, nil, &options, nil) }
        Log.shared.info("git", "libgit2 fetch origin — \(code == 0 ? "done" : Self.lastError())")
        try check(code, "Fetching")
    }

    public func push(branch: String) throws -> GitPushOutcome {
        let remote = try origin()
        defer { git_remote_free(remote) }
        var options = git_push_options()
        git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION))
        auth.install(&options.callbacks)
        auth.refusal = nil
        options.callbacks.push_update_reference = { _, status, payload in
            if let status, let payload {
                Unmanaged<Auth>.fromOpaque(payload).takeUnretainedValue().refusal = String(cString: status)
            }
            return 0
        }
        let code = try withStrings(["refs/heads/\(branch):refs/heads/\(branch)"]) { refspecs in
            withExtendedLifetime(auth) { git_remote_push(remote, refspecs, &options) }
        }
        let said = code < 0 ? Self.lastError() : auth.refusal
        Log.shared.info("git", "libgit2 push origin \(branch) — \(said ?? "done")")
        guard let said else { return .pushed }
        let lowered = said.lowercased()
        let behind = code == GIT_ENONFASTFORWARD.rawValue || code == GIT_EMODIFIED.rawValue
            || ["non-fast-forward", "non-fastforward", "fetch first", "cannot lock", "not present locally", "does not match"]
                .contains { lowered.contains($0) }
        return behind ? .behind : .rejected(said)
    }

    // MARK: Merging

    public func fastForward(to reference: String) throws {
        var target = try resolved(reference)
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repository, &target), "Reading \(reference)")
        defer { git_commit_free(commit) }
        var checkout = git_checkout_options()
        git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_checkout_tree(repository, commit, &checkout), "Fast-forwarding")
        guard let branch = try currentBranch() else { throw GitError(message: "HEAD is not on a branch") }
        var moved: OpaquePointer?
        try check(git_reference_create(&moved, repository, "refs/heads/\(branch)", &target, 1, "merge \(reference): Fast-forward"),
                  "Fast-forwarding")
        git_reference_free(moved)
    }

    public func merge(_ reference: String, message: String) throws -> GitMergeOutcome {
        var theirs: OpaquePointer?
        try check(git_annotated_commit_from_revspec(&theirs, repository, reference), "Reading \(reference)")
        defer { git_annotated_commit_free(theirs) }
        var options = git_merge_options()
        git_merge_options_init(&options, UInt32(GIT_MERGE_OPTIONS_VERSION))
        var checkout = git_checkout_options()
        git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkout.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue | GIT_CHECKOUT_ALLOW_CONFLICTS.rawValue
        var heads: [OpaquePointer?] = [theirs]
        guard git_merge(repository, &heads, 1, &options, &checkout) == 0 else {
            let said = Self.lastError()
            abortMerge()
            throw GitError(message: "Merging failed: \(said)")
        }
        let index = try openIndex()
        defer { git_index_free(index) }
        guard git_index_has_conflicts(index) != 0 else {
            try commitMerge(message: message)
            return .merged
        }
        var conflicts: [String: [Int: String]] = [:]
        var iterator: OpaquePointer?
        try check(git_index_conflict_iterator_new(&iterator, index), "Reading conflicts")
        defer { git_index_conflict_iterator_free(iterator) }
        var ancestor: UnsafePointer<git_index_entry>?, ours: UnsafePointer<git_index_entry>?, theirsEntry: UnsafePointer<git_index_entry>?
        while git_index_conflict_next(&ancestor, &ours, &theirsEntry, iterator) == 0 {
            guard let any = ours ?? theirsEntry ?? ancestor else { continue }
            let path = String(cString: any.pointee.path)
            for (stage, entry) in [(1, ancestor), (2, ours), (3, theirsEntry)] {
                guard var id = entry?.pointee.id else { continue }
                conflicts[path, default: [:]][stage] = Self.string(&id)
            }
        }
        return .conflicted(conflicts)
    }

    /// Leaves a merge as `git merge --abort` does: the index back to HEAD,
    /// the files the merge left conflicted back as HEAD has them — and every
    /// other file as it is, so nothing written since the cycle's commit is
    /// lost. (A hard reset, which this was, threw such writing away.)
    public func abortMerge() {
        var conflicted: [String] = []
        if let index = try? openIndex() {
            var iterator: OpaquePointer?
            if git_index_conflict_iterator_new(&iterator, index) == 0 {
                var ancestor: UnsafePointer<git_index_entry>?, ours: UnsafePointer<git_index_entry>?, theirs: UnsafePointer<git_index_entry>?
                while git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0 {
                    if let any = ours ?? theirs ?? ancestor { conflicted.append(String(cString: any.pointee.path)) }
                }
                git_index_conflict_iterator_free(iterator)
            }
            git_index_free(index)
        }
        if let head = headCommit() {
            git_reset(repository, head, GIT_RESET_MIXED, nil)
            git_commit_free(head)
        }
        if !conflicted.isEmpty {
            var checkout = git_checkout_options()
            git_checkout_options_init(&checkout, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            checkout.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue | GIT_CHECKOUT_DISABLE_PATHSPEC_MATCH.rawValue
            _ = try? withStrings(conflicted) { paths in
                checkout.paths = paths.pointee
                return git_checkout_head(repository, &checkout)
            }
            // A file the merge brought in that HEAD lacks: taken out again.
            for path in conflicted where !resolves("HEAD:\(path)") {
                try? FileManager.default.removeItem(atPath: workdir + path)
            }
        }
        git_repository_state_cleanup(repository)
    }

    public func commitMerge(message: String) throws {
        var parents: [OpaquePointer] = headCommit().map { [$0] } ?? []
        var mergeHeads: [git_oid] = []
        let collect: git_repository_mergehead_foreach_cb = { id, payload in
            guard let id, let payload else { return 0 }
            payload.assumingMemoryBound(to: [git_oid].self).pointee.append(id.pointee)
            return 0
        }
        _ = withUnsafeMutablePointer(to: &mergeHeads) { git_repository_mergehead_foreach(repository, collect, $0) }
        for var id in mergeHeads {
            var commit: OpaquePointer?
            if git_commit_lookup(&commit, repository, &id) == 0, let commit { parents.append(commit) }
        }
        try commitIndex(message: message, parents: parents)
        git_repository_state_cleanup(repository)
    }

    public func blob(_ id: String) throws -> Data {
        var oid = git_oid()
        try check(git_oid_fromstr(&oid, id), "Reading \(id)")
        var blob: OpaquePointer?
        try check(git_blob_lookup(&blob, repository, &oid), "Reading \(id)")
        defer { git_blob_free(blob) }
        return Self.data(of: blob)
    }

    public func add(topLevelPaths paths: [String]) throws {
        let index = try openIndex()
        defer { git_index_free(index) }
        for path in paths { try check(git_index_add_bypath(index, path), "Staging \(path)") }
        try check(git_index_write(index), "Writing the index")
    }

    public func remove(topLevelPath path: String) throws {
        let index = try openIndex()
        defer { git_index_free(index) }
        _ = git_index_remove_bypath(index, path)
        try check(git_index_write(index), "Writing the index")
    }

    public func mergeText(ours: Data, base: Data, theirs: Data, labels: (ours: String, base: String, theirs: String)) throws -> Data {
        var options = git_merge_file_options()
        git_merge_file_options_init(&options, UInt32(GIT_MERGE_FILE_OPTIONS_VERSION))
        var result = git_merge_file_result()
        let code: Int32 = base.withUnsafeBytes { baseBytes in
            ours.withUnsafeBytes { ourBytes in
                theirs.withUnsafeBytes { theirBytes in
                    labels.base.withCString { baseLabel in
                        labels.ours.withCString { ourLabel in
                            labels.theirs.withCString { theirLabel in
                                var ancestor = Self.input(baseBytes), mine = Self.input(ourBytes), other = Self.input(theirBytes)
                                options.ancestor_label = baseLabel
                                options.our_label = ourLabel
                                options.their_label = theirLabel
                                return git_merge_file(&result, &ancestor, &mine, &other, &options)
                            }
                        }
                    }
                }
            }
        }
        try check(code, "Merging text")
        defer { git_merge_file_result_free(&result) }
        guard let pointer = result.ptr else { return Data() }
        return Data(bytes: pointer, count: result.len)
    }

    public func changedPaths(from: String, to: String) -> [String] {
        guard let old = tree(of: from), let new = tree(of: to) else { return [] }
        defer {
            git_tree_free(old)
            git_tree_free(new)
        }
        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repository, old, new, nil) == 0 else { return [] }
        defer { git_diff_free(diff) }
        var paths: [String] = []
        for delta in Self.deltas(diff) {
            for path in [delta.old, delta.new].compactMap({ $0 }) {
                if let path = relative(path), !paths.contains(path) { paths.append(path) }
            }
        }
        return paths
    }

    // MARK: Helpers

    private struct Delta {
        var status: git_delta_t
        var old: String?
        var new: String?
    }

    /// What the index holds that HEAD does not, under the root.
    private func stagedDeltas(renames: Bool) throws -> [Delta] {
        let index = try openIndex()
        defer { git_index_free(index) }
        let head = headCommit()
        defer { if let head { git_commit_free(head) } }
        var tree: OpaquePointer?
        if let head { try check(git_commit_tree(&tree, head), "Reading HEAD") }
        defer { if let tree { git_tree_free(tree) } }
        var diff: OpaquePointer?
        try check(git_diff_tree_to_index(&diff, repository, tree, index, nil), "Comparing the index")
        defer { git_diff_free(diff) }
        if renames {
            var find = git_diff_find_options()
            git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
            find.flags = GIT_DIFF_FIND_RENAMES.rawValue
            try check(git_diff_find_similar(diff, &find), "Finding renames")
        }
        return Self.deltas(diff)
    }

    private static func deltas(_ diff: OpaquePointer?) -> [Delta] {
        (0..<git_diff_num_deltas(diff)).compactMap { index in
            guard let delta = git_diff_get_delta(diff, index) else { return nil }
            return Delta(status: delta.pointee.status,
                         old: delta.pointee.old_file.path.map { String(cString: $0) },
                         new: delta.pointee.new_file.path.map { String(cString: $0) })
        }
    }

    /// A path from the top, as a path from the root; nil when outside it.
    private func relative(_ path: String?) -> String? {
        guard let path, path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// The index as it is on disk now: another tool may have changed it.
    private func openIndex() throws -> OpaquePointer {
        var index: OpaquePointer?
        try check(git_repository_index(&index, repository), "Opening the index")
        guard let index else { throw GitError(message: "No index") }
        try check(git_index_read(index, 1), "Reading the index")
        return index
    }

    private func commitIndex(message: String, parents: [OpaquePointer]) throws {
        defer { parents.forEach { git_commit_free($0) } }
        let index = try openIndex()
        defer { git_index_free(index) }
        var treeID = git_oid()
        try check(git_index_write_tree(&treeID, index), "Writing the tree")
        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repository, &treeID), "Reading the tree")
        defer { git_tree_free(tree) }
        var signature: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&signature, repository) != 0 {
            try check(git_signature_now(&signature, identity.name, identity.email), "Signing")
        }
        defer { git_signature_free(signature) }
        // As `git commit` leaves a message: ending in a newline.
        let text = message.hasSuffix("\n") ? message : message + "\n"
        var id = git_oid()
        var pointers: [OpaquePointer?] = parents
        try check(git_commit_create(&id, repository, "HEAD", signature, signature, nil, text, tree, parents.count, &pointers),
                  "Committing")
    }

    private func headCommit() -> OpaquePointer? {
        guard var id = id(of: "HEAD") else { return nil }
        var commit: OpaquePointer?
        return git_commit_lookup(&commit, repository, &id) == 0 ? commit : nil
    }

    private func tree(of revision: String) -> OpaquePointer? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repository, revision + "^{tree}") == 0 else { return nil }
        return object
    }

    private func id(of reference: String) -> git_oid? {
        var id = git_oid()
        return git_reference_name_to_id(&id, repository, reference) == 0 ? id : nil
    }

    private func resolved(_ revision: String) throws -> git_oid {
        var object: OpaquePointer?
        try check(git_revparse_single(&object, repository, revision), "Reading \(revision)")
        defer { git_object_free(object) }
        return git_object_id(object).pointee
    }

    private func origin() throws -> OpaquePointer {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repository, "origin"), "Finding origin")
        return remote!
    }

    /// Everything under the root: no pathspec when the root is the top.
    private func withPathspec<T>(_ body: (UnsafeMutablePointer<git_strarray>) throws -> T) throws -> T {
        try withStrings(prefix.isEmpty ? [] : [String(prefix.dropLast())], body)
    }

    private func withStrings<T>(_ strings: [String], _ body: (UnsafeMutablePointer<git_strarray>) throws -> T) throws -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            var array = git_strarray(strings: buffer.baseAddress, count: buffer.count)
            return try body(&array)
        }
    }

    private static func input(_ bytes: UnsafeRawBufferPointer) -> git_merge_file_input {
        var input = git_merge_file_input()
        git_merge_file_input_init(&input, UInt32(GIT_MERGE_FILE_INPUT_VERSION))
        input.ptr = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
        input.size = bytes.count
        return input
    }

    private static func data(of blob: OpaquePointer?) -> Data {
        guard let content = git_blob_rawcontent(blob) else { return Data() }
        return Data(bytes: content, count: Int(git_blob_rawsize(blob)))
    }

    private static func string(_ id: UnsafePointer<git_oid>) -> String {
        String(cString: git_oid_tostr_s(id))
    }

    private static func string(_ id: git_oid) -> String {
        var id = id
        return string(&id)
    }

    static func lastError() -> String {
        git_error_last().flatMap { $0.pointee.message.map { String(cString: $0) } } ?? "unknown error"
    }

    @discardableResult
    private func check(_ code: Int32, _ what: String) throws -> Int32 {
        guard code < 0 else { return code }
        throw GitError(message: "\(what): \(Self.lastError())")
    }
}

/// What a callback needs: the credentials, and whether they were tried.
private final class Auth: @unchecked Sendable {
    var provide: (@Sendable () -> LibGit2Backend.Credentials?)?
    var tried = false
    /// What the remote said, turning a push away.
    var refusal: String?

    func install(_ callbacks: inout git_remote_callbacks) {
        tried = false
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        callbacks.credentials = { out, _, _, allowed, payload in
            guard let out, let payload else { return GIT_PASSTHROUGH.rawValue }
            let auth = Unmanaged<Auth>.fromOpaque(payload).takeUnretainedValue()
            // Asked again means turned away: say so rather than ask forever.
            guard !auth.tried, allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0,
                  let credentials = auth.provide?() else {
                return auth.tried ? GIT_EAUTH.rawValue : GIT_PASSTHROUGH.rawValue
            }
            auth.tried = true
            return git_credential_userpass_plaintext_new(out, credentials.username, credentials.password)
        }
    }
}

private final class Skip {
    let path: String
    init(_ path: String) { self.path = path }
}
