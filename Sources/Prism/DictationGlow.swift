import AppKit
import PrismCore
import QuartzCore
import ReflectUI

/// While words are said into a note: the caret a bar of light, glittering,
/// throwing off small stars back over what it writes, and each word as it
/// comes in lit, the light fading over a moment and a half — so it is
/// plain what is being written, and where.
@MainActor
final class DictationGlow: NSView {
    private weak var text: NSTextView?
    /// What has come in lately, and when — in the text's own characters.
    private var lit: [(range: NSRange, at: CFTimeInterval)] = []
    /// Where the caret stands while listening: before this character.
    private var listening: Int?
    /// When words last came out of the caret.
    private var wroteAt: CFTimeInterval = 0
    /// When listening stopped: the stars left to go out.
    private var endedAt: CFTimeInterval?
    private var timer: Timer?
    private var pool: [CALayer] = []
    private var accent = NSColor.clear
    private let bar: CALayer
    private let emitter: CAEmitterLayer
    private static let fade: CFTimeInterval = 1.6

    init(on text: NSTextView) {
        self.text = text
        var accent = Ink.accent
        text.effectiveAppearance.performAsCurrentDrawingAppearance { accent = Ink.accent.usingColorSpace(.sRGB) ?? Ink.accent }
        self.accent = accent
        bar = Sparkles.bar(accent.cgColor)
        emitter = Sparkles.emitter(accent.cgColor)
        super.init(frame: text.bounds)
        wantsLayer = true
        bar.isHidden = true
        emitter.birthRate = 0
        layer?.addSublayer(emitter)
        layer?.addSublayer(bar)
        text.addSubview(self)
        (text as? OutlineTextView)?.hidesCaret = true
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
        (text as? OutlineTextView)?.hidesCaret = false
        if !keepingLight {
            lit = []
            emitter.removeFromSuperlayer()
        }
        tick()
    }

    private func tick() {
        guard let text, let layout = text.layoutManager, let container = text.textContainer else { return finish() }
        let now = CACurrentMediaTime()
        lit.removeAll { now - $0.at > Self.fade }
        let starsOut = endedAt.map { now - $0 > 1.4 || emitter.superlayer == nil } ?? false
        guard listening != nil || !lit.isEmpty || !starsOut else { return finish() }
        frame = text.bounds
        let length = text.textStorage?.length ?? 0
        let origin = text.textContainerOrigin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.frame = bounds
        var used = 0
        for (range, at) in lit where NSMaxRange(range) <= length {
            let left = 1 - (now - at) / Self.fade
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let layer = self.layer(used)
                used += 1
                layer.frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1.5, dy: 0)
                layer.opacity = Float(left * left)
            }
        }
        for layer in pool.dropFirst(used) { layer.isHidden = true }

        if let listening, let caret = caretRect(listening, in: text) {
            Sparkles.glint(bar, at: caret, now: now)
            Sparkles.place(emitter, at: caret, busy: now - wroteAt < 0.4)
            bar.isHidden = false
        } else {
            bar.isHidden = true
            emitter.birthRate = 0
        }
        CATransaction.commit()
    }

    /// Where the caret before `location` stands: as the note's own would.
    private func caretRect(_ location: Int, in text: NSTextView) -> CGRect? {
        if let outline = text as? OutlineTextView, let caret = outline.caretBar(at: location) {
            return caret.bar
        }
        guard let window = text.window, location <= (text.textStorage?.length ?? 0) else { return nil }
        let screen = text.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        return text.convert(window.convertFromScreen(screen), from: nil)
    }

    private func layer(_ index: Int) -> CALayer {
        if index < pool.count {
            pool[index].isHidden = false
            return pool[index]
        }
        let layer = CALayer()
        layer.cornerRadius = 4
        layer.shadowRadius = 6
        layer.shadowOpacity = 0.5
        layer.shadowOffset = .zero
        layer.backgroundColor = accent.withAlphaComponent(0.18).cgColor
        layer.shadowColor = accent.cgColor
        self.layer?.insertSublayer(layer, at: 0)
        pool.append(layer)
        return layer
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if endedAt == nil { (text as? OutlineTextView)?.hidesCaret = false }
        removeFromSuperview()
    }
}
