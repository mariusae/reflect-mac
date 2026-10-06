import Foundation
import ReflectCore

/// Brings a graph down from GitHub, for the apps that show one.
public enum GraphClone {
    /// Clones a repository into a graph's place, all of its history: a
    /// graph is mostly its pictures, which a shallow clone has all the same,
    /// and libgit2 cannot merge or push in one. Nothing is left behind when
    /// it fails.
    @MainActor
    public static func clone(_ repository: GitHubRepository, account: GitHubAccount, into root: URL, depth: Int32 = 0) async throws {
        _ = try await account.validAccessToken()
        let token = account.currentToken
        let partial = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try LibGit2Backend.clone(repository.cloneURL, to: partial, depth: depth, credentials: { token.credentials })
                // An empty folder in the graph's place gives way; one with
                // something in it is not the app's to remove.
                if let left = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
                    guard left.filter({ $0 != ".DS_Store" }).isEmpty else {
                        throw GitHubError("There is already a folder named Graph, with files in it.")
                    }
                    try FileManager.default.removeItem(at: root)
                }
                try FileManager.default.moveItem(at: partial, to: root)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }
}
