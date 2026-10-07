import UIKit

/// A menu for a button held: it opens with its last row under the thumb and
/// that row chosen, follows the thumb as it slides, and lifting the thumb
/// takes the row it is on — off the menu, nothing. One press, start to end.
final class HoldMenu: UIView {
    struct Entry {
        var title: String
        var symbol: String
        var action: () -> Void
    }

    private static let rowHeight: CGFloat = 46
    private static let headerHeight: CGFloat = 36
    private static let width: CGFloat = 270
    private static let inset: CGFloat = 6

    private let entries: [Entry]
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let highlight = UIView()
    private var rows: [UIView] = []
    private let tick = UISelectionFeedbackGenerator()
    private(set) var chosen: Int? {
        didSet {
            guard chosen != oldValue else { return }
            placeHighlight()
            if chosen != nil { tick.selectionChanged() }
        }
    }

    /// `entries` top to bottom: the one by the thumb last.
    init(title: String, entries: [Entry]) {
        self.entries = entries
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 24
        layer.shadowOffset = CGSize(width: 0, height: 8)
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)
        highlight.backgroundColor = Ink.text.withAlphaComponent(0.09)
        highlight.layer.cornerRadius = 14
        highlight.layer.cornerCurve = .continuous
        highlight.alpha = 0
        card.contentView.addSubview(highlight)

        let header = UILabel()
        header.text = title
        header.font = .systemFont(ofSize: 13, weight: .medium)
        header.textColor = Ink.secondary
        header.frame = CGRect(x: 20, y: 10, width: Self.width - 40, height: Self.headerHeight - 12)
        card.contentView.addSubview(header)
        for (i, entry) in entries.enumerated() {
            let row = UIView(frame: CGRect(x: Self.inset, y: Self.headerHeight + CGFloat(i) * Self.rowHeight,
                                           width: Self.width - 2 * Self.inset, height: Self.rowHeight))
            let icon = UIImageView(image: UIImage(systemName: entry.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)))
            icon.tintColor = Ink.text
            icon.contentMode = .center
            icon.frame = CGRect(x: 8, y: 0, width: 28, height: Self.rowHeight)
            let label = UILabel()
            label.text = entry.title
            label.font = .systemFont(ofSize: 17)
            label.textColor = Ink.text
            label.lineBreakMode = .byTruncatingTail
            label.frame = CGRect(x: 46, y: 0, width: row.bounds.width - 46 - 10, height: Self.rowHeight)
            row.addSubview(icon)
            row.addSubview(label)
            card.contentView.addSubview(row)
            rows.append(row)
        }
        tick.prepare()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shown over `window`, its last row centred on `point` where it fits.
    func show(in window: UIWindow, at point: CGPoint) {
        let height = Self.headerHeight + CGFloat(entries.count) * Self.rowHeight + Self.inset
        let bounds = window.bounds.inset(by: UIEdgeInsets(top: window.safeAreaInsets.top + 8, left: 12, bottom: 8, right: 12))
        var x = min(point.x + 40, bounds.maxX) - Self.width
        x = max(bounds.minX, x)
        var y = point.y + Self.rowHeight / 2 + Self.inset - height
        y = min(max(bounds.minY, y), bounds.maxY - height)
        frame = CGRect(x: x, y: y, width: Self.width, height: height)
        card.frame = self.bounds
        window.addSubview(self)
        chosen = row(at: point) ?? (entries.isEmpty ? nil : entries.count - 1)
        // Grown from the thumb.
        let anchor = CGPoint(x: (point.x - x) / Self.width, y: min(max((point.y - y) / height, 0), 1))
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: x + anchor.x * Self.width, y: y + anchor.y * height)
        transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        alpha = 0
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0) {
            self.transform = .identity
            self.alpha = 1
        }
    }

    /// The thumb moved to `point`, in the window.
    func track(_ point: CGPoint) {
        chosen = row(at: point)
    }

    /// The thumb lifted at `point`: the row there taken, if any; gone either way.
    func finish(at point: CGPoint?) {
        if let point { chosen = row(at: point) }
        let entry = chosen.map { entries[$0] }
        UIView.animate(withDuration: 0.18, animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
        }, completion: { _ in self.removeFromSuperview() })
        entry?.action()
    }

    private func row(at point: CGPoint) -> Int? {
        let local = convert(point, from: superview)
        // A little give at the sides, so a thumb at the edge still counts.
        guard local.x >= -16, local.x <= bounds.width + 16 else { return nil }
        let i = Int(floor((local.y - Self.headerHeight) / Self.rowHeight))
        return entries.indices.contains(i) ? i : nil
    }

    private func placeHighlight() {
        guard let chosen else {
            UIView.animate(withDuration: 0.12) { self.highlight.alpha = 0 }
            return
        }
        let frame = rows[chosen].frame
        if highlight.alpha == 0 {
            highlight.frame = frame
            UIView.animate(withDuration: 0.12) { self.highlight.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.12) { self.highlight.frame = frame }
        }
    }
}
