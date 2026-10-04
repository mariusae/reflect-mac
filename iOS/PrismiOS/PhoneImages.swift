import UIKit
import ImageIO

extension Notification.Name {
    /// A picture is in, to be shown by the editors whose notes show it.
    static let prismImageLoaded = Notification.Name("PrismImageLoaded")
}

/// The pictures notes show: files in the graph — `assets/…` — read off the
/// main thread, made no bigger than a phone shows them, and kept.
@MainActor
enum PhoneImages {
    /// The graph the pictures' paths are under.
    static var root: URL?
    private static let cache = NSCache<NSString, UIImage>()
    private static var loading: Set<String> = []
    private static var missing: Set<String> = []
    /// The longest side a picture is read at, in pixels.
    private static let largest = 1600

    /// A picture by the path a note gives it, when it is in; else nil, and
    /// it is read, and `.prismImageLoaded` says when.
    static func image(_ source: String) -> UIImage? {
        if let image = cache.object(forKey: source as NSString) { return image }
        guard let url = url(for: source), !missing.contains(source), loading.insert(source).inserted else { return nil }
        let largest = largest
        Task.detached(priority: .userInitiated) {
            let image = Self.read(url, largest: largest)
            await MainActor.run {
                loading.remove(source)
                guard let image else {
                    missing.insert(source)
                    return
                }
                cache.setObject(image, forKey: source as NSString)
                NotificationCenter.default.post(name: .prismImageLoaded, object: source)
            }
        }
        return nil
    }

    /// Where a picture is: a file in the graph, not a page on the web.
    static func url(for source: String) -> URL? {
        guard let root, !source.contains("://"), !source.isEmpty else { return nil }
        let path = source.removingPercentEncoding ?? source
        let url = root.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) ? url : nil
    }

    private nonisolated static func read(_ url: URL, largest: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: largest,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: 2, orientation: .up)
    }
}

/// A picture in a row: drawn in the room its first character is given.
final class PhoneImageBox: NSObject {
    let image: UIImage
    /// The width the note asks for, in points, when it says.
    let width: CGFloat?

    init(image: UIImage, width: CGFloat?) {
        self.image = image
        self.width = width
    }

    static let maxHeight: CGFloat = 420
    static let margin: CGFloat = 6

    /// Its size where there is so much room across.
    func size(fitting available: CGFloat) -> CGSize {
        let natural = image.size
        guard natural.width > 0, natural.height > 0 else { return .zero }
        var width = min(width ?? natural.width, max(available, 40))
        var height = width * natural.height / natural.width
        if height > Self.maxHeight {
            height = Self.maxHeight
            width = height * natural.width / natural.height
        }
        return CGSize(width: floor(width), height: floor(height))
    }
}
