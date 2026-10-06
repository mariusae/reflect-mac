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
}
