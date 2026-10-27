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
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    /// A picture when it is in, from any thread; when not, asked for on the
    /// main thread, and `.prismImageLoaded` says when it is.
    nonisolated static func lookup(_ source: String) -> UIImage? {
        if let image = cache.object(forKey: source as NSString) { return image }
        if Thread.isMainThread {
            return MainActor.assumeIsolated { image(source) }
        }
        DispatchQueue.main.async { _ = image(source) }
        return nil
    }
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

    nonisolated(unsafe) private static let thumbnails = NSCache<NSString, UIImage>()

    /// A picture cut square about its middle, a side in points across — a
    /// cover's, in a list — when it is in; else nil, and it is read, and
    /// `.prismImageLoaded` says when.
    static func thumbnail(_ source: String, side: CGFloat) -> UIImage? {
        let key = "\(source)@\(side)" as NSString
        if let thumbnail = thumbnails.object(forKey: key) { return thumbnail }
        guard let image = image(source), image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let square = CGSize(width: side, height: side)
        let thumbnail = UIGraphicsImageRenderer(size: square).image { _ in
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: square), cornerRadius: side * 0.2).addClip()
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        thumbnails.setObject(thumbnail, forKey: key)
        return thumbnail
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

/// A picture in a row: drawn in the room its first character is given. Or
/// a carousel — pictures written side by side, `![](a.png)![](b.png)` with
/// nothing but space between, shown one at a time — as on the Mac.
final class PhoneImageBox: NSObject {
    let image: UIImage
    /// The width the note asks for, in points, when it says.
    let width: CGFloat?
    /// A carousel's pictures, and where each is from; one alone, just it.
    let images: [UIImage]
    let sources: [String]

    var isCarousel: Bool { images.count > 1 }

    init(image: UIImage, width: CGFloat?) {
        self.image = image
        self.width = width
        images = [image]
        sources = []
    }

    init(carousel images: [UIImage], sources: [String], width: CGFloat?) {
        image = images[0]
        self.images = images
        self.sources = sources
        self.width = width
    }

    static let maxHeight: CGFloat = 420
    static let margin: CGFloat = 6
    /// Under a carousel's pictures: a dot for each.
    static let dotsRoom: CGFloat = 20

    /// Its size where there is so much room across: a carousel as wide as
    /// there is room, and as tall as the tallest of its pictures there, its
    /// dots under them.
    func size(fitting available: CGFloat) -> CGSize {
        if isCarousel {
            let width = min(width ?? available, max(available, 40))
            let height = images.map { Self.fitted($0.size, width: width).height }.max() ?? 0
            return CGSize(width: floor(width), height: floor(height) + Self.dotsRoom)
        }
        return Self.fitted(image.size, width: min(width ?? image.size.width, max(available, 40)))
    }

    private static func fitted(_ natural: CGSize, width: CGFloat) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        var width = width
        var height = width * natural.height / natural.width
        if height > maxHeight {
            height = maxHeight
            width = height * natural.width / natural.height
        }
        return CGSize(width: floor(width), height: floor(height))
    }
}

/// Which picture each carousel shows, by its first picture's source: kept
/// as how this phone shows the notes, as the Mac keeps its own.
enum PhoneCarousel {
    private static let key = "Carousels"
    private static var shown = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]

    static func index(_ box: PhoneImageBox) -> Int {
        guard let first = box.sources.first else { return 0 }
        return min(max(shown[first] ?? 0, 0), box.images.count - 1)
    }

    static func set(_ index: Int, for box: PhoneImageBox) {
        guard let first = box.sources.first else { return }
        shown[first] = min(max(index, 0), box.images.count - 1)
        UserDefaults.standard.set(shown, forKey: key)
    }
}
