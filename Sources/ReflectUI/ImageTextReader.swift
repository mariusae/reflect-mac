import Foundation
import ImageIO
import ReflectCore
import Vision

/// Reads the text in the graph's pictures, on this Mac, a picture at a
/// time in the background, into the index the chooser searches.
///
/// Asked again while it reads, it goes round once more when it is done, so
/// pictures added meanwhile are read too.
package final class ImageTextReader: @unchecked Sendable {
    package let index: ImageTextIndex
    private let lock = NSLock()
    private var running = false
    private var again = false

    package init(index: ImageTextIndex) {
        self.index = index
    }

    /// Reads whatever pictures are new or changed.
    package func update() {
        lock.lock()
        if running {
            again = true
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        Task.detached(priority: .utility) { [self] in
            repeat {
                let pending = index.refresh()
                if !pending.isEmpty { Log.shared.info("pictures", "Reading the text in \(pending.count) pictures") }
                var read = 0
                for picture in pending {
                    let text = autoreleasepool { Self.text(in: picture.url) }
                    guard let text else { continue }
                    index.store(text, for: picture)
                    if !text.isEmpty { read += 1 }
                }
                if !pending.isEmpty { Log.shared.info("pictures", "Found text in \(read) of \(pending.count) pictures") }
            } while lock.withLock({
                let more = again
                again = false
                if !more { running = false }
                return more
            })
        }
    }

    /// Where in a picture some words are, as fractions of it from its lower
    /// left: each place any of them is seen.
    package static func boxes(of words: [String], in url: URL) -> [CGRect] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        var boxes: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for word in words where !word.isEmpty {
                var from = text.startIndex
                while let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                    if let box = try? candidate.boundingBox(for: range)?.boundingBox { boxes.append(box) }
                    from = range.upperBound
                }
            }
        }
        return boxes
    }

    /// The text Vision finds in a picture, a line to each line it sees —
    /// empty when there is none; nil when the picture cannot be read.
    package static func text(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            Log.shared.info("pictures", "Could not read the text in \(url.lastPathComponent)", detail: error.localizedDescription)
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
