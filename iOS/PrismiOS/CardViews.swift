import UIKit
import ReflectCore
import PrismCore

/// The sheet of paper a note's card is: lighter than the page it lies on,
/// its corners round, a soft shadow under it.
final class CardBackground: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Ink.card
        layer.cornerRadius = Card.radius
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.06
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 1)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Card.radius).cgPath
    }
}

/// A card's short form: its first picture, the line that says what the
/// note is, and a little of what follows, in grey.
final class CardSummaryView: UIView {
    private let picture = UIImageView()
    private let headline = UILabel()
    private let snippet = UILabel()
    private var source: String?
    nonisolated(unsafe) private var observer: NSObjectProtocol?
    private var measured: (width: CGFloat, height: CGFloat)?
    /// Told when its picture came in, and it is taller.
    var onResize: (() -> Void)?

    init(metrics: PhoneMetrics) {
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 10
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = Ink.shelf
        headline.numberOfLines = 3
        headline.font = metrics.face.body(round(metrics.size * 1.12), weight: .regular)
        headline.textColor = Ink.text
        snippet.numberOfLines = 2
        snippet.font = metrics.face.body(round(metrics.size * 0.94), weight: .regular)
        snippet.textColor = Ink.secondary
        addSubview(picture)
        addSubview(headline)
        addSubview(snippet)
        observer = NotificationCenter.default.addObserver(forName: .prismImageLoaded, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let source = note.object as? String, source == self.source else { return }
                self.picture.image = PhoneImages.lookup(source)
                self.measured = nil
                self.onResize?()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show(_ summary: NoteSummary) {
        source = summary.picture
        picture.image = summary.picture.flatMap { PhoneImages.lookup($0) }
        headline.text = summary.headline
        snippet.text = summary.snippet.isEmpty ? nil : summary.snippet
        measured = nil
        setNeedsLayout()
    }

    /// The picture's side: square, as a post's thumbnail is.
    private static let pictureSide: CGFloat = 100
    private static let spacing: CGFloat = 10

    private var hasPicture: Bool { picture.image != nil }

    func height(width: CGFloat) -> CGFloat {
        if let measured, abs(measured.width - width) < 0.5 { return measured.height }
        var height: CGFloat = 0
        if hasPicture { height += Self.pictureSide + Self.spacing }
        if headline.text?.isEmpty == false { height += ceil(headline.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height) }
        if snippet.text?.isEmpty == false {
            height += (headline.text?.isEmpty == false ? 6 : 0) + ceil(snippet.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        }
        measured = (width, height)
        return height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        var y: CGFloat = 0
        picture.isHidden = !hasPicture
        if hasPicture {
            picture.frame = CGRect(x: 0, y: 0, width: Self.pictureSide, height: Self.pictureSide)
            y += Self.pictureSide + Self.spacing
        }
        let headlineHeight = headline.text?.isEmpty == false ? ceil(headline.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height) : 0
        headline.frame = CGRect(x: 0, y: y, width: width, height: headlineHeight)
        y += headlineHeight
        if snippet.text?.isEmpty == false {
            if headlineHeight > 0 { y += 6 }
            snippet.frame = CGRect(x: 0, y: y, width: width, height: ceil(snippet.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        } else {
            snippet.frame = .zero
        }
    }
}
