import AppKit
import ReflectCore
import ReflectUI

/// Keeps the graph's repository in step, on Reflect's schedule.
///
/// Writing is committed and pushed thirty seconds after it stops, and never
/// more than five minutes after it starts. A full sync — commit, fetch,
/// merge, push — runs at launch, when the app comes to the front, and when
/// asked; there is no timer beyond that. One cycle runs at a time; asking
/// during one queues one more after it, and a full sync asked for then is
/// not made a lesser one.
@MainActor
final class SyncController {
    enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
        case unavailable
    }

    let git: Git?
    private(set) var status: Status {
        didSet { onStatus?(status) }
    }
    var onStatus: ((Status) -> Void)?
    /// Told of the files a merge wrote.
    var onPulled: (([String]) -> Void)?
    /// Asked to write what is unsaved, before a commit.
    var flush: (() -> Void)?
    /// Told when a merge left notes needing review.
    var onConflicts: (([String]) -> Void)?
    /// Told of files too large to commit.
    var onLargeFiles: (([(path: String, size: Int)]) -> Void)?

    private var idleTimer: Timer?
    private var firstUnsaved: Date?
    private var running = false
    private var pending: Git.Mode?
    private var lastFullSync = Date.distantPast

    private static let idle: TimeInterval = 30
    private static let longest: TimeInterval = 300
    /// Coming to the front twice in a moment is one sync.
    private static let activationDedupe: TimeInterval = 1.5

    init(git: Git?) {
        self.git = git
        status = git == nil ? .unavailable : .idle
    }

    /// Something was written; commit it once writing pauses.
    func noteChanged() {
        guard git != nil else { return }
        let now = Date()
        let first = firstUnsaved ?? now
        firstUnsaved = first
        let wait = min(Self.idle, max(0, Self.longest - now.timeIntervalSince(first)))
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.run(.push) }
        }
    }

    /// Commits and pushes what is written, now.
    func commitAndPush() { run(.push) }

    /// The full round: commit, fetch, merge, push.
    func sync(becauseActivated: Bool = false) {
        guard git != nil else { return }
        if becauseActivated && Date().timeIntervalSince(lastFullSync) < Self.activationDedupe { return }
        lastFullSync = Date()
        run(.full)
    }

    private func run(_ mode: Git.Mode) {
        guard let git else { return }
        idleTimer?.invalidate()
        firstUnsaved = nil
        guard !running else {
            pending = pending == .full || mode == .full ? .full : .push
            return
        }
        running = true
        status = .syncing
        flush?()
        let name = mode == .full ? "Sync" : "Backup"
        Log.shared.info("sync", "\(name) started")
        Task {
            do {
                let report = try await git.sync(mode)
                Log.shared.info("sync", "\(name) finished" + (report.quiet ? ", nothing to do" : ": \(report)"))
                if !report.conflicted.isEmpty {
                    Log.shared.warning("sync", "Merged with conflicts to review", detail: report.conflicted.joined(separator: "\n"))
                }
                for file in report.skippedLargeFiles {
                    Log.shared.warning("sync", "Left out of the backup, too large: \(file.path)",
                                       detail: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                }
                if report.pulled {
                    StallWatch.doing("taking in what the sync pulled")
                    onPulled?(report.changed)
                    StallWatch.doing("idle")
                }
                if !report.conflicted.isEmpty { onConflicts?(report.conflicted) }
                if !report.skippedLargeFiles.isEmpty { onLargeFiles?(report.skippedLargeFiles) }
                status = .synced(Date())
            } catch {
                Log.shared.error("sync", "\(name) failed", detail: error.localizedDescription)
                status = .failed(error.localizedDescription)
            }
            running = false
            if let next = pending {
                pending = nil
                run(next)
            }
        }
    }

    /// Commits and pushes on the way out, giving it a few seconds.
    func finish() async {
        guard let git else { return }
        flush?()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await git.sync(.push) }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
    }
}
