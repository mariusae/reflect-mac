import Foundation
import ReflectCore

/// The sync relay (`worker/`): GitHub tells it of each push to a graph's
/// repository, and it tells the devices that keep the graph — an iPhone by
/// a silent push, a Mac over a WebSocket it holds open — so each syncs at
/// once. Devices prove they may hear of a repository with their GitHub
/// token, which the relay checks with GitHub and does not keep.
public enum SyncRelay {
    /// Where the relay is: its host, from the app's Info.plist. Nil, none.
    public static var host: String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: "SyncRelayHost") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }

    /// `owner/name`, from a GitHub remote's address.
    public static func repository(fromRemote url: String?) -> String? {
        guard let url, let range = url.range(of: "github.com[/:]", options: .regularExpression) else { return nil }
        var path = String(url[range.upperBound...])
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/")
        return parts.count == 2 ? "\(parts[0])/\(parts[1])" : nil
    }

    /// An iPhone's push token, to be sent a silent push when the repository
    /// is pushed to; `topic` is the app's bundle identifier, `sandbox`
    /// whether the app was signed for development.
    public static func register(deviceToken: Data, repository: String, topic: String, sandbox: Bool, accessToken: String) async throws {
        try await devices("POST", ["repository": repository, "token": hex(deviceToken), "topic": topic,
                                   "environment": sandbox ? "sandbox" : "production"], accessToken: accessToken)
    }

    public static func unregister(deviceToken: Data, repository: String, accessToken: String) async throws {
        try await devices("DELETE", ["repository": repository, "token": hex(deviceToken)], accessToken: accessToken)
    }

    private static func devices(_ method: String, _ body: [String: String], accessToken: String) async throws {
        guard let host else { return }
        var request = URLRequest(url: URL(string: "https://\(host)/devices")!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw GitHubError("The sync relay answered \(status): \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        Log.shared.info("relay", "\(method == "DELETE" ? "Unregistered" : "Registered") for pushes to \(body["repository"] ?? "")")
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// Whether the app was signed to be pushed to through APNs' sandbox: its
    /// provisioning profile says `aps-environment` is `development`. One
    /// from the App Store has no profile, and is pushed to for real.
    public static var isSandbox: Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return false }
        return text[key.upperBound...].prefix(80).contains("development")
    }
}

/// A Mac listening to the relay for pushes to its graph's repository: a
/// WebSocket held open, kept alive, and opened again — sooner after a
/// moment's trouble, later after a long one — when it drops.
@MainActor
public final class SyncRelayListener {
    private let repository: String
    private let accessToken: () async throws -> String
    private let onPush: () -> Void
    private var task: URLSessionWebSocketTask?
    private var keepAlive: Timer?
    private var retry: Timer?
    private var failures = 0
    private var stopped = false

    /// `accessToken` gives a GitHub token good for a while yet; `onPush`
    /// is told of each push.
    public init(repository: String, accessToken: @escaping () async throws -> String, onPush: @escaping () -> Void) {
        self.repository = repository
        self.accessToken = accessToken
        self.onPush = onPush
    }

    public func start() {
        stopped = false
        guard task == nil, let host = SyncRelay.host,
              let name = repository.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        Task {
            let token: String
            do {
                token = try await accessToken()
            } catch {
                return scheduleRetry()
            }
            guard !stopped, task == nil else { return }
            var request = URLRequest(url: URL(string: "wss://\(host)/events?repository=\(name)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            self.task = task
            task.resume()
            receive(task)
            keepAlive?.invalidate()
            // Cloudflare closes a quiet socket; a word now and then keeps it open.
            keepAlive = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak task] _ in
                MainActor.assumeIsolated {
                    guard let self, let task, task === self.task else { return }
                    task.send(.string("ping")) { error in
                        if error != nil { Task { @MainActor in self.dropped(task) } }
                    }
                }
            }
        }
    }

    public func stop() {
        stopped = true
        keepAlive?.invalidate()
        retry?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    /// Opened again now — the Mac woke, or came back online.
    public func reconnect() {
        guard !stopped else { return }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        failures = 0
        start()
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.task else { return }
                switch result {
                case .success(.string(let text)):
                    self.failures = 0
                    if text.contains("\"push\"") {
                        Log.shared.info("relay", "Told of a push")
                        self.onPush()
                    }
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    self.dropped(task)
                }
            }
        }
    }

    private func dropped(_ dropped: URLSessionWebSocketTask) {
        guard dropped === task else { return }
        task = nil
        keepAlive?.invalidate()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard !stopped else { return }
        failures += 1
        let delay = min(300, 5 * pow(2, Double(min(failures - 1, 6))))
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }
}
