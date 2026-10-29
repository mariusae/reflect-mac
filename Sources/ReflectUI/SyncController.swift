import AppKit
import ReflectCore

/// Keeps the graph's repository in step, on Reflect's schedule.
///
/// Writing is committed and pushed `idle` seconds after it stops — thirty,
/// as Reflect does, unless the app says otherwise — and never
/// more than five minutes after it starts. A full sync — commit, fetch,
/// merge, push — runs at launch, when the app comes to the front, and when
/// asked; there is no timer beyond that. One cycle runs at a time; asking
/// during one queues one more after it, and a full sync asked for then is
/// not made a lesser one.
@MainActor
package final class SyncController {
    package enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
        case unavailable
    }

    /// How syncing has gone here: kept across launches, for each repository.
    package struct Record: Codable, Equatable {
        package var lastAttempt: Date?
        package var lastSuccess: Date?
        /// The last cycle that took in what other devices pushed.
        package var lastFullSuccess: Date?
        package var lastFailure: Date?
        package var lastFailureMessage: String?
        /// What the last cycle to finish did, and how long it took.
        package var lastReport: String?
        package var lastTiming: String?
    }

    /// Since launch.
    package struct Stats: Equatable {
        package var since = Date()
        package var syncs = 0
        package var failures = 0
        /// Files the merges wrote.
        package var pulled = 0
        package var conflicts = 0
    }

    package let git: Git?
    package private(set) var record: Record {
        didSet {
            guard let key = recordKey, let data = try? JSONEncoder().encode(record) else { return }
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    package private(set) var stats = Stats()
    /// Whether a cycle is running now, and which.
    package private(set) var runningMode: Git.Mode?
    package private(set) var status: Status {
        didSet { onStatus?(status) }
    }
    package var onStatus: ((Status) -> Void)?
    /// Told of the files a merge wrote.
    package var onPulled: (([String]) -> Void)?
    /// Asked to write what is unsaved, before a commit.
    package var flush: (() -> Void)?
    /// Told when a merge left notes needing review.
    package var onConflicts: (([String]) -> Void)?
    /// Told of files too large to commit.
    package var onLargeFiles: (([(path: String, size: Int)]) -> Void)?
    /// Done before each cycle — a GitHub token refreshed, when it runs out.
    package var prepare: (() async throws -> Void)?

    private let recordKey: String?
    private var idleTimer: Timer?
    private var firstUnsaved: Date?
    private var running = false
    private var pending: Git.Mode?
    private var lastFullSync = Date.distantPast

    /// How long writing must pause before it is pushed.
    package var idle: TimeInterval = 30
    private static let longest: TimeInterval = 300
    /// Coming to the front twice in a moment is one sync.
    private static let activationDedupe: TimeInterval = 1.5

    /// Told what the app is busy with, for an app that watches for stalls.
    package static var doing: (String) -> Void = { _ in }

    package init(git: Git?) {
        self.git = git
        status = git == nil ? .unavailable : .idle
        let key = git.map { "SyncRecord " + $0.root.standardizedFileURL.path }
        recordKey = key
        record = key.flatMap { UserDefaults.standard.data(forKey: $0) }.flatMap { try? JSONDecoder().decode(Record.self, from: $0) } ?? Record()
    }

    /// Something was written; commit it once writing pauses.
    package func noteChanged() {
        guard git != nil else { return }
        let now = Date()
        let first = firstUnsaved ?? now
        firstUnsaved = first
        let wait = min(idle, max(0, Self.longest - now.timeIntervalSince(first)))
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.run(.push) }
        }
    }

    /// Commits and pushes what is written, now.
    package func commitAndPush() { run(.push) }

    /// The full round: commit, fetch, merge, push.
    package func sync(becauseActivated: Bool = false) {
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
        runningMode = mode
        record.lastAttempt = Date()
        status = .syncing
        flush?()
        let name = mode == .full ? "Sync" : "Backup"
        Log.shared.info("sync", "\(name) started")
        Task {
            do {
                try await prepare?()
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
                    Self.doing("taking in what the sync pulled")
                    onPulled?(report.changed)
                    Self.doing("idle")
                }
                if !report.conflicted.isEmpty { onConflicts?(report.conflicted) }
                if !report.skippedLargeFiles.isEmpty { onLargeFiles?(report.skippedLargeFiles) }
                let now = Date()
                record.lastSuccess = now
                if mode == .full { record.lastFullSuccess = now }
                record.lastReport = report.quiet ? "Nothing to do" : report.description
                record.lastTiming = report.timingSummary
                stats.syncs += 1
                stats.pulled += report.changed.count
                stats.conflicts += report.conflicted.count
                status = .synced(now)
            } catch is SyncStopped {
                Log.shared.info("sync", "\(name) stopped at a safe point, to go on next time")
                status = .idle
            } catch {
                Log.shared.error("sync", "\(name) failed", detail: error.localizedDescription)
                record.lastFailure = Date()
                record.lastFailureMessage = error.localizedDescription
                stats.syncs += 1
                stats.failures += 1
                status = .failed(error.localizedDescription)
            }
            running = false
            runningMode = nil
            if let next = pending {
                pending = nil
                run(next)
            }
        }
    }

    /// Commits and pushes on the way out, giving it a few seconds.
    package func finish() async {
        guard let git else { return }
        flush?()
        let prepare = prepare
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await prepare?()
                _ = try? await git.sync(.push)
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
    }
}
