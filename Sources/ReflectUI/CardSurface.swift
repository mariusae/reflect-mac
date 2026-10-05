import AppKit

/// The sheet of paper a note's card is: its fill a shade lighter than the
/// page it lies on, its corners round, a soft shadow under it.
package final class CardSurface: NSView {
    package var fill: NSColor = .textBackgroundColor { didSet { needsDisplay = true } }
    package static let radius: CGFloat = 12
    /// Room above and below a card, in its block: half the space between two.
    package static let spacing: CGFloat = 7
    /// How far a card reaches past the text column on either side.
    package static let outset: CGFloat = 14

    package override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        shadow = NSShadow()
        layer?.shadowOpacity = 1
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override var wantsUpdateLayer: Bool { true }
    package override var isFlipped: Bool { true }
    package override func hitTest(_ point: NSPoint) -> NSView? { nil }

    package override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.35 : 0.07).cgColor
            layer?.borderWidth = dark ? 1 : 0
            layer?.borderColor = NSColor.white.withAlphaComponent(0.06).cgColor
        }
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    package override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    /// A block's card, about the text column in it.
    package static func frame(column: NSRect, in bounds: NSRect) -> NSRect {
        NSRect(x: column.minX - outset, y: spacing, width: column.width + 2 * outset, height: max(0, bounds.height - 2 * spacing))
    }

    /// `now`, `5m`, `22h`, `3d`, then the date.
    package static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<(7 * 86_400): return "\(Int(seconds / 86_400))d"
        default:
            let formatter = DateFormatter()
            let sameYear = Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "MMMdyyyy")
            return formatter.string(from: date)
        }
    }

    /// A day by how far it is from today: `3d`, `in 5d`, `2w`, `5mo`, `2y`.
    package static func distance(days: Int) -> String {
        let n = abs(days)
        let amount = n < 14 ? "\(n)d" : n < 60 ? "\(n / 7)w" : n < 365 ? "\(n / 30)mo" : "\(n / 365)y"
        return days < 0 ? amount : "in " + amount
    }
}
