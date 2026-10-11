import UIKit

/// A label given a name in several lengths, longest first: it says the
/// first that fits, or — none fitting — the shortest, cut.
final class ShortLabel: UILabel {
    var names: [String] = [] {
        didSet {
            guard names != oldValue else { return }
            fit()
        }
    }

    override func layoutSubviews() {
        fit()
        super.layoutSubviews()
    }

    private func fit() {
        let width = bounds.width
        let chosen = names.first { measure($0) <= width } ?? names.last
        if text != chosen { text = chosen }
    }

    private func measure(_ name: String) -> CGFloat { ceil((name as NSString).size(withAttributes: [.font: font as Any]).width) }

    /// How wide what it would say is, given so much room: the first name
    /// that fits; none fitting, all of it.
    func width(within room: CGFloat) -> CGFloat {
        names.lazy.map(measure).first { $0 <= room } ?? room
    }
}

/// A note, as the bar shows the one being read: a glass capsule, its cover
/// small and round at the start, its name centred — the way a note is shown
/// wherever one is to be chosen.
final class NoteChip: UIView {
    static let height: CGFloat = 48
    static let round: CGFloat = 38
    /// In a cover's stead, for a note without one: a note's mark, on a faint round.
    static let standIn = UIImage(systemName: "doc.text", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    static let standInGround = Ink.text.withAlphaComponent(0.06)

    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let picture = UIImageView()
    private let secondary: Bool
    /// A view's mark, standing in for a cover.
    private let symbol: UIImage?
    private(set) var hasCover = false
    private let label = ShortLabel()

    init(names: [String], cover: UIImage?, symbol: String? = nil, secondary: Bool = false) {
        self.secondary = secondary
        self.symbol = symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)) }
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        show(cover: cover)
        picture.clipsToBounds = true
        picture.tintColor = Ink.secondary
        picture.layer.cornerRadius = Self.round / 2
        glass.contentView.addSubview(picture)
        label.names = names
        label.font = secondary ? Typeface.current.body(15, weight: .medium) : Typeface.current.heading(16, weight: .semibold)
        label.textColor = secondary ? Ink.secondary : Ink.text
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        glass.contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = names.first
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Its cover, once read.
    func show(cover: UIImage?) {
        hasCover = cover != nil
        picture.image = cover ?? symbol ?? Self.standIn
        picture.contentMode = cover == nil ? .center : .scaleAspectFill
        picture.backgroundColor = cover == nil ? Self.standInGround : .clear
        // Not a note — "All 9 linking here…" — none at all.
        picture.isHidden = secondary
        setNeedsLayout()
    }

    /// Lifted, as the thumb comes onto it.
    var lifted = false {
        didSet {
            guard lifted != oldValue else { return }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.lifted ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
                self.glass.effect = {
                    let effect = UIGlassEffect()
                    if self.lifted { effect.tintColor = Ink.text.withAlphaComponent(0.08) }
                    return effect
                }()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let h = bounds.height
        picture.frame = CGRect(x: 5, y: (h - Self.round) / 2, width: Self.round, height: Self.round)
        // Centred — or, too long for that, as near it as it can be — clear of the round.
        let lead: CGFloat = picture.isHidden ? 18 : picture.frame.maxX + 10, trail: CGFloat = 18
        let room = max(0, bounds.width - lead - trail)
        let words = min(room, label.width(within: room))
        let x = min(max((bounds.width - words) / 2, lead), bounds.width - trail - words)
        label.frame = CGRect(x: x, y: 0, width: words, height: h)
    }
}

/// A view, as the home button is: its mark in a glass circle, its name
/// beside it — not a note, so not as one is shown.
final class RoundChip: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let mark = UIImageView()
    private let label = UILabel()

    init(name: String, symbol: String?) {
        super.init(frame: .zero)
        glass.isUserInteractionEnabled = false
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        mark.image = symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)) }
        mark.tintColor = Ink.text
        mark.contentMode = .center
        glass.contentView.addSubview(mark)
        label.text = name
        label.font = Typeface.current.heading(16, weight: .semibold)
        label.textColor = Ink.text
        // Read over whatever is behind: a halo of the page about the words.
        label.layer.shadowColor = Ink.page.cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 5
        label.layer.shadowOffset = .zero
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = name
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The circle and its name: where the thumb takes it, in its own space.
    var reach: CGRect { bounds.union(label.frame) }

    var lifted = false {
        didSet {
            guard lifted != oldValue else { return }
            UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.transform = self.lifted ? CGAffineTransform(scaleX: 1.08, y: 1.08) : .identity
                self.glass.effect = {
                    let effect = UIGlassEffect()
                    if self.lifted { effect.tintColor = Ink.text.withAlphaComponent(0.08) }
                    return effect
                }()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        mark.frame = glass.bounds
        let width = ceil(label.sizeThatFits(CGSize(width: 240, height: bounds.height)).width)
        label.frame = CGRect(x: bounds.maxX + 12, y: 0, width: width, height: bounds.height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { reach.contains(point) }
}

/// Notes to choose among, dealt up out of the bar as chips — the nearest
/// the thumb first — the moment something is held: the sheets behind, the
/// notes written in last, what links here. The thumb slid onto one and let
/// go takes it; let go anywhere else, they gather back.
final class NoteFan: UIView, UIGestureRecognizerDelegate {
    struct Entry {
        /// What it is called, longest first.
        var names: [String]
        var cover: UIImage?
        /// Its note, for its cover once read.
        var path: String? = nil
        /// Not a note but a view: its mark, in a cover's stead.
        var symbol: String? = nil
        /// Not a note: "All 9 linking here…".
        var secondary = false
        /// A view, not a note: a circle, as the home button is.
        var round = false
        var action: () -> Void
    }

    var onClose: (() -> Void)?
    /// A note's cover, if read yet.
    var cover: ((String) -> UIImage?)?

    private let entries: [Entry]
    private var chips: [UIView] = []
    private let backdrop = UIVisualEffectView(effect: nil)
    /// Where they are dealt from: what was held, in this view.
    private let origin: CGRect
    /// The column they lie in: the bar's pill, or — views — the circle held, in this view.
    private let column: CGRect

    private static let step: CGFloat = NoteChip.height + 8
    /// Room left over what was held: a circle swells while pressed.
    private var clearance: CGFloat { entries.first?.round == true ? 22 : 8 }

    /// `entries` nearest the thumb first.
    init(entries: [Entry], from origin: CGRect, along column: CGRect, in bounds: CGRect) {
        // As many as fit over the bar.
        let room = max(1, Int((column.minY - 60) / Self.step))
        self.entries = Array(entries.prefix(room))
        self.origin = origin
        self.column = column
        super.init(frame: bounds)
        // What is behind, blurred away as they are dealt.
        backdrop.frame = self.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(backdrop)
        let outside = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
        outside.delegate = self
        addGestureRecognizer(outside)
        for (i, entry) in self.entries.enumerated() {
            let chip: UIView = entry.round
                ? RoundChip(name: entry.names.first ?? "", symbol: entry.symbol)
                : NoteChip(names: entry.names, cover: entry.cover, symbol: entry.symbol, secondary: entry.secondary)
            chip.tag = i
            chip.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedChip(_:))))
            addSubview(chip)
            chips.append(chip)
        }
        // Covers not read yet: put in as each is.
        NotificationCenter.default.addObserver(forName: .prismImageLoaded, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showCovers() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func showCovers() {
        for case let (chip as NoteChip, entry) in zip(chips, entries) where !chip.hasCover {
            if let path = entry.path, let image = cover?(path) { chip.show(cover: image) }
        }
    }

    /// Where a chip lies dealt out: over the pill, up from just over the bar.
    private func place(_ i: Int) -> CGRect {
        CGRect(x: column.minX, y: column.minY - clearance - NoteChip.height - CGFloat(i) * Self.step,
               width: column.width, height: NoteChip.height)
    }

    // MARK: Dealing out, and gathering in

    /// Each from what was held to its place, the nearest first.
    func deal() {
        for (i, chip) in chips.enumerated() {
            chip.frame = place(i)
            chip.layoutIfNeeded()
            chip.transform = gathered(i)
            chip.alpha = 0
            UIView.animate(withDuration: 0.42, delay: Double(i) * 0.03, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                           options: [.allowUserInteraction]) {
                chip.transform = .identity
                chip.alpha = 1
            }
        }
        UIView.animate(withDuration: 0.25) { self.backdrop.effect = UIBlurEffect(style: .systemUltraThinMaterial) }
    }

    /// All back into what was held, then gone.
    func gather(then done: (() -> Void)? = nil) {
        isUserInteractionEnabled = false
        for (i, chip) in chips.enumerated().reversed() {
            UIView.animate(withDuration: 0.22, delay: Double(chips.count - 1 - i) * 0.02, options: [.curveEaseIn]) {
                chip.transform = self.gathered(i)
                chip.alpha = 0
            }
        }
        UIView.animate(withDuration: 0.25, delay: 0.05, options: []) {
            self.backdrop.effect = nil
        } completion: { _ in
            self.removeFromSuperview()
            done?()
        }
    }

    /// A chip shrunk into what was held.
    private func gathered(_ i: Int) -> CGAffineTransform {
        let rect = place(i)
        let scale = max(origin.width, 1) / max(rect.width, 1)
        return CGAffineTransform(translationX: origin.midX - rect.midX, y: origin.midY - rect.midY).scaledBy(x: scale, y: scale)
    }

    // MARK: Held, one touch

    private var pointed: Int?
    private let tick = UISelectionFeedbackGenerator()

    /// The thumb moved to a point, in this view: the chip under it lifted.
    func track(_ point: CGPoint) {
        let index = chips.firstIndex { chip in
            let reach = (chip as? RoundChip).map { chip.convert($0.reach, to: self) } ?? chip.frame
            return reach.insetBy(dx: -12, dy: -4).contains(point)
        }
        guard index != pointed else { return }
        if let pointed, chips.indices.contains(pointed) { lift(chips[pointed], false) }
        pointed = index
        if let index {
            lift(chips[index], true)
            tick.selectionChanged()
        }
    }

    private func lift(_ chip: UIView, _ up: Bool) {
        (chip as? NoteChip)?.lifted = up
        (chip as? RoundChip)?.lifted = up
    }

    /// The thumb let go at a point: the chip there taken; elsewhere, all gathered.
    func release(at point: CGPoint?) {
        if let point { track(point) }
        guard let index = pointed else { return gather { [onClose] in onClose?() } }
        take(index)
    }

    private func take(_ index: Int) {
        let action = entries[index].action
        gather { action() }
    }

    // MARK: Touches

    @objc private func tappedChip(_ gesture: UITapGestureRecognizer) {
        guard let index = gesture.view?.tag, entries.indices.contains(index) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        take(index)
    }

    /// Only a tap beside the chips closes them: one on a chip is its own.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === self || touch.view?.isDescendant(of: backdrop) == true
    }

    @objc private func tappedOutside(_ gesture: UITapGestureRecognizer) {
        gather { [onClose] in onClose?() }
    }
}
