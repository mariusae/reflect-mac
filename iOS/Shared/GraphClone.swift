import Foundation
import ReflectCore
import ReflectGit2

/// Brings a graph down from GitHub, for the apps that show one.
enum GraphClone {
    /// Clones a repository into a graph's place — only its latest commit.
    /// Nothing is left behind when it fails.
    @MainActor
    static func clone(_ repository: GitHubRepository, account: GitHubAccount, into root: URL) async throws {
        _ = try await account.validAccessToken()
        let token = account.currentToken
        let partial = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + ".partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try LibGit2Backend.clone(repository.cloneURL, to: partial, depth: 1, credentials: { token.credentials })
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
