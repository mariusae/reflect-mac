import Foundation
import Testing
@testable import ReflectCore
import ReflectGit2

/// How long the phone's sync takes on a real graph: `SYNC_TIMING_REPO`
/// names a folder with `phone`, `other` (clones) and `remote.git`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SYNC_TIMING_REPO"] != nil))
struct SyncTimingTests {
    private func time<T>(_ name: String, _ work: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try work()
        print(String(format: "TIMING %-34@ %8.0f ms", name as NSString, Date().timeIntervalSince(start) * 1000))
        return result
    }

    @Test func phoneCycles() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SYNC_TIMING_REPO"]!)
        let phone = base.appendingPathComponent("phone"), other = base.appendingPathComponent("other")
        let backend = try time("open") { LibGit2Backend(root: phone)! }
        _ = try time("markMissingHistory") { try backend.markMissingHistory() }
        try time("stageAll") { try backend.stageAll() }
        _ = try time("stagedChanges") { try backend.stagedChanges() }
        _ = try time("divergence") { try backend.divergence("refs/remotes/origin/main") }
        let git = Git(backend: LibGit2Backend(root: phone)!)
        _ = try time("cycle push, nothing written") { try git.cycle(.push) }
        _ = try time("cycle full, nothing new") { try git.cycle(.full) }
        // Another device writes; the phone takes it in.
        try "- from the other device \(Date())\n".write(to: other.appendingPathComponent("daily/2099-01-01.md"), atomically: true, encoding: .utf8)
        _ = try Git(root: other).cycle(.push)
        _ = try time("cycle full, one commit to pull") { try git.cycle(.full) }
        // The phone writes.
        try "- from the phone \(Date())\n".write(to: phone.appendingPathComponent("daily/2099-01-02.md"), atomically: true, encoding: .utf8)
        _ = try time("cycle push, one note written") { try git.cycle(.push) }
        let fresh = Git(backend: LibGit2Backend(root: phone)!)
        _ = try time("cycle full, fresh launch") { try fresh.cycle(.full) }
    }

    /// A clone libgit2 made — as the phone's is, moved into place — staged
    /// again and again with nothing changed.
    @Test func libgit2CloneStaging() throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SYNC_TIMING_REPO"]!)
        let partial = base.appendingPathComponent("lg.partial"), root = base.appendingPathComponent("lg")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: root)
        _ = try time("libgit2 clone") { try LibGit2Backend.clone(base.appendingPathComponent("remote.git").path, to: partial) }
        try FileManager.default.moveItem(at: partial, to: root)
        for n in 1...3 {
            let backend = LibGit2Backend(root: root)!
            try time("stageAll #\(n)") { try backend.stageAll() }
        }
        // Every file's attributes touched — as iOS does to a file read —
        // which moves its ctime, not its contents.
        func touchAttributes() {
            let walker = FileManager.default.enumerator(atPath: root.path)!
            for case let path as String in walker where !path.hasPrefix(".git") {
                setxattr(root.appendingPathComponent(path).path, "com.example.read", "1", 1, 0, 0)
            }
        }
        touchAttributes()
        try time("stageAll, attributes touched") { try LibGit2Backend(root: root)!.stageAll() }
        // Times moved without the contents changing: hashed once, then not.
        let now = Date()
        for case let path as String in FileManager.default.enumerator(atPath: root.path)! where !path.hasPrefix(".git") {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: root.appendingPathComponent(path).path)
        }
        try time("stageAll, times moved") { try LibGit2Backend(root: root)!.stageAll() }
        try time("stageAll, again") { try LibGit2Backend(root: root)!.stageAll() }
    }
}
