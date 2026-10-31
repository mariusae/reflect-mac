import Foundation
import ReflectCore

/// What a note gives the reader: a page on the web it links to, a PDF on
/// the web it links to, or a PDF in the graph it embeds — its own page
/// first, a link note's `URL:`, then each as the note goes down, once.
public struct ReaderSource: Hashable, Sendable {
    /// As the note writes it: the page's address, or the PDF's source in the graph.
    public let address: String
    /// The page, or the PDF: its file in the graph, or its address on the web.
    public let url: URL
    public let isPDF: Bool

    /// A PDF on the web, to be fetched before it is read.
    public var isOnline: Bool { !url.isFileURL }

    /// A PDF on the web that turned out not to be one — a page asking to
    /// sign in, say: read as the page it is.
    public var asPage: ReaderSource { ReaderSource(address: address, url: url, isPDF: false) }

    /// Everything in a note to read, in order: none, a note with nothing.
    public static func all(in text: String, root: URL) -> [ReaderSource] {
        var found: [ReaderSource] = []
        func add(_ address: String) {
            guard !found.contains(where: { $0.address == address }), let source = source(address, root: root) else { return }
            found.append(source)
        }
        if let own = WebCapture.url(in: text) { add(own) }
        for row in OutlineMarkdown.parse(text).unfoldedRows {
            let line = row.text as NSString
            for span in InlineMarkup.spans(in: line, range: NSRange(location: 0, length: line.length)) {
                switch span.kind {
                case .link(let target), .url(let target): add(target)
                case .image(let reference) where reference.source.lowercased().hasSuffix(".pdf"): add(reference.source)
                default: break
                }
            }
        }
        return found
    }

    /// A page on the web, a PDF there, or a PDF in the graph's assets: nil, anything else.
    static func source(_ address: String, root: URL) -> ReaderSource? {
        if address.hasPrefix("http://") || address.hasPrefix("https://") {
            // Not a picture, or a file to download.
            let last = (URL(string: address)?.path ?? "").lowercased()
            guard let url = URL(string: address),
                  ![".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip", ".mp4", ".mov"].contains(where: last.hasSuffix) else { return nil }
            return ReaderSource(address: address, url: url, isPDF: isPDF(url))
        }
        // As the notes' own PDFs are read: inside `assets/`, and no `..` out of it.
        let path = address.removingPercentEncoding ?? address
        guard path.lowercased().hasSuffix(".pdf"), path.hasPrefix("assets/"), !path.contains("\\"),
              path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        let file = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return ReaderSource(address: address, url: file, isPDF: true)
    }

    /// A PDF on the web, by its address: a `.pdf` file, or arXiv's paper.
    static func isPDF(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".pdf") || (url.host?.lowercased().hasSuffix("arxiv.org") == true && path.hasPrefix("/pdf/"))
    }

    /// Its name, short: the site, or the PDF's file.
    public var name: String {
        isPDF ? url.deletingPathExtension().lastPathComponent : (url.host ?? address).replacingOccurrences(of: "www.", with: "")
    }
}

extension ReaderPlace {
    /// Which of a note's sources was read last: read first again.
    public static func chosen(in sources: [ReaderSource], for notePath: String) -> Int {
        let address = UserDefaults.standard.string(forKey: "Reader.source." + notePath)
        return sources.firstIndex { $0.address == address } ?? 0
    }

    public static func choose(_ source: ReaderSource, for notePath: String, first: Bool) {
        UserDefaults.standard.set(first ? nil : source.address, forKey: "Reader.source." + notePath)
    }
}
