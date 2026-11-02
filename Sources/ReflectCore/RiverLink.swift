import Foundation

/// A link to one of Weft's saved rivers, written as a link to the file it
/// is — `[[rivers/Work]]` — so that it reads plainly wherever the graph
/// goes, and Prism and Weft alike know it for a river.
public enum RiverLink {
    /// The graph's folder of saved rivers, a file each.
    public static let folder = "rivers"
    /// What a river link shows before its name.
    public static let symbol = "square.stack"
    /// The frontmatter key naming a page's home river: `river: Work`.
    public static let homeKey = "river"

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

    /// The address that opens a saved river in Weft, from anywhere — a
    /// reminder, a message, Prism: `weft://river/Work`.
    public static func url(_ name: String) -> URL {
        let path = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? name
        return URL(string: "weft://river/\(path)")!
    }

    /// The river an address opens, or nil for one that is no river's.
    public static func name(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "weft", url.host()?.lowercased() == "river" else { return nil }
        let name = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return name.isEmpty ? nil : name
    }

    /// A saved river's cards, as its file has them — a link each, a row
    /// each; what is folded of them, indented under, left out — or nil
    /// when no river has the name.
    public static func cards(of name: String, in root: URL) -> [String]? {
        guard let text = try? String(contentsOf: root.appendingPathComponent(path(name)), encoding: .utf8) else { return nil }
        var body = Substring(text)
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            body = text[end.upperBound...]
        }
        return body.split(separator: "\n").compactMap { line in
            guard line.first != " ", line.first != "\t", let start = line.range(of: "[["),
                  let end = line.range(of: "]]", range: start.upperBound..<line.endIndex) else { return nil }
            let title = String(line[start.upperBound..<end.lowerBound])
            return title.isEmpty ? nil : title
        }
    }

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
