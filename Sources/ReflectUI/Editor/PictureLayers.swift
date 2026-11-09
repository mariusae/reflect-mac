import AppKit
import QuartzCore

/// The pictures in a note, each shown by a layer of its own over the room
/// its line is given — as a PDF is by a view — not drawn in the text. Drawn
/// in it, a picture is drawn again each time the text is: as a page with
/// screenshots on it is scrolled, most of the time each step takes. A
/// layer is put together on the screen, and costs nothing scrolled.
///
/// Only a plain picture: a carousel, a post, a video, a link's card and a
/// block are drawn in the text still, as is a picture until it is here.
extension OutlineTextView {
    /// Whether a picture is shown by its layer, in this place.
    func showsPictureLayer(_ source: String, at frame: NSRect) -> Bool {
        pictureLayers.values.contains { layer in
            layer.name == source && !layer.isHidden && abs(layer.frame.minX - frame.minX) < 0.5 && abs(layer.frame.minY - frame.minY) < 0.5
                && abs(layer.frame.width - frame.width) < 0.5 && abs(layer.frame.height - frame.height) < 0.5
        }
    }

    /// Puts each picture's layer where its room is now, making those that
    /// are new and letting go of those that are gone.
    func placePictures() {
        guard let manager = layoutManager as? OutlineLayoutManager, let images else { return }
        let frames = manager.pictureFrames(origin: textContainerOrigin) { images.isPlainPicture($0) }
        guard !frames.isEmpty || !pictureLayers.isEmpty else { return }
        // A layer of its own to put them in, over the text drawn in it.
        if layer == nil { wantsLayer = true }
        guard layer != nil else { return }
        let scale = window?.backingScaleFactor ?? 2
        let space = window?.colorSpace
        var seen = Set<String>()
        var counts: [String: Int] = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (box, _, frame) in frames {
            let count = counts[box.source, default: 0]
            counts[box.source] = count + 1
            let key = "\(box.source)#\(count)"
            let shown = pictureLayers[key]
            // Made again at a new size only once it has stopped changing —
            // stretched till then, as its grip is dragged.
            let resized = shown.map { $0.frame.size != frame.size && $0.contents != nil } ?? false
            let picture: CGImage?
            if resized {
                picture = nil
                schedulePictureRedo()
            } else {
                // Made in the background, the first time: the room shown
                // quiet meanwhile — a page of pictures opens at once.
                // Ready: placed again with the text's next layout — once,
                // however many arrive meanwhile.
                picture = images.drawableLater(box.source, size: frame.size, scale: scale, colorSpace: space, for: self) { [weak self] in
                    self?.needsLayout = true
                }
                guard picture != nil || images.naturalSize(box.source) != nil else { continue }
            }
            seen.insert(key)
            let layer = shown ?? makePictureLayer(key, source: box.source)
            if let picture, layer.contents as! CGImage? !== picture { layer.contents = picture }
            if layer.frame != frame { layer.frame = frame }
            layer.contentsScale = scale
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer.borderColor = (metrics.typography.ink.rule).cgColor
                // Till the picture is ready, its room quiet.
                layer.backgroundColor = layer.contents == nil ? NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor : nil
            }
            layer.sublayers?.first?.isHidden = !(hoveredPictureFrame == frame && box.isResizable)
            layer.sublayers?.first?.frame = Self.gripLayerFrame(in: frame.size)
        }
        for (key, layer) in pictureLayers where !seen.contains(key) {
            layer.removeFromSuperlayer()
            pictureLayers[key] = nil
        }
    }

    /// The grip of the picture under the pointer shown; the others' not.
    func showPictureGrips() {
        guard !pictureLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in pictureLayers.values {
            let hovered = hoveredPictureFrame == layer.frame && (hoveredPictureBox?.isResizable ?? true)
            layer.sublayers?.first?.isHidden = !hovered
        }
        CATransaction.commit()
    }

    private func makePictureLayer(_ key: String, source: String) -> CALayer {
        let picture = CALayer()
        picture.name = source
        picture.contentsGravity = .resize
        picture.cornerRadius = 4
        picture.masksToBounds = true
        // A hairline round it: a picture as light as the page — a
        // screenshot of one — reads as a picture, not a patch.
        picture.borderWidth = 0.5
        picture.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        let grip = CALayer()
        grip.contents = Self.gripImage
        grip.contentsGravity = .resize
        grip.isHidden = true
        grip.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        picture.addSublayer(grip)
        layer?.addSublayer(picture)
        pictureLayers[key] = picture
        return picture
    }

    /// The pictures stretched to a new size made again at it, once it has
    /// stopped changing.
    private func schedulePictureRedo() {
        guard !picturesToRedo else { return }
        picturesToRedo = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            picturesToRedo = false
            for layer in pictureLayers.values { layer.contents = nil }
            placePictures()
        }
    }

    /// Where the grip goes in a picture so large: its corner.
    private static func gripLayerFrame(in size: CGSize) -> CGRect {
        let grip = OutlineTextView.grip(in: NSRect(origin: .zero, size: size))
        return grip.insetBy(dx: -1, dy: -1)
    }

    /// The grip, drawn once.
    private static let gripImage: NSImage = {
        let side = gripSide + 2
        return NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            // `grip(in:)` puts it in a frame's corner: a frame it fills.
            OutlineLayoutManager.drawPictureGrip(in: NSRect(x: 0, y: 0, width: side + 3, height: side + 3))
            return true
        }
    }()
}
