import AppKit
import CryptoKit
import ImageIO
import ReflectCore

/// The pictures a graph's notes show: its own assets, read from disk, and
/// images on the web, fetched once and kept.
///
/// A source that is not a picture — a tweet's page written as an image, a
/// `blob:` address from another device — is remembered as such, so it is
/// asked after once, and its Markdown is left showing.
///
/// Used only on the main thread, where the text system runs; a fetch hops
/// back to it before touching anything.
final class ImageStore: @unchecked Sendable {
    /// Posted with the source as the object when an image arrives.
    static let didLoad = Notification.Name("ReflectImageStoreDidLoad")

    let root: URL
    /// Each source's size in points, or nil for one that is not a picture.
    private var sizes: [String: CGSize?] = [:]
    private let images = NSCache<NSString, NSImage>()
    private var fetching: Set<String> = []
    /// Posts, by the source that links them; nil for one that is gone.
    private var tweets: [String: Tweet?] = [:]
    /// The pictures a post's card shows, and the post's source: when one
    /// arrives, the card is drawn again.
    private var dependents: [String: Set<String>] = [:]

    init(root: URL) {
        self.root = root
        images.countLimit = 200
    }

    /// The spans with images that cannot be shown turned back into text.
    func resolve(_ spans: [InlineSpan]) -> [InlineSpan] {
        spans.map { span in
            guard case .image(let reference) = span.kind, naturalSize(reference.source) == nil else { return span }
            var text = span
            text.kind = .imageText
            text.content = span.range
            return text
        }
    }

    /// The size a picture is drawn at, before fitting it to the column:
    /// the size the note gives, or its own.
    func size(of reference: ImageReference) -> CGSize? {
        // A post is the card's size, whatever the note says.
        if Tweet.id(from: reference.source) != nil { return naturalSize(reference.source) }
        guard let natural = naturalSize(reference.source), natural.width > 0, natural.height > 0 else { return nil }
        switch (reference.width, reference.height) {
        case let (width?, height?): return CGSize(width: width, height: height)
        case let (width?, nil): return CGSize(width: width, height: width * natural.height / natural.width)
        case let (nil, height?): return CGSize(width: height * natural.width / natural.height, height: height)
        case (nil, nil): return natural
        }
    }

    /// A picture's own size in points, or nil when it is not one — or not
    /// here yet, in which case it is sent for.
    func naturalSize(_ source: String) -> CGSize? {
        if let id = Tweet.id(from: source) { return tweet(source, id: id).map(TweetCard.size(of:)) }
        if let known = sizes[source] { return known }
        if let file = assetURL(source) {
            let size = Self.pointSize(of: CGImageSourceCreateWithURL(file as CFURL, nil))
            sizes[source] = size
            return size
        }
        guard let url = URL(string: source), url.scheme == "https" || url.scheme == "http" else {
            sizes[source] = .some(nil)
            return nil
        }
        let cached = Self.cacheURL(for: source)
        if FileManager.default.fileExists(atPath: cached.path + ".none") {
            sizes[source] = .some(nil)
            return nil
        }
        if FileManager.default.fileExists(atPath: cached.path) {
            let size = Self.pointSize(of: CGImageSourceCreateWithURL(cached as CFURL, nil))
            sizes[source] = size
            return size
        }
        fetch(source, from: url, to: cached)
        return nil
    }

    /// The post a source links, once it is here; sent for when it is not.
    func tweet(_ source: String) -> Tweet? {
        Tweet.id(from: source).flatMap { tweet(source, id: $0) }
    }

    private func tweet(_ source: String, id: String) -> Tweet? {
        if let known = tweets[source] { return known }
        let cached = Self.cacheDirectory.appendingPathComponent("tweet-\(id).json")
        if FileManager.default.fileExists(atPath: cached.path + ".none") {
            tweets[source] = .some(nil)
            return nil
        }
        if let data = try? Data(contentsOf: cached) {
            let tweet = Tweet(json: data, id: id)
            tweets[source] = tweet
            if let tweet { want(tweet, for: source) }
            return tweet
        }
        guard let endpoint = Tweet.endpoint(for: id), !fetching.contains(source) else { return nil }
        fetching.insert(source)
        Task.detached(priority: .utility) {
            var found = false
            if let (data, response) = try? await URLSession.shared.data(from: endpoint) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (200..<300).contains(status), Tweet(json: data, id: id) != nil {
                    found = (try? data.write(to: cached, options: .atomic)) != nil
                } else if (200..<300).contains(status) || status == 404 {
                    // Deleted, private, or not a post: shown as the link it is.
                    FileManager.default.createFile(atPath: cached.path + ".none", contents: nil)
                    Log.shared.info("images", "No post at \(source)")
                }
            } else {
                Log.shared.warning("images", "Could not reach X for \(source)")
            }
            let arrived = found
            await MainActor.run {
                self.fetching.remove(source)
                self.tweets[source] = nil
                if arrived { NotificationCenter.default.post(name: Self.didLoad, object: source) }
            }
        }
        return nil
    }

    /// Sends for a card's avatar and picture, noting whose they are.
    private func want(_ tweet: Tweet, for source: String) {
        for url in [tweet.user.avatar, tweet.media?.url].compactMap({ $0 }) {
            dependents[url, default: []].insert(source)
            _ = naturalSize(url)
        }
    }

    /// The picture itself, once it is known to be one.
    func image(_ source: String) -> NSImage? {
        if let image = images.object(forKey: source as NSString) { return image }
        guard naturalSize(source) != nil else { return nil }
        let file = assetURL(source) ?? Self.cacheURL(for: source)
        guard let image = NSImage(contentsOf: file) else { return nil }
        images.setObject(image, forKey: source as NSString)
        return image
    }

    /// The file an `assets/…` source names, when it is safely inside the
    /// graph and there. As Reflect does, nothing outside `assets/` is read,
    /// and no `..` can lead out of it.
    private func assetURL(_ source: String) -> URL? {
        let path = source.removingPercentEncoding ?? source
        guard path.hasPrefix("assets/"), !path.contains("\\") else { return nil }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let url = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Size in points from the image's header alone, its pixels scaled by
    /// its resolution — a Retina screenshot is half its pixel size.
    private static func pointSize(of source: CGImageSource?) -> CGSize? {
        guard let source, CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi > 0 ? 72 / dpi : 1
        var size = CGSize(width: width * scale, height: height * scale)
        // Rotated photographs report their stored, not their shown, size.
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    // MARK: The web

    private static let cacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ReflectMac").appendingPathComponent("Images")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func cacheURL(for source: String) -> URL {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest)
    }

    private func fetch(_ source: String, from url: URL, to cached: URL) {
        guard !fetching.contains(source) else { return }
        fetching.insert(source)
        Task.detached(priority: .utility) {
            var isImage = false
            if let (data, response) = try? await URLSession.shared.data(from: url) {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (200..<300).contains(status), let image = CGImageSourceCreateWithData(data as CFData, nil),
                   CGImageSourceGetCount(image) > 0, CGImageSourceGetType(image) != nil {
                    isImage = (try? data.write(to: cached, options: .atomic)) != nil
                } else if (200..<300).contains(status) || status == 404 || status == 410 {
                    // A page, not a picture, or nothing there at all:
                    // remembered, so it is not asked for again. A server
                    // having a bad day, or no network, is asked again next
                    // time.
                    FileManager.default.createFile(atPath: cached.path + ".none", contents: nil)
                }
            }
            let arrived = isImage
            await MainActor.run {
                self.fetching.remove(source)
                self.sizes[source] = nil
                if arrived {
                    NotificationCenter.default.post(name: Self.didLoad, object: source)
                    for card in self.dependents[source] ?? [] {
                        NotificationCenter.default.post(name: Self.didLoad, object: card)
                    }
                }
            }
        }
    }
}

extension NSAttributedString.Key {
    /// On the first character of an image's Markdown: the picture to draw
    /// there, as an `ImageBox`.
    static let outlineImage = NSAttributedString.Key("ReflectOutlineImage")
}

/// A picture in the text, and the size the note asks for.
final class ImageBox: NSObject {
    let source: String
    let size: CGSize

    init(source: String, size: CGSize) {
        self.source = source
        self.size = size
    }

    /// The size it is drawn at in a column so wide: never wider than the
    /// column, never stretched.
    func fitted(to width: CGFloat) -> CGSize {
        guard size.width > width, width > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        return CGSize(width: width.rounded(), height: (size.height * width / size.width).rounded())
    }

    /// Space above and below a picture.
    static let margin: CGFloat = 4
}
