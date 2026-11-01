import UIKit
import PrismCore

/// While words are said into a note: the caret a bar of light, glittering,
/// throwing off small stars back over what it writes, and each word as it
/// comes in lit behind, the light fading over a moment and a half — so it
/// is plain what is being written, and where.
@MainActor
final class DictationGlow: UIView {
    private weak var text: UITextView?
    /// What has come in lately, and when — in the text's own characters.
    private var lit: [(range: NSRange, at: CFTimeInterval)] = []
    /// Where the caret stands while listening: before this character.
    private var listening: Int?
    /// When words last came out of the caret.
    private var wroteAt: CFTimeInterval = 0
    /// When listening stopped: the stars left to go out.
    private var endedAt: CFTimeInterval?
    private var link: CADisplayLink?
    private var pool: [CALayer] = []
    /// Over the text: the caret, and what it throws off.
    private let sparks = UIView()
    private let bar: CALayer
    private let emitter: CAEmitterLayer
    private static let fade: CFTimeInterval = 1.6

    init(on text: UITextView) {
        self.text = text
        let accent = Ink.accent.resolvedColor(with: text.traitCollection).cgColor
        bar = Sparkles.bar(accent)
        emitter = Sparkles.emitter(accent)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        sparks.isUserInteractionEnabled = false
        sparks.layer.addSublayer(emitter)
        sparks.layer.addSublayer(bar)
        bar.isHidden = true
        emitter.birthRate = 0
        // The light behind the text; the caret and its stars over it.
        text.insertSubview(self, at: 0)
        text.addSubview(sparks)
        (text as? OutlineEditor)?.hidesCaret = true
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Characters just written, to light.
    func wrote(_ range: NSRange) {
        guard range.length > 0 else { return }
        let now = CACurrentMediaTime()
        lit.append((range, now))
        wroteAt = now
        tick()
    }

    /// Where the words are going in: the caret before `location`; nil, none.
    func listen(at location: Int?) {
        listening = location
        tick()
    }

    /// Done listening: the caret as it was, its stars and the light let
    /// go out — or, what was written taken back, put out — then this gone.
    func end(keepingLight: Bool = true) {
        listening = nil
        endedAt = CACurrentMediaTime()
        (text as? OutlineEditor)?.hidesCaret = false
        if !keepingLight {
            lit = []
            emitter.removeFromSuperlayer()
        }
        tick()
    }

    @objc private func tick() {
        guard let text, let layout = text.textContainer.layoutManager else { return finish() }
        let now = CACurrentMediaTime()
        lit.removeAll { now - $0.at > Self.fade }
        let starsOut = endedAt.map { now - $0 > 1.4 || emitter.superlayer == nil } ?? false
        guard listening != nil || !lit.isEmpty || !starsOut else { return finish() }
        frame = CGRect(origin: .zero, size: CGSize(width: max(text.contentSize.width, text.bounds.width),
                                                   height: max(text.contentSize.height, text.bounds.height)))
        sparks.frame = frame
        emitter.frame = sparks.bounds
        let length = text.textStorage.length
        let inset = text.textContainerInset
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var used = 0
        for (range, at) in lit where NSMaxRange(range) <= length {
            let left = 1 - (now - at) / Self.fade
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: text.textContainer) { rect, _ in
                let layer = self.layer(used)
                used += 1
                layer.frame = rect.offsetBy(dx: inset.left, dy: inset.top).insetBy(dx: -1.5, dy: 0)
                layer.opacity = Float(left * left)
            }
        }
        for layer in pool.dropFirst(used) { layer.isHidden = true }

        if let listening, listening <= length, let place = text.position(from: text.beginningOfDocument, offset: listening) {
            let caret = text.caretRect(for: place)
            Sparkles.glint(bar, at: caret, now: now)
            Sparkles.place(emitter, at: caret, busy: now - wroteAt < 0.4)
            bar.isHidden = false
        } else {
            bar.isHidden = true
            emitter.birthRate = 0
        }
        CATransaction.commit()
    }

    private func layer(_ index: Int) -> CALayer {
        if index < pool.count {
            pool[index].isHidden = false
            return pool[index]
        }
        let layer = CALayer()
        layer.backgroundColor = Ink.accent.withAlphaComponent(0.22).cgColor
        layer.cornerRadius = 4
        layer.shadowColor = Ink.accent.cgColor
        layer.shadowRadius = 6
        layer.shadowOpacity = 0.5
        layer.shadowOffset = .zero
        self.layer.addSublayer(layer)
        pool.append(layer)
        return layer
    }

    private func finish() {
        link?.invalidate()
        link = nil
        if endedAt == nil { (text as? OutlineEditor)?.hidesCaret = false }
        sparks.removeFromSuperview()
        removeFromSuperview()
    }
}
