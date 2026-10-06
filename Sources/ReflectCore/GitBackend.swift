import Foundation

/// What the sync asks of a repository, one plain operation at a time: the
/// sync's rules — what is committed, how a merge is settled, when a push is
/// tried again — are `Git`'s, and the same on every device; how each step
/// is done is the backend's. On the Mac, the `git` command line; where
/// there is none, a library.
///
/// Every call is made on the sync's own serial queue, never on the main
/// thread. Paths are relative to the graph's root unless said otherwise.
public protocol GitBackend: AnyObject, Sendable {
    /// Where the graph is: the working tree, or a directory within it.
    var root: URL { get }
    /// The top of the repository's working tree.
    func topLevel() throws -> URL

    /// What another tool left the repository in the middle of — "a merge",
    /// "a rebase" — or nil when it is in the middle of nothing.
    func operationInProgress() throws -> String?
    /// The branch checked out, or nil on a detached HEAD.
    func currentBranch() throws -> String?
    /// The commit HEAD is at, or nil before the first.
    func head() -> String?
    /// Whether a reference — `refs/remotes/origin/main` — names a commit.
    func resolves(_ reference: String) -> Bool
    func hasRemote(_ name: String) -> Bool
    /// How many commits HEAD has.
    func commitCount() -> Int
    /// How many commits each side has that the other lacks.
    func divergence(_ reference: String) throws -> (behind: Int, ahead: Int)

    // MARK: The index

    /// Stages every change under the root — `.reflect/`, the index each
    /// device rebuilds, left out.
    func stageAll() throws
    /// The paths staged as added or changed.
    func stagedWrittenPaths() throws -> [String]
    func unstage(_ path: String) throws
    /// What the index would commit, renames found.
    func stagedChanges() throws -> [CommitMessage.Change]
    /// Files as they stand at revisions — an empty revision is the index —
    /// nil for one that cannot be read.
    func contents(_ requests: [(revision: String, path: String)]) -> [String?]
    func commit(message: String) throws

    // MARK: The remote

    func fetch() throws
    func push(branch: String) throws -> GitPushOutcome

    // MARK: Merging

    func fastForward(to reference: String) throws
    /// Merges a reference into HEAD. A clean merge is committed with the
    /// message. A conflicted one is left in progress, its conflicts
    /// returned — for each path from the top, the blob at each stage: 1 the
    /// common ancestor, 2 ours, 3 theirs. Any other failure leaves nothing
    /// in progress, and throws.
    func merge(_ reference: String, message: String) throws -> GitMergeOutcome
    func abortMerge()
    /// Commits a merge whose conflicts were settled.
    func commitMerge(message: String) throws
    func blob(_ id: String) throws -> Data
    /// Stages files as they are in the working tree; paths from the top.
    func add(topLevelPaths paths: [String]) throws
    /// Takes a file out of the index; its path from the top.
    func remove(topLevelPath path: String) throws
    /// Both sides in one text, differing lines between labelled markers.
    func mergeText(ours: Data, base: Data, theirs: Data, labels: (ours: String, base: String, theirs: String)) throws -> Data
    /// The paths that differ between two commits.
    func changedPaths(from: String, to: String) -> [String]

    // MARK: Putting things right

    /// The repository's own folder, where its locks are: `.git`.
    func gitDirectory() throws -> URL
    /// Leaves whatever operation is in progress — a merge, a rebase — as
    /// git's own `--abort` does, the working tree's other changes kept.
    func abandonOperation() throws
    /// The local branches, each with the commit it is at.
    func branches() -> [String: String]
    /// Whether a commit is the other, or one of its ancestors.
    func isAncestor(_ ancestor: String, of descendant: String) -> Bool
    /// Puts a branch at a commit and HEAD on the branch, leaving the index
    /// and the working tree as they are.
    func attachHead(to branch: String, at commit: String) throws
    /// Points a reference at a commit, making it if need be.
    func setReference(_ name: String, to commit: String) throws
    /// The references whose names start so.
    func references(withPrefix prefix: String) -> [String]
    func deleteReference(_ name: String)
    /// The commit two have most recently in common, or nil when, as far as
    /// this repository can see, none.
    func mergeBase(_ a: String, _ b: String) -> String?
    /// Whether the repository has only the latest part of its history.
    func isShallow() -> Bool
    /// Fetches more of the history: so many commits more, or nil for all.
    func deepen(by commits: Int?) throws
    /// Finds commits whose parents are missing and notes them as where the
    /// history stops — as a shallow clone notes it — when the note was lost.
    /// Says how many it noted.
    func markMissingHistory() throws -> Int
}

public enum GitPushOutcome: Sendable, Equatable { case pushed, behind, rejected(String) }

public enum GitMergeOutcome: Sendable, Equatable { case merged, conflicted([String: [Int: String]]) }
