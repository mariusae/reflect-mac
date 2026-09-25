import CryptoKit
import Foundation

/// The text in the graph's pictures, for finding notes by what their
/// pictures say.
///
/// A picture's text is Reflect's description of it when there is one —
/// `assets/x.png.reflect.md`, beside the picture, written by Reflect — and
/// otherwise what this Mac read in it, kept in a cache outside the graph:
/// nothing is written into the graph, so nothing more is synced.
public final class ImageTextIndex: @unchecked Sendable {
    public let root: URL
    private let cache: URL
    private let lock = NSLock()
    /// Each picture's text, as written and folded for matching.
    private var texts: [String: (text: String, folded: String)] = [:]
    /// The key each picture's text was read under, to notice it changing.
    private var keys: [String: String] = [:]

    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]
    /// Reflect's description of an asset, beside it.
    public static let descriptionSuffix = ".reflect.md"

    public init(root: URL, cache: URL) {
        self.root = root
        self.cache = cache
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    /// A picture still to be read, and the key its text is to be kept under.
    public struct Pending: Sendable {
        public var path: String
        public var key: String
        public var url: URL
    }

    /// Takes in what is known of the pictures under `assets/` — Reflect's
    /// descriptions, and text read before — and says which are still to be
    /// read. Cheap enough to call whenever pictures may have come or gone.
    public func refresh() -> [Pending] {
        let assets = root.appendingPathComponent(Assets.directory).resolvingSymlinksInPath()
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: assets, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                              options: [.skipsHiddenFiles]) else { return [] }
        lock.lock()
        let knownKeys = keys
        lock.unlock()
        var found: [String: (text: String, folded: String)] = [:]
        var foundKeys: [String: String] = [:]
        var pending: [Pending] = []
        for case let url as URL in walker where Self.extensions.contains(url.pathExtension.lowercased()) {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(assets.path + "/") else { continue }
            let path = Assets.directory + "/" + full.dropFirst(assets.path.count + 1)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            // Reflect's description wins: it has the text and more.
            let description = URL(fileURLWithPath: url.path + Self.descriptionSuffix)
            if let source = try? String(contentsOf: description, encoding: .utf8) {
                let body = Self.body(of: source)
                if !body.isEmpty {
                    found[path] = (body, NoteIndex.foldKey(body))
                    foundKeys[path] = "description"
                    continue
                }
            }
            let key = Self.key(path: path, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast)
            foundKeys[path] = key
            if knownKeys[path] == key, let known = text(path) {
                found[path] = (known, NoteIndex.foldKey(known))
            } else if let cached = try? String(contentsOf: cache.appendingPathComponent(key), encoding: .utf8) {
                if !cached.isEmpty { found[path] = (cached, NoteIndex.foldKey(cached)) }
            } else {
                pending.append(Pending(path: path, key: key, url: url))
            }
        }
        lock.lock()
        texts = found
        keys = foundKeys
        lock.unlock()
        return pending
    }

    /// Keeps what was read in a picture — nothing, too, so it is not read again.
    public func store(_ text: String, for pending: Pending) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try? text.write(to: cache.appendingPathComponent(pending.key), atomically: true, encoding: .utf8)
        lock.lock()
        if !text.isEmpty { texts[pending.path] = (text, NoteIndex.foldKey(text)) }
        keys[pending.path] = pending.key
        lock.unlock()
    }

    /// A picture's text, if it has any.
    public func text(_ path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return texts[path]?.text
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return texts.count
    }

    /// Pictures with every word of a query in their text, and the text
    /// around the first, with the words between `\u{1}` and `\u{2}`.
    public func search(_ query: String, limit: Int = 20) -> [(path: String, snippet: String)] {
        let terms = NoteIndex.foldKey(query).split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return [] }
        lock.lock()
        let all = texts
        lock.unlock()
        var found: [(path: String, snippet: String)] = []
        for (path, text) in all.sorted(by: { $0.key > $1.key }) where terms.allSatisfy({ text.folded.contains($0) }) {
            found.append((path, Self.snippet(text.text, terms: terms)))
            if found.count == limit { break }
        }
        return found
    }

    static func snippet(_ text: String, terms: [String]) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let first = flat.range(of: terms[0], options: [.caseInsensitive, .diacriticInsensitive]) else { return String(flat.prefix(100)) }
        let start = flat.index(first.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(first.upperBound, offsetBy: 80, limitedBy: flat.endIndex) ?? flat.endIndex
        var snippet = String(flat[start..<end])
        for term in terms {
            var from = snippet.startIndex
            while let range = snippet.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: from..<snippet.endIndex) {
                let marked = "\u{1}" + snippet[range] + "\u{2}"
                snippet.replaceSubrange(range, with: marked)
                from = snippet.index(range.lowerBound, offsetBy: marked.count)
            }
        }
        return (start > flat.startIndex ? "…" : "") + snippet + (end < flat.endIndex ? "…" : "")
    }

    /// A description's text, its frontmatter left out.
    static func body(of source: String) -> String {
        var body = Substring(source)
        if body.hasPrefix("---\n"), let close = body.range(of: "\n---\n", range: body.index(body.startIndex, offsetBy: 3)..<body.endIndex) {
            body = body[close.upperBound...]
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func key(path: String, size: Int, modified: Date) -> String {
        let identity = "\(path)\n\(size)\n\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension NoteIndex {
    /// Notes that show a picture, newest first.
    public func notes(showing asset: String) -> [String] {
        notePaths(showing: asset).compactMap(entry).sorted { $0.modified > $1.modified }.map(\.path)
    }
}
