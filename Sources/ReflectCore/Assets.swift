import Foundation

/// Files added to a graph — pictures pasted in, documents dropped in — kept
/// under `assets/` and named as Reflect names them.
public enum Assets {
    public static let directory = "assets"
    /// Above this, adding a file is worth a word: every version stays in the
    /// repository forever, and GitHub turns away files over 100 MB.
    public static let largeFileBytes = 25 * 1024 * 1024

    /// Picture types that are named for when they were pasted, having no
    /// name worth keeping, with the extension each is saved under.
    public static let imageExtensions: [String: String] = [
        "public.png": "png", "public.jpeg": "jpg", "com.compuserve.gif": "gif",
        "org.webmproject.webp": "webp", "public.svg-image": "svg",
    ]

    /// `pasted-1790045733506.png`: a pasted or dropped picture's name.
    public static func pastedName(extension ext: String, at date: Date = Date()) -> String {
        "pasted-\(Int64((date.timeIntervalSince1970 * 1000).rounded(.down))).\(ext)"
    }

    /// Any other file's name on disk, from its own: the stem made a slug,
    /// inner dots dashes, the extension kept, lowercased and alphanumeric.
    /// `Q3 Report (final).PDF` → `q3-report-final.pdf`. The original name
    /// is what the link says.
    public static func fileName(for original: String) -> String {
        let trimmed = original.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = trimmed
        var ext = ""
        if let dot = trimmed.lastIndex(of: "."), dot > trimmed.startIndex, trimmed.index(after: dot) < trimmed.endIndex {
            stem = String(trimmed[..<dot])
            ext = String(trimmed[trimmed.index(after: dot)...].lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) }.prefix(12))
        }
        let slug = self.slug(stem.replacingOccurrences(of: ".", with: "-"))
        return ext.isEmpty ? slug : "\(slug).\(ext)"
    }

    private static let reserved = Set(["con", "prn", "aux", "nul"] + (1...9).flatMap { ["com\($0)", "lpt\($0)"] })

    /// Reflect's readable-filename slug: lowercase, letters and numbers
    /// kept, separator runs one dash, at most 60 characters, never empty,
    /// never a name Windows reserves.
    public static func slug(_ title: String) -> String {
        let folded = title.precomposedStringWithCanonicalMapping.lowercased()
        var result = ""
        var pendingDash = false
        for character in folded {
            let isSeparator = character.isWhitespace || character == "_" || character == "-"
            if isSeparator {
                pendingDash = true
            } else if character.isLetter || character.isNumber {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.append(character)
            }
            // Anything else is dropped, and does not end a run of separators.
        }
        var capped = String(String.UnicodeScalarView(result.unicodeScalars.prefix(60)))
        while capped.hasSuffix("-") { capped.removeLast() }
        if capped.isEmpty { return "untitled" }
        return reserved.contains(capped) ? "\(capped)-note" : capped
    }

    /// Copies bytes into `assets/` under `name`, or the first free `-2`,
    /// `-3`, … variant of it, never over another file. Returns the
    /// graph-relative path it went to.
    public static func add(_ data: Data, named name: String, to root: URL) throws -> String {
        let folder = root.appendingPathComponent(directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dot = name.lastIndex(of: ".").flatMap { $0 > name.startIndex ? $0 : nil }
        let stem = dot.map { String(name[..<$0]) } ?? name
        let ext = dot.map { String(name[$0...]) } ?? ""
        for attempt in 1...1000 {
            let candidate = attempt == 1 ? name : "\(stem)-\(attempt)\(ext)"
            let url = folder.appendingPathComponent(candidate)
            // Created only if nothing is there: the test and the claim at once.
            let descriptor = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if descriptor < 0 {
                if errno == EEXIST { continue }
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            return "\(directory)/\(candidate)"
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
