import AppKit
import ReflectCore
import ReflectUI

/// Notes when the main thread stops answering — the app not responding to
/// a click, a key, or being brought forward — for long enough to be felt:
/// how long, and what it was last doing, in the Console window's log.
///
/// Only while the app is the one in use: in the background, macOS naps it,
/// and its answers wait — which is not the app being stuck. A stall whose
/// sample finds the main thread only waiting for something to do is not
/// one either.
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

    /// Whether the app is the one in use; set as it comes forward — before
    /// what it does then, which is watched — and as it goes back.
    private var active = true

    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: nil) { [self] _ in
            lock.withLock {
                active = true
                lastAnswer = Date()
                stalledSince = nil
                sampled = nil
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [self] _ in
            lock.withLock {
                active = false
                stalledSince = nil
                sampled = nil
            }
        }
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

    /// Whether a sample of the main thread finds it mostly waiting for
    /// events — four in five of its samples in the run loop's wait.
    static func isIdle(_ trace: String) -> Bool {
        let lines = trace.components(separatedBy: "\n")
        func count(_ line: String) -> Int? {
            line.split(whereSeparator: { $0 == " " || $0 == "+" || $0 == "!" || $0 == ":" || $0 == "|" }).first.flatMap { Int($0) }
        }
        guard let total = lines.first(where: { $0.contains("Thread_") }).flatMap(count), total > 0,
              let waiting = lines.first(where: { $0.contains("__CFRunLoopServiceMachPort") }).flatMap(count) else { return false }
        return Double(waiting) >= 0.8 * Double(total)
    }

    private func watch() {
        while true {
            Thread.sleep(forTimeInterval: Self.interval)
            DispatchQueue.main.async { [self] in
                lock.withLock { lastAnswer = Date() }
            }
            let (answered, doing, active) = lock.withLock { (lastAnswer, activity, self.active) }
            guard active else { continue }
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
                // Sampled only waiting: it was not stuck, only not running.
                if let trace, Self.isIdle(trace) { continue }
                Log.shared.warning("app", String(format: "Not answering for %.1f s", seconds),
                                   detail: "Doing: \(doing)" + (trace.map { "\n\nThe main thread, sampled while stuck:\n" + $0 } ?? ""))
            }
        }
    }
}
