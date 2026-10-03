import CryptoKit
import Foundation
import ReflectCore

/// What web pages say about themselves, for links' cards: fetched once,
/// and kept, on disk, for next time.
///
/// A page that answers without a title, or is not there, is remembered as
/// having no card; one that does not answer at all is asked again later.
package final class LinkPreviewStore: @unchecked Sendable {
    package static let shared = LinkPreviewStore()

    private let lock = NSLock()
    private var known: [URL: PageMetadata?] = [:]
    private var waiting: [URL: [@MainActor (PageMetadata?) -> Void]] = [:]

    private static let directory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ReflectMac").appendingPathComponent("LinkPreviews")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static let maxBytes = 4 * 1024 * 1024

    private static func file(for url: URL) -> URL {
        directory.appendingPathComponent(SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
    }

    /// The page's card, when it is known — nil for not yet, `.some(nil)`
    /// for a page with none.
    package func cached(_ url: URL) -> PageMetadata?? {
        lock.lock()
        defer { lock.unlock() }
        if let known = known[url] { return known }
        let file = Self.file(for: url)
        if FileManager.default.fileExists(atPath: file.path + ".none") {
            known[url] = .some(nil)
            return .some(nil)
        }
        if let data = try? Data(contentsOf: file), let meta = try? JSONDecoder().decode(PageMetadata.self, from: data) {
            known[url] = meta
            return meta
        }
        return nil
    }

    /// Looks a page up, and says what it found, on the main thread.
    package func load(_ url: URL, then done: @escaping @MainActor (PageMetadata?) -> Void) {
        if let cached = cached(url) {
            DispatchQueue.main.async { MainActor.assumeIsolated { done(cached) } }
            return
        }
        lock.lock()
        let first = waiting[url] == nil
        waiting[url, default: []].append(done)
        lock.unlock()
        guard first else { return }

        Task.detached(priority: .userInitiated) {
            var request = URLRequest(url: url, timeoutInterval: 15)
            // Some sites answer only what looks like a browser.
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            var result: PageMetadata??
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let http = response as? HTTPURLResponse
                let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
                if let status = http?.statusCode, !(200..<300).contains(status) {
                    // Not there (4xx): no card. A server's bad day (5xx): try again another time.
                    result = (400..<500).contains(status) ? .some(nil) : nil
                } else if data.count <= Self.maxBytes, type.contains("html") {
                    let html = String(decoding: data, as: UTF8.self)
                    result = .some(PageMetadata.parse(html: html, url: response.url ?? url))
                } else {
                    result = .some(nil)
                }
            } catch {
                Log.shared.info("links", "Could not reach \(url.host ?? url.absoluteString)", detail: error.localizedDescription)
                result = nil
            }
            if let result {
                let file = Self.file(for: url)
                if let meta = result, let data = try? JSONEncoder().encode(meta) {
                    try? data.write(to: file, options: .atomic)
                } else {
                    FileManager.default.createFile(atPath: file.path + ".none", contents: nil)
                }
            }
            let callbacks = self.lock.withLock {
                if let result { self.known[url] = result }
                return self.waiting.removeValue(forKey: url) ?? []
            }
            let found = result ?? nil
            await MainActor.run { for callback in callbacks { callback(found) } }
        }
    }
}
