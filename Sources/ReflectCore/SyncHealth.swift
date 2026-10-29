import Foundation

/// How the graph's repository stands, to see whether it is kept in step:
/// against the remote as last fetched, anything left in the way, and when
/// each device last pushed — by the device each commit names.
public struct SyncHealth: Sendable {
    /// A device the remote's history names, and its newest commit there.
    public struct Device: Sendable, Equatable {
        public var name: String
        public var last: Date
        public var message: String
    }

    public var branch: String?
    public var head: String?
    public var remote: String?
    /// Whether the remote's branch is here at all: fetched once, at least.
    public var hasRemoteBranch = false
    /// Commits here not on the remote, and there not here — as of the last fetch.
    public var ahead = 0
    public var behind = 0
    /// What another tool left the repository in the middle of.
    public var operation: String?
    /// How long a git lock has been left, when one is.
    public var lockAge: TimeInterval?
    /// The remote's newest commit.
    public var newest: GitCommitSummary?
    /// The devices the remote's recent history names, the latest first.
    public var devices: [Device] = []
    /// The newest commit naming no device: Reflect's, or before devices were named.
    public var unnamed: GitCommitSummary?

    public init() {}
}

extension Git {
    /// The device commits made here are said to come from, in a trailer
    /// under the message — `Device: Marius's MacBook Pro` — so the history
    /// says which device last pushed. Nil, none.
    nonisolated(unsafe) public static var device: String?
    static let deviceTrailer = "Device: "
    /// How far back the history is read for devices.
    static let devicesLookBack = 400

    static func stamped(_ message: String) -> String {
        guard let device = device?.trimmingCharacters(in: .whitespacesAndNewlines), !device.isEmpty else { return message }
        return message + "\n\n" + deviceTrailer + device
    }

    /// The device a commit's message names, if it names one.
    public static func device(in message: String) -> String? {
        message.split(separator: "\n").reversed().lazy
            .first { $0.hasPrefix(deviceTrailer) }
            .map { String($0.dropFirst(deviceTrailer.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The commit's first line.
    public static func subject(of message: String) -> String {
        message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    /// How the repository stands, now — after any cycle under way.
    public func health() async -> SyncHealth {
        (try? await turn { self.readHealth() }) ?? SyncHealth()
    }

    func readHealth() -> SyncHealth {
        var health = SyncHealth()
        health.branch = try? backend.currentBranch()
        health.head = backend.head()
        health.remote = backend.remoteURL("origin")
        health.operation = try? backend.operationInProgress()
        if let directory = try? backend.gitDirectory(),
           let date = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("index.lock").path))?[.modificationDate] as? Date {
            health.lockAge = Date().timeIntervalSince(date)
        }
        guard let branch = health.branch else { return health }
        let remote = "refs/remotes/origin/\(branch)"
        guard backend.resolves(remote) else { return health }
        health.hasRemoteBranch = true
        if health.head != nil, let counts = try? backend.divergence(remote) {
            health.ahead = counts.ahead
            health.behind = counts.behind
        }
        let commits = backend.recentCommits(remote, limit: Self.devicesLookBack)
        health.newest = commits.first
        var seen = Set<String>()
        for commit in commits {
            if let name = Self.device(in: commit.message) {
                guard seen.insert(name).inserted else { continue }
                health.devices.append(.init(name: name, last: commit.date, message: Self.subject(of: commit.message)))
            } else if health.unnamed == nil {
                health.unnamed = commit
            }
        }
        return health
    }
}
