import AppKit
import ReflectCore

/// Pictures written side by side on a line — `![](a.png)![](b.png)`, with
/// nothing but space between them — shown as one: a picture at a time, the
/// one before and after a click away. In Reflect, which has no carousels,
/// they are the pictures one after another they are written as.
///
/// A picture dropped onto another is written straight after it, and so
/// joins it; dragged from a carousel, the picture it shows leaves it. Which
/// picture a carousel shows is kept, as how this Mac shows the notes.
enum Carousel {
    struct Group {
        var sources: [String]
        var size: CGSize
    }

    /// The carousels among a row's spans: for the first picture of each,
    /// the carousel; for the others in it, nil — they are drawn in it.
    static func groups(in spans: [InlineSpan], text: NSString, images: ImageStore) -> [Int: Group?] {
        var result: [Int: Group?] = [:]
        var run: [(span: InlineSpan, source: String)] = []
        func finish() {
            defer { run.removeAll() }
            guard run.count >= 2 else { return }
            let sizes = run.compactMap { images.naturalSize($0.source) }
            let size = CGSize(width: sizes.map(\.width).max() ?? 400, height: sizes.map(\.height).max() ?? 300)
            result[run[0].span.range.location] = Group(sources: run.map(\.source), size: size)
            for member in run.dropFirst() { result.updateValue(nil, forKey: member.span.range.location) }
        }
        for span in spans {
            guard case .image(let reference) = span.kind, isPicture(reference.source, images: images) else {
                // Anything shown between two pictures parts them.
                if !(span.kind == .comment) { finish() }
                continue
            }
            if let last = run.last {
                let gap = NSRange(location: NSMaxRange(last.span.range), length: span.range.location - NSMaxRange(last.span.range))
                if gap.length < 0 || !text.substring(with: gap).trimmingCharacters(in: .whitespaces).isEmpty { finish() }
            }
            run.append((span, reference.source))
        }
        finish()
        return result
    }

    /// A picture that can be in a carousel: not a post's or a video's card.
    static func isPicture(_ source: String, images: ImageStore) -> Bool {
        Tweet.id(from: source) == nil && Video.id(from: source) == nil && images.naturalSize(source) != nil
    }

    // MARK: Drawing

    static let buttonSide: CGFloat = 28

    /// Where a carousel's controls are, in its frame.
    static func previousButton(in frame: NSRect) -> NSRect {
        NSRect(x: frame.minX + 10, y: frame.midY - buttonSide / 2, width: buttonSide, height: buttonSide)
    }

    static func nextButton(in frame: NSRect) -> NSRect {
        NSRect(x: frame.maxX - 10 - buttonSide, y: frame.midY - buttonSide / 2, width: buttonSide, height: buttonSide)
    }

    static func dot(_ index: Int, of count: Int, in frame: NSRect) -> NSRect {
        let spacing: CGFloat = 14
        let start = frame.midX - spacing * CGFloat(count - 1) / 2
        return NSRect(x: start + spacing * CGFloat(index) - 5, y: frame.maxY - 22, width: 10, height: 10)
    }

    /// Draws the picture a carousel is at, fitted and centred, over a quiet
    /// ground; its buttons, its dots, and how many there are.
    static func draw(_ box: ImageBox, index: Int, in rect: NSRect, images: ImageStore) {
        guard let sources = box.carousel, !sources.isEmpty else { return }
        let index = min(max(index, 0), sources.count - 1)
        NSGraphicsContext.saveGraphicsState()
        let shape = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        shape.addClip()
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        if let image = images.image(sources[index]), image.size.width > 0, image.size.height > 0 {
            let scale = min(rect.width / image.size.width, rect.height / image.size.height, 1)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawn = NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        NSGraphicsContext.restoreGraphicsState()

        func button(_ frame: NSRect, _ symbol: String, enabled: Bool) {
            guard enabled else { return }
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: frame).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold).applying(.init(paletteColors: [.white]))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = image.size
                image.draw(in: NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        button(previousButton(in: rect), "chevron.left", enabled: index > 0)
        button(nextButton(in: rect), "chevron.right", enabled: index < sources.count - 1)

        for dotIndex in sources.indices {
            let frame = dot(dotIndex, of: sources.count, in: rect).insetBy(dx: 1.5, dy: 1.5)
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: frame.insetBy(dx: -1, dy: -1)).fill()
            (dotIndex == index ? NSColor.white : NSColor.white.withAlphaComponent(0.5)).setFill()
            NSBezierPath(ovalIn: frame).fill()
        }

        let count = NSAttributedString(string: "\(index + 1)/\(sources.count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ])
        let size = count.size()
        let badge = NSRect(x: rect.maxX - size.width - 18, y: rect.minY + 8, width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2).fill()
        count.draw(at: NSPoint(x: badge.minX + 5, y: badge.minY + 2))
    }
}

extension OutlineTextView {
    /// The picture a carousel shows.
    func carouselIndex(_ box: ImageBox) -> Int {
        guard let sources = box.carousel, let root = images?.root else { return 0 }
        return min(max(SessionState.shared.carouselIndex(root, sources[0]), 0), sources.count - 1)
    }

    /// A click on a carousel's controls: to the picture before or after, or
    /// the one a dot stands for. Says whether it was on one.
    func clickCarousel(_ box: ImageBox, frame: NSRect, at point: NSPoint) -> Bool {
        guard let sources = box.carousel, let root = images?.root else { return false }
        let current = carouselIndex(box)
        var next: Int?
        if Carousel.previousButton(in: frame).insetBy(dx: -6, dy: -6).contains(point) {
            next = current - 1
        } else if Carousel.nextButton(in: frame).insetBy(dx: -6, dy: -6).contains(point) {
            next = current + 1
        } else if let dot = sources.indices.first(where: { Carousel.dot($0, of: sources.count, in: frame).insetBy(dx: -3, dy: -4).contains(point) }) {
            next = dot
        }
        guard let next else { return false }
        SessionState.shared.setCarouselIndex(root, sources[0], min(max(next, 0), sources.count - 1))
        setNeedsDisplay(frame.insetBy(dx: -2, dy: -2))
        return true
    }
}
