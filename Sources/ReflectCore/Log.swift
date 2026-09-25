import Foundation

/// What the app did, for when something went wrong: every git command and
/// what it said, every sync and how it ended, files added, pictures that
/// would not load.
///
/// Kept in memory for the Console window, and appended to a file under
/// `~/Library/Logs`, where Console.app can read it too.
public final class Log: @unchecked Sendable {
    public static let shared = Log()
    /// Posted on the main queue with the new `Entry` as the object.
    public static let didAdd = Notification.Name("ReflectLogDidAdd")

    public enum Level: String, Sendable { case info, warning, error }

    public struct Entry: Sendable {
        public var date: Date
        public var level: Level
        public var category: String
        public var message: String
        /// More, when there is more: a command's output, an error's text.
        public var detail: String?
    }

    private let lock = NSLock()
    private var stored: [Entry] = []
    private static let limit = 5000
    private let file: FileHandle?
    public let fileURL: URL

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs").appendingPathComponent("Reflect Mac")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        fileURL = logs.appendingPathComponent("Reflect Mac.log")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        file = try? FileHandle(forWritingTo: fileURL)
        _ = try? file?.seekToEnd()
    }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    public func clear() {
        lock.lock()
        stored.removeAll()
        lock.unlock()
    }

    public func add(_ level: Level, _ category: String, _ message: String, detail: String? = nil) {
        let detail = detail.map { $0.count > 4000 ? String($0.prefix(4000)) + "…" : $0 }
        let entry = Entry(date: Date(), level: level, category: category, message: message, detail: detail?.isEmpty == true ? nil : detail)
        lock.lock()
        stored.append(entry)
        if stored.count > Self.limit { stored.removeFirst(stored.count - Self.limit) }
        var line = "\(Self.stamp.string(from: entry.date)) [\(level.rawValue)] \(category): \(message)\n"
        if let detail = entry.detail {
            line += detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    \($0)\n" }.joined()
        }
        try? file?.write(contentsOf: Data(line.utf8))
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didAdd, object: entry) }
    }

    public func info(_ category: String, _ message: String, detail: String? = nil) { add(.info, category, message, detail: detail) }
    public func warning(_ category: String, _ message: String, detail: String? = nil) { add(.warning, category, message, detail: detail) }
    public func error(_ category: String, _ message: String, detail: String? = nil) { add(.error, category, message, detail: detail) }

    static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
