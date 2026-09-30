import Foundation
import ReflectCore

/// Notes when the main thread stops answering — the app not responding to
/// a click, a key, or being brought forward — for long enough to be felt:
/// how long, and what it was last doing, in the Console window's log.
///
/// Work that might take a while says what it is with `StallWatch.doing`;
/// a stall names the last thing said. A stall of more than a second is
/// sampled while it lasts — what the main thread is in the middle of, as
/// `sample` sees it — and that goes in the log with it.
final class StallWatch: @unchecked Sendable {
    static let shared = StallWatch()

    /// How long a stall must be to be noted.
    static let threshold: TimeInterval = 0.25
    private static let interval: TimeInterval = 0.05

    private let lock = NSLock()
    private var lastAnswer = Date()
    private var activity = "idle"
    private var stalledSince: Date?
    private var sampled: String?
    /// What the main thread was doing when it stopped answering.
    private var stalledDoing = "idle"
    /// How long a stall must go on to be sampled.
    static let sampleAfter: TimeInterval = 1
    /// The stalls noted, for scripts.
    private(set) var stalls: [(seconds: Double, doing: String)] = []

    func start() {
        let thread = Thread { [self] in watch() }
        thread.name = "Stall watch"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Says what the main thread is about to do, for a stall to name.
    static func doing(_ what: String) {
        shared.lock.withLock { shared.activity = what }
    }

    /// The main thread's calls, as `sample` catches them over half a
    /// second: its busiest lines, the frames they were in.
    private static func sampleMainThread() -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("reflect-stall-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "1", "1", "-file", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "(sample could not run)" }
        process.waitUntilExit()
        guard let text = try? String(contentsOf: output, encoding: .utf8) else { return "(no sample)" }
        // The main thread's tree, and no more.
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("com.apple.main-thread") }) else { return String(text.prefix(4000)) }
        var tree: [String] = []
        for line in lines[start...].prefix(120) {
            if tree.count > 1, line.trimmingCharacters(in: .whitespaces).hasPrefix("+") == false,
               line.contains("Thread_") { break }
            tree.append(line)
        }
        return tree.joined(separator: "\n")
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: Self.interval)
            DispatchQueue.main.async { [self] in
                lock.withLock { lastAnswer = Date() }
            }
            let (answered, doing) = lock.withLock { (lastAnswer, activity) }
            let silent = Date().timeIntervalSince(answered)
            if silent > Self.threshold {
                lock.withLock {
                    if stalledSince == nil {
                        stalledSince = answered
                        stalledDoing = doing
                    }
                }
                // Still stuck after a second: what it is stuck in, while it is.
                if silent > Self.sampleAfter, lock.withLock({ sampled == nil }) {
                    let trace = Self.sampleMainThread()
                    lock.withLock { sampled = trace }
                }
            } else if let since = lock.withLock({ stalledSince }) {
                let seconds = answered.timeIntervalSince(since)
                let (trace, doing) = lock.withLock {
                    let found = (sampled, stalledDoing)
                    stalledSince = nil
                    sampled = nil
                    stalls.append((seconds, stalledDoing))
                    return found
                }
                Log.shared.warning("app", String(format: "Not answering for %.1f s", seconds),
                                   detail: "Doing: \(doing)" + (trace.map { "\n\nThe main thread, sampled while stuck:\n" + $0 } ?? ""))
            }
        }
    }
}
