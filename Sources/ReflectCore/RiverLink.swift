import Foundation

/// A link to one of Weft's saved rivers, written as a link to the file it
/// is — `[[rivers/Work]]` — so that it reads plainly wherever the graph
/// goes, and Prism and Weft alike know it for a river.
public enum RiverLink {
    /// The graph's folder of saved rivers, a file each.
    public static let folder = "rivers"
    /// What a river link shows before its name.
    public static let symbol = "square.stack"

    /// The river a link's target names — `rivers/Work` is `Work` — or nil
    /// for a target that is no river.
    public static func name(_ target: String) -> String? {
        let target = target.trimmingCharacters(in: .whitespaces)
        guard target.count > folder.count + 1, target.lowercased().hasPrefix(folder + "/") else { return nil }
        var name = String(target.dropFirst(folder.count + 1))
        if name.lowercased().hasSuffix(".md") { name.removeLast(3) }
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// A link's target for a river: `Work` is `rivers/Work`.
    public static func target(_ name: String) -> String { "\(folder)/\(name)" }

    /// The link written for a river: `[[rivers/Work]]`.
    public static func link(_ name: String) -> String { "[[\(target(name))]]" }

    /// A river's file, in the graph.
    public static func path(_ name: String) -> String { "\(folder)/\(name).md" }

    /// The graph's saved rivers, by name.
    public static func names(in root: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []
        return files.filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.map { String($0.dropLast(3)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The saved rivers whose names have what is typed in them, to link to.
    public static func matching(_ query: String, in root: URL, limit: Int = 4) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return Array(names(in: root).filter { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.prefix(limit))
    }
}
