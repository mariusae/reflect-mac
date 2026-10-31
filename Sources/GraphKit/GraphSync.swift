import Foundation
import Observation
import ReflectCore

/// Keeps the graph's repository in step on Reflect's schedule, through
/// Reflect's own sync (`Git`): writing is committed and pushed thirty
/// seconds after it stops, and never more than five minutes after it
/// starts; a full sync — commit, fetch, merge, push — runs when asked: at
/// launch, on coming to the front, and on ⌘R. One cycle runs at a time;
/// asking during one queues one more after it.
///
/// Two devices' changes to one page have their frontmatter put together
/// field by field before the bodies are merged by lines (`PageMerge`).
@MainActor @Observable
public final class GraphSync {
    public enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    public let git: Git
    public private(set) var status: Status = .idle
    /// Told of the files a merge wrote, to read again.
    @ObservationIgnored public var onPulled: ([String]) -> Void = { _ in }
    /// Done before each cycle: a GitHub token refreshed, on the phone.
    @ObservationIgnored public var prepare: (() async throws -> Void)?

    /// How long writing must pause before it is pushed.
    public var idle: TimeInterval = 30
    private static let longest: TimeInterval = 300

    @ObservationIgnored private var firstUnsaved: Date?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var pending: Git.Mode?
    @ObservationIgnored private var completions: [(Bool) -> Void] = []

    public init(git: Git) {
        self.git = git
        git.prepareMerge = { path, ours, base, theirs in
            PageMerge.prepare(path: path, ours: ours, base: base, theirs: theirs)
        }
    }

    /// Something was written: commit and push it once writing pauses.
    public func noteChanged() {
        let now = Date()
        let first = firstUnsaved ?? now
        firstUnsaved = first
        let wait = min(idle, max(0, Self.longest - now.timeIntervalSince(first)))
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.run(.push)
        }
    }

    /// The full round, now.
    public func sync() { run(.full) }

    /// The full round, now, and then told whether it brought anything in:
    /// for a silent push, whose time the system measures.
    public func sync(completion: @escaping (Bool) -> Void) {
        completions.append(completion)
        run(.full)
    }

    /// Commits and pushes what is written, now.
    public func push() { run(.push) }

    private func run(_ mode: Git.Mode) {
        waiting?.cancel()
        firstUnsaved = nil
        guard !running else {
            pending = pending == .full || mode == .full ? .full : .push
            return
        }
        running = true
        status = .syncing
        let toTell = mode == .full ? completions : []
        if mode == .full { completions = [] }
        Task {
            var pulled = false
            do {
                try await prepare?()
                let report = try await git.sync(mode)
                pulled = report.pulled
                if report.pulled { onPulled(report.changed) }
                status = .synced(Date())
            } catch is SyncStopped {
                status = .idle
            } catch {
                status = .failed(error.localizedDescription)
            }
            for completion in toTell { completion(pulled) }
            running = false
            if let next = pending {
                pending = nil
                run(next)
            }
        }
    }
}
