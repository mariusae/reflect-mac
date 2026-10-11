import UIKit

/// The bar along the bottom, as Safari's: back in a glass circle at the
/// left; in the middle, a glass pill — the menu at its start, the name of
/// what is shown, and what links to it where Safari has reload; a + to
/// write in today in a circle at the right. The name tapped opens the pill
/// out into a field to search, an ✕ beside it to close it again; scrolled
/// down, it all gathers to a small pill of the name alone.
final class BottomBar: UIView, UITextFieldDelegate {
    /// Home: today, in the days.
    var onHome: (() -> Void)?
    /// The menu at the pill's start: the views, the note's own, the app's.
    var menu: (() -> UIMenu)?
    var onWrite: (() -> Void)?
    /// The + held: speaking begun; let go, ended — `cancelled` when slid away.
    var onDictateBegin: (() -> Void)?
    var onDictateEnd: ((_ cancelled: Bool) -> Void)?
    /// The name tapped: searching.
    var onSearch: (() -> Void)?
    var onLeaveSearch: (() -> Void)?
    var onQuery: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    /// What can be held to deal out things to choose among: home, for the
    /// other views; the name, for those written in last; what links here
    /// — that one at a touch.
    enum Held { case home, title, backlinks }
    /// Something held: its notes dealt out (`.began`), the thumb followed
    /// (`.changed`), let go (`.ended`, or `.cancelled`) — in the window.
    var onHold: ((Held, UIGestureRecognizer.State, CGPoint) -> Void)?

    /// Safari's: the circles and the pill as tall, the margins and gaps its.
    static let height: CGFloat = 48
    static let margin: CGFloat = 21
    static let side: CGFloat = 33
    static let gap: CGFloat = 8
    /// Gathered: the pill this tall, this much lower.
    static let smallHeight: CGFloat = 32
    static let smallDrop: CGFloat = 10

    private let container = UIVisualEffectView(effect: UIGlassContainerEffect())
    private let homeGlass = BottomBar.glass()
    private let homeButton = UIButton(type: .system)
    private let pill = BottomBar.glass()
    private let menuButton = UIButton(type: .system)
    private let title = ShortLabel()
    private let titleButton = UIButton(type: .custom)
    /// The name, gathered small: its own, faded in as the other fades out.
    private let smallTitle = ShortLabel()
    private let backlinksButton = UIButton(type: .system)
    private let plusGlass = BottomBar.glass()
    private let writeButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let magnifier = UIImageView()
    let field = UITextField()
    /// Over the bar while dictating: what is heard, as it is.
    private let bubble = BottomBar.glass()
    private let heard = UILabel()

    private(set) var isSearching = false
    private(set) var isSmall = false
    private(set) var backlinkCount = 0

    init() {
        super.init(frame: .zero)
        addSubview(container)
        for glass in [homeGlass, pill, plusGlass] { container.contentView.addSubview(glass) }
        let symbol = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)

        // Home, to today; back is a swipe from the edge.
        homeButton.setImage(UIImage(systemName: "house", withConfiguration: symbol), for: .normal)
        homeButton.tintColor = Ink.text
        homeButton.accessibilityLabel = "Today"
        homeButton.addAction(UIAction { [weak self] _ in self?.onHome?() }, for: .touchUpInside)
        // Held: the other views — the inbox, the pinned notes, the tasks.
        let homeHold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        homeHold.minimumPressDuration = 0.35
        homeHold.allowableMovement = .greatestFiniteMagnitude
        homeButton.addGestureRecognizer(homeHold)
        holds[homeHold] = .home
        homeGlass.contentView.addSubview(homeButton)

        menuButton.setImage(NoteChip.standIn, for: .normal)
        menuButton.backgroundColor = NoteChip.standInGround
        menuButton.tintColor = Ink.secondary
        menuButton.accessibilityLabel = "Menu"
        // The note's cover in its place, when it has one: round, as the top's was.
        menuButton.clipsToBounds = true
        menuButton.imageView?.contentMode = .scaleAspectFill
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menu?().children ?? [])
        }])
        pill.contentView.addSubview(menuButton)

        title.font = Typeface.current.heading(16, weight: .semibold)
        title.textColor = Ink.text
        title.textAlignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.isAccessibilityElement = false
        pill.contentView.addSubview(title)
        // Over the name, to be touched: a control, as the glass passes touches to one.
        titleButton.addAction(UIAction { [weak self] _ in self?.tappedTitle() }, for: .touchUpInside)
        titleButton.accessibilityHint = "Search"
        let titleHold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        titleHold.minimumPressDuration = 0.35
        titleHold.allowableMovement = .greatestFiniteMagnitude
        titleButton.addGestureRecognizer(titleHold)
        holds[titleHold] = .title
        smallTitle.font = Typeface.current.heading(14, weight: .semibold)
        smallTitle.textColor = Ink.text
        smallTitle.textAlignment = .center
        smallTitle.lineBreakMode = .byTruncatingTail
        smallTitle.alpha = 0
        smallTitle.isAccessibilityElement = false
        pill.contentView.addSubview(smallTitle)
        pill.contentView.addSubview(titleButton)
        // Gathered small, the pill tapped anywhere: out again.
        let expand = UITapGestureRecognizer(target: self, action: #selector(tappedSmall))
        pill.addGestureRecognizer(expand)
        smallTap = expand

        var linksStyle = UIButton.Configuration.plain()
        linksStyle.image = UIImage(systemName: "arrow.turn.up.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        linksStyle.imagePadding = 4
        linksStyle.contentInsets = .zero
        backlinksButton.configuration = linksStyle
        backlinksButton.tintColor = Ink.text
        backlinksButton.accessibilityLabel = "Linked Here"
        // Touched: the cards dealt out at once, the thumb followed, let go on one.
        let linksHold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        linksHold.minimumPressDuration = 0
        linksHold.allowableMovement = .greatestFiniteMagnitude
        backlinksButton.addGestureRecognizer(linksHold)
        holds[linksHold] = .backlinks
        backlinksButton.alpha = 0
        pill.contentView.addSubview(backlinksButton)

        magnifier.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        magnifier.tintColor = Ink.secondary
        magnifier.contentMode = .center
        magnifier.alpha = 0
        pill.contentView.addSubview(magnifier)
        field.placeholder = "Search"
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.clearButtonMode = .whileEditing
        field.font = .systemFont(ofSize: 17)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.delegate = self
        field.alpha = 0
        field.addAction(UIAction { [weak self] _ in self?.onQuery?(self?.field.text ?? "") }, for: .editingChanged)
        pill.contentView.addSubview(field)

        writeButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)), for: .normal)
        writeButton.tintColor = Ink.text
        writeButton.accessibilityLabel = "Write in Today"
        writeButton.addAction(UIAction { [weak self] _ in self?.onWrite?() }, for: .touchUpInside)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldPlus(_:)))
        hold.minimumPressDuration = 0.35
        writeButton.addGestureRecognizer(hold)
        plusGlass.contentView.addSubview(writeButton)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                             for: .normal)
        closeButton.tintColor = Ink.text
        closeButton.accessibilityLabel = "Close Search"
        closeButton.addAction(UIAction { [weak self] _ in self?.onLeaveSearch?() }, for: .touchUpInside)
        closeButton.alpha = 0
        plusGlass.contentView.addSubview(closeButton)

        heard.numberOfLines = 3
        heard.font = .systemFont(ofSize: 17)
        heard.textColor = Ink.text
        bubble.contentView.addSubview(heard)
        bubble.alpha = 0
        bubble.cornerConfiguration = .uniformCorners(radius: 22)
        addSubview(bubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func glass() -> UIVisualEffectView {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }

    // MARK: What is shown

    /// The name of what is shown, in the pill.
    func setTitle(_ names: [String], cover: UIImage? = nil) {
        if cover !== self.cover {
            self.cover = cover
            setMenuFace()
        }
        guard title.names != names else { return }
        title.names = names
        smallTitle.names = names
        titleButton.accessibilityLabel = names.first
        if isSmall { setNeedsLayout() }
    }

    private func tappedTitle() {
        if isSmall { return tappedSmall() }
        onSearch?()
    }

    private weak var smallTap: UITapGestureRecognizer?

    /// The cover before the name, as the menu's face; none, a note's mark in its stead.
    private var cover: UIImage?

    private func setMenuFace() {
        if let cover {
            menuButton.setImage(cover.withRenderingMode(.alwaysOriginal), for: .normal)
            menuButton.contentHorizontalAlignment = .fill
            menuButton.contentVerticalAlignment = .fill
            menuButton.backgroundColor = .clear
        } else {
            menuButton.setImage(NoteChip.standIn, for: .normal)
            menuButton.backgroundColor = NoteChip.standInGround
            menuButton.contentHorizontalAlignment = .center
            menuButton.contentVerticalAlignment = .center
        }
        setNeedsLayout()
    }

    /// Gathered small, the name tapped: straight to searching, as Safari's.
    @objc private func tappedSmall() {
        guard isSmall else { return }
        onSearch?()
    }

    // MARK: Gathered small

    /// Gathered to a small pill of the name alone, low — as Safari's is
    /// scrolled down — or out again.
    func setSmall(_ small: Bool, animated: Bool = true) {
        guard small != isSmall, !isSearching || !small else { return }
        isSmall = small
        let change = {
            self.place()
            self.layoutIfNeeded()
        }
        guard animated else { return change() }
        UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
    }

    // MARK: What links here

    private var holds: [UIGestureRecognizer: Held] = [:]

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard let window, let what = holds[gesture], !isSearching else { return }
        if gesture.state == .began { UIImpactFeedbackGenerator(style: what == .backlinks ? .light : .medium).impactOccurred() }
        onHold?(what, gesture.state, gesture.location(in: window))
    }

    /// Where something held is, in the bar: what its notes are dealt from.
    func frame(of what: Held) -> CGRect {
        switch what {
        case .home: homeGlass.frame
        case .title: pill.frame
        case .backlinks: backlinksFrame
        }
    }

    /// The pill, in the bar: the column the notes are dealt into.
    var pillFrame: CGRect { pill.frame }

    /// Where its button is, in the bar: what its cards are dealt from.
    var backlinksFrame: CGRect { pill.convert(backlinksButton.frame, to: self) }

    /// How many notes link to what is shown: their count where Safari has
    /// reload, or — none — nothing there.
    func showBacklinks(_ count: Int) {
        guard count != backlinkCount else { return }
        backlinkCount = count
        if count > 0 {
            backlinksButton.configuration?.attributedTitle = AttributedString("\(count)", attributes: AttributeContainer([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            ]))
            backlinksButton.accessibilityValue = count == 1 ? "1 note" : "\(count) notes"
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
            self.place()
            self.layoutIfNeeded()
        }
    }

    // MARK: Dictating

    private(set) var isDictating = false

    @objc private func heldPlus(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDictating = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            writeButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)), for: .normal)
            writeButton.tintColor = .systemRed
            showHeard(nil)
            onDictateBegin?()
        case .ended, .cancelled, .failed:
            guard isDictating else { return }
            isDictating = false
            writeButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .medium)), for: .normal)
            writeButton.tintColor = Ink.text
            // Slid well away from the +, then let go: not kept.
            let point = gesture.location(in: self)
            let cancelled = gesture.state != .ended || point.y < -80
            if cancelled { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            onDictateEnd?(cancelled)
        default:
            break
        }
    }

    /// What is heard so far, over the bar — nil: still listening.
    func showHeard(_ text: String?) {
        heard.text = text?.isEmpty == false ? text : "Listening…"
        heard.textColor = text?.isEmpty == false ? Ink.text : Ink.secondary
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: 0.2) { self.bubble.alpha = 1 }
    }

    func hideHeard() {
        UIView.animate(withDuration: 0.25) { self.bubble.alpha = 0 }
    }

    // MARK: Searching

    /// The pill opened out into the field, the ✕ in the +'s place; or back.
    func setSearching(_ searching: Bool, animated: Bool = true) {
        guard searching != isSearching else { return }
        isSearching = searching
        if searching { isSmall = false }
        let change = {
            self.place()
            self.layoutIfNeeded()
        }
        guard animated else { return change() }
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.84, initialSpringVelocity: 0, options: [.beginFromCurrentState],
                       animations: change)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit?()
        return false
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Down past the foot, for the pill gathered small and low.
        container.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height + Self.smallDrop + 8)
        place()
    }

    private func place() {
        let width = bounds.width, h = Self.height, margin = Self.side, gap = Self.gap
        smallTap?.isEnabled = isSmall
        if isSmall {
            // The name alone, small, centred, low: the circles gone into it.
            let words = ceil(((title.names.first ?? "") as NSString).size(withAttributes: [.font: smallTitle.font as Any]).width)
            let w = min(max(words + 40, 120), width - 2 * margin)
            let small = CGRect(x: ((width - w) / 2).rounded(), y: h - Self.smallHeight + Self.smallDrop, width: w, height: Self.smallHeight)
            pill.frame = small
            homeGlass.frame = CGRect(x: small.minX, y: small.minY, width: Self.smallHeight, height: Self.smallHeight)
            plusGlass.frame = CGRect(x: small.maxX - Self.smallHeight, y: small.minY, width: Self.smallHeight, height: Self.smallHeight)
            homeGlass.alpha = 0
            plusGlass.alpha = 0
            smallTitle.frame = pill.bounds.insetBy(dx: 14, dy: 0)
            smallTitle.alpha = 1
            title.frame.origin.x = (pill.bounds.width - title.frame.width) / 2
            titleButton.frame = pill.bounds
            for view in [title, menuButton, backlinksButton, magnifier, field] as [UIView] { view.alpha = 0 }
            placeBubble(width: width)
            return
        }
        homeGlass.alpha = isSearching ? 0 : 1
        plusGlass.alpha = 1
        smallTitle.alpha = 0
        homeGlass.frame = CGRect(x: margin, y: 0, width: h, height: h)
        plusGlass.frame = CGRect(x: width - margin - h, y: 0, width: h, height: h)
        homeButton.frame = homeGlass.bounds
        writeButton.frame = plusGlass.bounds
        closeButton.frame = plusGlass.bounds
        writeButton.alpha = isSearching ? 0 : 1
        closeButton.alpha = isSearching ? 1 : 0
        // Searching, the pill from the margin to the ✕; else between the circles.
        let left = isSearching ? margin : homeGlass.frame.maxX + gap
        pill.frame = CGRect(x: left, y: 0, width: plusGlass.frame.minX - gap - left, height: h)
        let inner = pill.bounds
        // The round at the start — the cover, or the menu's lines — as the top's pill had.
        let round: CGFloat = 38
        menuButton.frame = CGRect(x: 5, y: (h - round) / 2, width: round, height: round)
        menuButton.layer.cornerRadius = round / 2
        menuButton.alpha = isSearching ? 0 : 1
        let linksWidth = backlinkCount > 0 ? ceil(backlinksButton.intrinsicContentSize.width) + 20 : 0
        backlinksButton.frame = CGRect(x: inner.width - linksWidth - 6, y: 0, width: linksWidth, height: h)
        backlinksButton.alpha = backlinkCount > 0 && !isSearching ? 1 : 0
        // The name centred in the pill — or, too long for that, as near it as
        // it can be — clear of the round and of what links here, if anything does.
        let lead = menuButton.frame.maxX + 10, trail = max(18, linksWidth + 6)
        let room = max(0, inner.width - lead - trail)
        let words = min(room, title.width(within: room))
        let x = min(max((inner.width - words) / 2, lead), inner.width - trail - words)
        title.frame = CGRect(x: x, y: 0, width: words, height: h)
        smallTitle.frame = title.frame
        titleButton.frame = CGRect(x: lead, y: 0, width: room, height: h)
        titleButton.isHidden = isSearching
        title.alpha = isSearching ? 0 : 1
        magnifier.frame = CGRect(x: 12, y: 0, width: 24, height: h)
        magnifier.alpha = isSearching ? 1 : 0
        field.frame = CGRect(x: 40, y: 0, width: max(0, inner.width - 52), height: h)
        field.alpha = isSearching ? 1 : 0
        placeBubble(width: width)
    }

    /// What is heard, over the bar, its width the bar's.
    private func placeBubble(width: CGFloat) {
        let margin = Self.side, gap = Self.gap
        let heardWidth = width - 2 * margin - 36
        let textHeight = ceil(heard.sizeThatFits(CGSize(width: heardWidth, height: .greatestFiniteMagnitude)).height)
        let bubbleHeight = max(52, textHeight + 28)
        bubble.frame = CGRect(x: margin, y: -gap - bubbleHeight, width: width - 2 * margin, height: bubbleHeight)
        heard.frame = CGRect(x: 18, y: 14, width: heardWidth, height: bubbleHeight - 28)
    }

    /// The bubble over the bar is the bar's too, to the touch; gathered
    /// small, only the pill.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isSmall { return pill.frame.insetBy(dx: -8, dy: -8).contains(point) }
        return super.point(inside: point, with: event) || (bubble.alpha > 0 && bubble.frame.contains(point))
    }
}
