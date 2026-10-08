import Foundation

/// Pages shared to Prism from other apps, waiting for Prism to make them
/// notes: the share extension leaves each here, in the container the app
/// and the extension both reach, and the app takes them in when it next
/// comes to the front. The extension never touches the graph.
enum ShareQueue {
    static let group = "group.com.mariusae.Prism"

    /// A page as shared: what the page said of itself, when the sharing app
    /// could tell — Safari can — and what was selected on it.
    struct Item: Codable, Equatable {
        var url: String
        var title: String
        var description: String
        var highlights: [String]
        var shared: Date
        /// "today": a bullet at the top of the day's note, linking to it;
        /// else, as before, a note of its own linked from the day.
        var destination: String? = nil
    }

    /// The last choice of where pages go, for the next share.
    static var lastDestination: String {
        get { UserDefaults(suiteName: group)?.string(forKey: "ShareDestination") ?? "note" }
        set { UserDefaults(suiteName: group)?.set(newValue, forKey: "ShareDestination") }
    }

    static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("Shared", isDirectory: true)
    }

    /// Leaves a page for the app: a file of its own, written whole.
    static func enqueue(_ item: Item) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%.0f-%@.json", item.shared.timeIntervalSince1970 * 1000, UUID().uuidString)
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// The pages waiting, oldest first, each with the file it is in.
    static func pending() -> [(item: Item, file: URL)] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { file in
            guard let data = try? Data(contentsOf: file), let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
            return (item, file)
        }
    }

    static func remove(_ file: URL) { try? FileManager.default.removeItem(at: file) }
}
