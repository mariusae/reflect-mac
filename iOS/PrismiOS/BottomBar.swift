import UIKit

/// The bar along the bottom, as a quiet browser's: one glass panel. Over,
/// a soft field with the name of what is shown — its cover, or its view's
/// mark, before it — tapped to search, held for the notes written in last.
/// Under, plain marks in a row: back; home, held for the other views; what
/// links here, with how many; the menu; and + to write in today, held to
/// speak. Searching, the panel is the field alone, an ✕ beside it; scrolled
/// down, it gathers to a small pill of the name.
final class BottomBar: UIView, UITextFieldDelegate {
    var onBack: (() -> Void)?
    /// Home: today, in the days.
    var onHome: (() -> Void)?
    /// The ⋯: the views, the note's own, the app's.
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

    /// The panel: its field over its row of marks.
    static let height: CGFloat = 96
    /// From the screen's foot.
    static let margin: CGFloat = 24
    /// From the screen's sides.
    static let side: CGFloat = 28
    static let gap: CGFloat = 8
    private static let fieldHeight: CGFloat = 38
    private static let inset: CGFloat = 8
    private static let radius: CGFloat = 28
    /// Searching: the panel the field alone.
    private static let searchHeight: CGFloat = fieldHeight + 2 * inset
    /// Gathered: the pill this tall, this much lower.
    static let smallHeight: CGFloat = 32
    static let smallDrop: CGFloat = 10

    private let panel: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect())
        view.cornerConfiguration = .uniformCorners(radius: .fixed(BottomBar.radius))
        return view
    }()
    /// The field the name is in: a shade on the glass.
    private let well = UIView()
    private let round = UIImageView()
    private let title = ShortLabel()
    private let titleButton = UIButton(type: .custom)
    /// The name, gathered small: its own, faded in as the other fades out.
    private let smallTitle = ShortLabel()
    private let backButton = UIButton(type: .system)
    private let homeButton = UIButton(type: .system)
    private let backlinksButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let writeButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let magnifier = UIImageView()
    let field = UITextField()
    /// Over the bar while dictating: what is heard, as it is.
    private let bubble: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect())
        view.cornerConfiguration = .uniformCorners(radius: .fixed(22))
        return view
    }()
    private let heard = UILabel()

    private(set) var isSearching = false
    private(set) var isSmall = false
    private(set) var backlinkCount = 0
    var canGoBack = false {
        didSet { backButton.isEnabled = canGoBack }
    }

    private static func mark(_ name: String, size: CGFloat = 19) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    init() {
        super.init(frame: .zero)
        addSubview(panel)
        let content = panel.contentView

        well.backgroundColor = Ink.text.withAlphaComponent(0.06)
        well.layer.cornerCurve = .continuous
        content.addSubview(well)
        round.contentMode = .scaleAspectFill
        round.clipsToBounds = true
        round.tintColor = Ink.secondary
        well.addSubview(round)
        title.font = Typeface.current.heading(16, weight: .semibold)
        title.textColor = Ink.text
        title.textAlignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.isAccessibilityElement = false
        well.addSubview(title)
        smallTitle.font = Typeface.current.heading(14, weight: .semibold)
        smallTitle.textColor = Ink.text
        smallTitle.textAlignment = .center
        smallTitle.lineBreakMode = .byTruncatingTail
        smallTitle.alpha = 0
        smallTitle.isAccessibilityElement = false
        well.addSubview(smallTitle)
        // Over the name, to be touched: tapped, searching; held, the notes written in last.
        titleButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
        titleButton.accessibilityHint = "Search"
        hold(titleButton, as: .title, after: 0.35)
        well.addSubview(titleButton)

        magnifier.image = Self.mark("magnifyingglass", size: 16)
        magnifier.tintColor = Ink.secondary
        magnifier.contentMode = .center
        magnifier.alpha = 0
        well.addSubview(magnifier)
        field.placeholder = "Search"
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.clearButtonMode = .whileEditing
        field.font = Typeface.current.body(17)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .go
        field.delegate = self
        field.alpha = 0
        field.addAction(UIAction { [weak self] _ in self?.onQuery?(self?.field.text ?? "") }, for: .editingChanged)
        well.addSubview(field)

        // The row of marks: plain, as a browser's.
        backButton.setImage(Self.mark("chevron.left"), for: .normal)
        backButton.accessibilityLabel = "Back"
        backButton.isEnabled = false
        backButton.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        homeButton.setImage(Self.mark("house"), for: .normal)
        homeButton.accessibilityLabel = "Today"
        homeButton.addAction(UIAction { [weak self] _ in self?.onHome?() }, for: .touchUpInside)
        // Held: the other views — the inbox, the pinned notes, the tasks.
        hold(homeButton, as: .home, after: 0.35)
        var linksStyle = UIButton.Configuration.plain()
        linksStyle.image = Self.mark("arrow.turn.up.left", size: 17)
        linksStyle.imagePadding = 4
        linksStyle.contentInsets = .zero
        backlinksButton.configuration = linksStyle
        backlinksButton.accessibilityLabel = "Linked Here"
        backlinksButton.isEnabled = false
        // Touched: the notes dealt out at once, the thumb followed, let go on one.
        hold(backlinksButton, as: .backlinks, after: 0)
        menuButton.setImage(Self.mark("ellipsis"), for: .normal)
        menuButton.accessibilityLabel = "Menu"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menu?().children ?? [])
        }])
        writeButton.setImage(Self.mark("plus", size: 21), for: .normal)
        writeButton.accessibilityLabel = "Write in Today"
        writeButton.addAction(UIAction { [weak self] _ in self?.onWrite?() }, for: .touchUpInside)
        let speak = UILongPressGestureRecognizer(target: self, action: #selector(heldPlus(_:)))
        speak.minimumPressDuration = 0.35
        writeButton.addGestureRecognizer(speak)
        for button in [backButton, homeButton, backlinksButton, menuButton, writeButton] {
            button.tintColor = Ink.text
            content.addSubview(button)
        }
        closeButton.setImage(Self.mark("xmark", size: 17), for: .normal)
        closeButton.tintColor = Ink.text
        closeButton.accessibilityLabel = "Close Search"
        closeButton.addAction(UIAction { [weak self] _ in self?.onLeaveSearch?() }, for: .touchUpInside)
        closeButton.alpha = 0
        content.addSubview(closeButton)

        // Gathered small, the pill tapped anywhere: straight to searching.
        let small = UITapGestureRecognizer(target: self, action: #selector(tappedSmall))
        panel.addGestureRecognizer(small)
        smallTap = small

        heard.numberOfLines = 3
        heard.font = Typeface.current.body(17)
        heard.textColor = Ink.text
        bubble.contentView.addSubview(heard)
        bubble.alpha = 0
        addSubview(bubble)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: What is shown

    /// The name of what is shown, in the field: its cover before it, or —
    /// a view, not a note — its mark; else a note's.
    func setTitle(_ names: [String], cover: UIImage? = nil, symbol: String? = nil) {
        if let cover {
            round.image = cover
            round.contentMode = .scaleAspectFill
            round.backgroundColor = .clear
        } else {
            round.image = symbol.flatMap { Self.mark($0, size: 13) } ?? Self.mark("doc.text", size: 13)
            round.contentMode = .center
            round.backgroundColor = Ink.text.withAlphaComponent(0.06)
        }
        guard title.names != names else { return setNeedsLayout() }
        title.names = names
        smallTitle.names = names
        titleButton.accessibilityLabel = names.first
        setNeedsLayout()
    }

    private weak var smallTap: UITapGestureRecognizer?

    /// Gathered small, the name tapped: straight to searching, as Safari's.
    @objc private func tappedSmall() {
        guard isSmall else { return }
        onSearch?()
    }

    // MARK: Gathered small

    /// Gathered to a small pill of the name alone, low — as a browser's is
    /// scrolled down — or out again.
    func setSmall(_ small: Bool, animated: Bool = true) {
        guard small != isSmall, !isSearching || !small else { return }
        isSmall = small
        animate(animated, duration: 0.4)
    }

    private func animate(_ animated: Bool, duration: TimeInterval) {
        let change = {
            self.place()
            self.layoutIfNeeded()
        }
        guard animated else { return change() }
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
    }

    // MARK: Held

    private var holds: [UIGestureRecognizer: Held] = [:]

    private func hold(_ view: UIView, as what: Held, after delay: TimeInterval) {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        gesture.minimumPressDuration = delay
        gesture.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(gesture)
        holds[gesture] = what
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard let window, let what = holds[gesture], !isSearching else { return }
        if what == .backlinks, backlinkCount == 0 { return }
        if gesture.state == .began { UIImpactFeedbackGenerator(style: what == .backlinks ? .light : .medium).impactOccurred() }
        onHold?(what, gesture.state, gesture.location(in: window))
    }

    /// Where something held is, in the bar: what its notes are dealt from.
    func frame(of what: Held) -> CGRect {
        switch what {
        case .home: homeButton.convert(homeButton.bounds, to: self)
        case .title: pillFrame
        case .backlinks: backlinksButton.convert(backlinksButton.bounds, to: self)
        }
    }

    /// The field, in the bar: the column notes are dealt into.
    var pillFrame: CGRect { well.convert(well.bounds, to: self) }

    /// The panel's top, in the bar: what is dealt out lies over it.
    var panelTop: CGFloat { panel.frame.minY }

    /// How many notes link to what is shown: their count by its mark; none,
    /// the mark faint.
    func showBacklinks(_ count: Int) {
        guard count != backlinkCount else { return }
        backlinkCount = count
        backlinksButton.configuration?.attributedTitle = count > 0 ? AttributedString("\(count)", attributes: AttributeContainer([
            .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
        ])) : nil
        backlinksButton.accessibilityValue = count == 1 ? "1 note" : "\(count) notes"
        backlinksButton.isEnabled = count > 0
        animate(true, duration: 0.25)
    }

    // MARK: Dictating

    private(set) var isDictating = false

    @objc private func heldPlus(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDictating = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            writeButton.setImage(Self.mark("mic.fill", size: 21), for: .normal)
            writeButton.tintColor = .systemRed
            showHeard(nil)
            onDictateBegin?()
        case .ended, .cancelled, .failed:
            guard isDictating else { return }
            isDictating = false
            writeButton.setImage(Self.mark("plus", size: 21), for: .normal)
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

    /// The panel the field alone, to type in, the ✕ beside it; or back.
    func setSearching(_ searching: Bool, animated: Bool = true) {
        guard searching != isSearching else { return }
        isSearching = searching
        if searching { isSmall = false }
        animate(animated, duration: 0.42)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit?()
        return false
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        place()
    }

    private func place() {
        let width = bounds.width, height = bounds.height, inset = Self.inset
        smallTap?.isEnabled = isSmall
        let marks: [UIView] = [backButton, homeButton, backlinksButton, menuButton, writeButton]
        if isSmall {
            // The name alone, small, centred, low: the panel gathered into it.
            let words = ceil(((title.names.first ?? "") as NSString).size(withAttributes: [.font: smallTitle.font as Any]).width)
            let w = min(max(words + 40, 120), width - 2 * Self.side)
            panel.frame = CGRect(x: ((width - w) / 2).rounded(), y: height - Self.smallHeight + Self.smallDrop, width: w, height: Self.smallHeight)
            panel.cornerConfiguration = .capsule()
            well.frame = panel.bounds
            well.backgroundColor = .clear
            well.layer.cornerRadius = Self.smallHeight / 2
            smallTitle.frame = well.bounds.insetBy(dx: 14, dy: 0)
            smallTitle.alpha = 1
            titleButton.frame = well.bounds
            titleButton.isUserInteractionEnabled = false
            for view in marks + [title, round, magnifier, field, closeButton] as [UIView] { view.alpha = 0 }
            placeBubble(width: width)
            return
        }
        panel.cornerConfiguration = .uniformCorners(radius: .fixed(Self.radius))
        well.backgroundColor = Ink.text.withAlphaComponent(0.06)
        smallTitle.alpha = 0
        titleButton.isUserInteractionEnabled = !isSearching
        let panelHeight = isSearching ? Self.searchHeight : Self.height
        panel.frame = CGRect(x: Self.side, y: height - panelHeight, width: width - 2 * Self.side, height: panelHeight)
        let inner = panel.bounds.width
        // The field: across the panel; searching, an ✕ beside it.
        let closeSide: CGFloat = 40
        well.frame = CGRect(x: inset, y: inset, width: inner - 2 * inset - (isSearching ? closeSide : 0), height: Self.fieldHeight)
        well.layer.cornerRadius = Self.fieldHeight / 2
        closeButton.frame = CGRect(x: inner - inset - closeSide, y: inset, width: closeSide, height: Self.fieldHeight)
        closeButton.alpha = isSearching ? 1 : 0
        // The name centred in the field, its round just before it — or, too
        // long for that, as near it as it can be.
        let side: CGFloat = 26, field = well.bounds
        let room = max(0, field.width - 2 * 14 - side - 8)
        let words = min(room, title.width(within: room))
        let group = side + 8 + words
        let x = max(14, (field.width - group) / 2)
        round.frame = CGRect(x: x, y: (field.height - side) / 2, width: side, height: side)
        round.layer.cornerRadius = side / 2
        title.frame = CGRect(x: round.frame.maxX + 8, y: 0, width: words, height: field.height)
        smallTitle.frame = title.frame
        titleButton.frame = field
        for view in [title, round] as [UIView] { view.alpha = isSearching ? 0 : 1 }
        magnifier.frame = CGRect(x: 10, y: 0, width: 24, height: field.height)
        magnifier.alpha = isSearching ? 1 : 0
        self.field.frame = CGRect(x: 38, y: 0, width: max(0, field.width - 46), height: field.height)
        self.field.alpha = isSearching ? 1 : 0
        // The marks, evenly along the row under the field.
        let rowY = inset + Self.fieldHeight, rowHeight = Self.height - rowY - 2
        let slot = (inner - 2 * inset) / CGFloat(marks.count)
        for (i, mark) in marks.enumerated() {
            mark.frame = CGRect(x: inset + CGFloat(i) * slot, y: rowY, width: slot, height: rowHeight)
            mark.alpha = isSearching ? 0 : 1
        }
        placeBubble(width: width)
    }

    /// What is heard, over the panel, as wide.
    private func placeBubble(width: CGFloat) {
        let heardWidth = width - 2 * Self.side - 36
        let textHeight = ceil(heard.sizeThatFits(CGSize(width: heardWidth, height: .greatestFiniteMagnitude)).height)
        let bubbleHeight = max(52, textHeight + 28)
        bubble.frame = CGRect(x: Self.side, y: bounds.height - Self.height - Self.gap - bubbleHeight, width: width - 2 * Self.side, height: bubbleHeight)
        heard.frame = CGRect(x: 18, y: 14, width: heardWidth, height: bubbleHeight - 28)
    }

    /// Only the panel is the bar's, to the touch — and the bubble over it,
    /// while it shows.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        panel.frame.insetBy(dx: -4, dy: -4).contains(point) || (bubble.alpha > 0 && bubble.frame.contains(point))
    }
}
