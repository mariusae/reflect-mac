import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A captured page's cover: the picture the page gives itself for previews
/// — its `og:image`, what its card shows — kept in the graph's `assets/`;
/// or, when it has none worth showing, the screenshot taken of it.
public enum CaptureCover {
    /// The cover a page's note gets, as a source in the graph: its own
    /// picture, fetched and kept, when it is a good one; else the
    /// screenshot; else none.
    public static func choose(image address: String?, title: String, screenshot: String?, in root: URL) async -> String? {
        if let address, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()),
           !looksGeneric(address), let data = await fetch(url), let ext = fileExtension(data), isGood(data) {
            let name = "cover-" + Assets.slug(title).prefix(40) + "." + ext
            if let added = try? Assets.add(data, named: name, to: root) { return added }
        }
        return screenshot
    }

    /// A picture worth a banner: big enough — not an icon, nor a tracking
    /// pixel — and not too tall or too thin.
    public static func isGood(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              height > 0 else { return false }
        let aspect = width / height
        return width >= 400 && height >= 200 && aspect >= 0.6 && aspect <= 3.2
    }

    /// A site's stock picture, not the page's: its logo, a placeholder.
    public static func looksGeneric(_ address: String) -> Bool {
        let path = (URL(string: address)?.path ?? address).lowercased()
        let name = (path as NSString).lastPathComponent
        return ["logo", "favicon", "placeholder", "default", "fallback", "sprite", "avatar", "blank"].contains { name.contains($0) }
            || path.contains("/logos/")
    }

    /// The extension a picture is kept under, by what it is: nil for what
    /// is not a picture a note shows.
    static func fileExtension(_ data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source) as String? else { return nil }
        return Assets.imageExtensions[type]
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 200),
              data.count < 15 * 1024 * 1024 else { return nil }
        return data
    }
}
