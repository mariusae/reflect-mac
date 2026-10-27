import UIKit
import ReflectCore

/// A note, or a view, as the bar's field shows what is open — a copy of
/// the field: a capsule, the name centred, its cover or mark small and round
/// just before it. Whatever is to be chosen is shown so: one of these each.
final class NoteChip: UIView {
    static let height: CGFloat = 44
    static let round: CGFloat = 26
    /// In a cover's stead, for a note without one: a note's mark, on a faint round.
    static let standIn = UIImage(systemName: "doc.text", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular))
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
        self.symbol = symbol.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)) }
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
        // As the field sets its name: the round just before it, the two centred together.
        let round = picture.isHidden ? 0 : Self.round + 8
        let room = max(0, bounds.width - 2 * 14 - round)
        let words = min(room, label.width(within: room))
        let x = max(14, (bounds.width - round - words) / 2)
        picture.frame = CGRect(x: x, y: (h - Self.round) / 2, width: Self.round, height: Self.round)
        label.frame = CGRect(x: x + round, y: 0, width: words, height: h)
    }
}

/// Notes to choose among, dealt as chips out of what was held — the nearest
/// the thumb first: what links to the note shown, out of its count held.
/// The thumb slid onto one and let go takes it; let go anywhere else, or
/// tapped beside them, they gather back.
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
        var action: () -> Void
    }

    var onClose: (() -> Void)?
    /// A note's cover, if read yet.
    var cover: ((String) -> UIImage?)?

    private let entries: [Entry]
    private var chips: [NoteChip] = []
    private let backdrop = UIVisualEffectView(effect: nil)
    /// Where they are dealt from: what was held, in this view.
    private let origin: CGRect
    /// The column they lie in: the bar's pill, or — views — the circle held, in this view.
    private let column: CGRect

    private static let step: CGFloat = NoteChip.height + 8
    /// Room left over what was held: a circle swells while pressed.
    private var clearance: CGFloat { 10 }

    /// Dealt down from what was held, under it; else up, over it.
    private let down: Bool

    /// `entries` nearest the thumb first.
    init(entries: [Entry], from origin: CGRect, along column: CGRect, in bounds: CGRect, down: Bool = false) {
        self.down = down
        // As many as fit, over the bar — or under the controls, above the bar.
        let room = max(1, Int((down ? bounds.height - column.maxY - 140 : column.minY - 60) / Self.step))
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
            let chip = NoteChip(names: entry.names, cover: entry.cover, symbol: entry.symbol, secondary: entry.secondary)
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
        for (chip, entry) in zip(chips, entries) where !chip.hasCover {
            if let path = entry.path, let image = cover?(path) { chip.show(cover: image) }
        }
    }

    /// Where a chip lies dealt out: up from just over the column — or down from just under it.
    private func place(_ i: Int) -> CGRect {
        let y = down ? column.maxY + clearance + CGFloat(i) * Self.step : column.minY - clearance - NoteChip.height - CGFloat(i) * Self.step
        return CGRect(x: column.minX, y: y, width: column.width, height: NoteChip.height)
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
        let index = chips.firstIndex { $0.frame.insetBy(dx: -12, dy: -4).contains(point) }
        guard index != pointed else { return }
        if let pointed, chips.indices.contains(pointed) { lift(chips[pointed], false) }
        pointed = index
        if let index {
            lift(chips[index], true)
            tick.selectionChanged()
        }
    }

    private func lift(_ chip: NoteChip, _ up: Bool) { chip.lifted = up }

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

/// What links to the note shown, dealt down out of its count held: the
/// newest nearest the thumb; past six, the last of them all — what links
/// here, at the page's end.
@MainActor
final class LinkedFan {
    private weak var fan: NoteFan?

    func held(_ state: UIGestureRecognizer.State, at point: CGPoint, bar: PaneBar, in host: UIView, store: PrismStore,
              paths: [String], open: @escaping (String) -> Void, showAll: @escaping () -> Void) {
        let local = host.convert(point, from: nil)
        switch state {
        case .began:
            fan = deal(bar: bar, in: host, store: store, paths: paths, open: open, showAll: showAll)
        case .changed:
            fan?.track(local)
        case .ended:
            fan?.release(at: local)
            fan = nil
        default:
            fan?.release(at: nil)
            fan = nil
        }
    }

    private func deal(bar: PaneBar, in host: UIView, store: PrismStore, paths: [String],
                      open: @escaping (String) -> Void, showAll: @escaping () -> Void) -> NoteFan? {
        guard !paths.isEmpty else { return nil }
        let most = 6
        let shown = paths.count > most ? Array(paths.prefix(most - 1)) : paths
        var entries = shown.map { path in
            NoteFan.Entry(names: SliceBlock.names(path, store: store), cover: Self.cover(of: path, store: store), path: path) { open(path) }
        }
        if paths.count > shown.count {
            entries.append(NoteFan.Entry(names: ["All \(paths.count) linking here…"], cover: nil, secondary: true, action: showAll))
        }
        // Under the controls, across the page, as the bar's field is at the foot.
        let under = host.convert(bar.trailingView.bounds, from: bar.trailingView)
        let column = CGRect(x: 20, y: under.minY, width: host.bounds.width - 40, height: under.height)
        let fan = NoteFan(entries: entries, from: host.convert(bar.linkedView.bounds, from: bar.linkedView), along: column,
                          in: host.bounds, down: true)
        fan.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fan.cover = { path in Self.cover(of: path, store: store) }
        host.insertSubview(fan, belowSubview: bar)
        fan.deal()
        return fan
    }

    private static func cover(of path: String, store: PrismStore) -> UIImage? {
        NoteCover.source(in: store.text(path)).flatMap { PhoneImages.thumbnail($0, side: NoteChip.round) }
    }
}
