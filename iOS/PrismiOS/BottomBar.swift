import UIKit

/// The bar along the bottom: the views, three to a glass pill at the left;
/// at the right, in a pill of their own, a + to write in today and a
/// magnifier to search. Searching, the views gather to a circle showing
/// the one left — tapped, back to it — and the right pill, its + gone,
/// opens out into a field.
final class BottomBar: UIView, UITextFieldDelegate {
    struct Item {
        var title: String
        var symbol: String
    }

    var onSelect: ((Int) -> Void)?
    /// A view's tab held: its more — the days', a calendar.
    var onHold: ((Int) -> Void)?
    var onWrite: (() -> Void)?
    /// The + held: speaking begun; let go, ended — `cancelled` when slid away.
    var onDictateBegin: (() -> Void)?
    var onDictateEnd: ((_ cancelled: Bool) -> Void)?
    var onSearch: (() -> Void)?
    /// The notes written in last, for the magnifier held: the most recent last.
    var recents: (() -> [HoldMenu.Entry])?
    var onLeaveSearch: (() -> Void)?
    var onQuery: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    static let height: CGFloat = 62
    static let margin: CGFloat = 21
    static let gap: CGFloat = 8

    private let items: [Item]
    private let container = UIVisualEffectView(effect: UIGlassContainerEffect())
    private let pill = BottomBar.glass()
    /// Write and search, together; searching, the field.
    private let actions = BottomBar.glass()
    private var buttons: [UIButton] = []
    private let selection = UIView()
    /// The view left, in the pill gathered to a circle while searching.
    private let gathered = UIButton(type: .system)
    private let writeButton = UIButton(type: .system)
    private let searchButton = UIButton(type: .system)
    private let magnifier = UIImageView()
    let field = UITextField()
    /// Over the bar while dictating: what is heard, as it is.
    private let bubble = BottomBar.glass()
    private let heard = UILabel()

    private(set) var isSearching = false
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            styleButtons()
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) { self.placeSelection() }
        }
    }

    init(items: [Item]) {
        self.items = items
        super.init(frame: .zero)
        addSubview(container)
        for glass in [pill, actions] { container.contentView.addSubview(glass) }

        selection.backgroundColor = Ink.dynamic(UIColor.black.withAlphaComponent(0.07), UIColor.white.withAlphaComponent(0.12))
        selection.isUserInteractionEnabled = false
        pill.contentView.addSubview(selection)
        for (i, item) in items.enumerated() {
            var configuration = UIButton.Configuration.plain()
            configuration.imagePlacement = .top
            configuration.imagePadding = 3
            configuration.contentInsets = .zero
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
            configuration.image = UIImage(systemName: item.symbol + ".fill") ?? UIImage(systemName: item.symbol)
            configuration.attributedTitle = AttributedString(item.title, attributes: AttributeContainer([
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            ]))
            let button = UIButton(configuration: configuration)
            button.tintColor = Ink.text
            button.accessibilityLabel = item.title
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(i) }, for: .touchUpInside)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldTab(_:)))
            hold.minimumPressDuration = 0.4
            button.addGestureRecognizer(hold)
            pill.contentView.addSubview(button)
            buttons.append(button)
        }
        gathered.tintColor = Ink.text
        gathered.alpha = 0
        gathered.accessibilityLabel = "Back"
        gathered.addAction(UIAction { [weak self] _ in self?.onLeaveSearch?() }, for: .touchUpInside)
        pill.contentView.addSubview(gathered)

        let symbol = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
        writeButton.setImage(UIImage(systemName: "plus", withConfiguration: symbol), for: .normal)
        writeButton.tintColor = Ink.text
        writeButton.accessibilityLabel = "Write Today"
        writeButton.addAction(UIAction { [weak self] _ in self?.onWrite?() }, for: .touchUpInside)
        // Held: speaking, written into today.
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.35
        writeButton.addGestureRecognizer(hold)
        heard.numberOfLines = 3
        heard.font = .systemFont(ofSize: 17)
        heard.textColor = Ink.text
        bubble.contentView.addSubview(heard)
        bubble.alpha = 0
        bubble.cornerConfiguration = .uniformCorners(radius: 22)
        addSubview(bubble)
        actions.contentView.addSubview(writeButton)

        searchButton.setImage(UIImage(systemName: "magnifyingglass", withConfiguration: symbol), for: .normal)
        searchButton.tintColor = Ink.text
        searchButton.accessibilityLabel = "Search"
        searchButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
        // Held, the notes written in last, the latest under the thumb.
        searchHold.minimumPressDuration = 0.35
        searchButton.addGestureRecognizer(searchHold)
        actions.contentView.addSubview(searchButton)
        magnifier.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        magnifier.tintColor = Ink.text
        magnifier.contentMode = .center
        magnifier.alpha = 0
        actions.contentView.addSubview(magnifier)
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
        actions.contentView.addSubview(field)
        styleButtons()
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

    private func styleButtons() {
        for (i, button) in buttons.enumerated() {
            button.tintColor = i == selected ? Ink.text : Ink.text.withAlphaComponent(0.85)
        }
        guard items.indices.contains(selected) else { return }
        let symbol = items[selected].symbol
        gathered.setImage(UIImage(systemName: symbol + ".fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
            ?? UIImage(systemName: symbol), for: .normal)
    }

    @objc private func heldTab(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let button = gesture.view as? UIButton, let i = buttons.firstIndex(of: button) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onHold?(i)
    }

    // MARK: Recent notes

    private lazy var searchHold = UILongPressGestureRecognizer(target: self, action: #selector(heldSearch(_:)))
    private var recentMenu: HoldMenu?

    /// One press: held, the menu; slid, a note; lifted, opened.
    @objc private func heldSearch(_ gesture: UILongPressGestureRecognizer) {
        guard let window else { return }
        let point = gesture.location(in: window)
        switch gesture.state {
        case .began:
            let entries = recents?() ?? []
            guard !entries.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let menu = HoldMenu(title: "Recent", entries: entries)
            menu.show(in: window, at: point)
            recentMenu = menu
        case .changed:
            recentMenu?.track(point)
        case .ended:
            recentMenu?.finish(at: point)
            recentMenu = nil
        case .cancelled, .failed:
            recentMenu?.finish(at: nil)
            recentMenu = nil
        default:
            break
        }
    }

    // MARK: Dictating

    private(set) var isDictating = false

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            isDictating = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            writeButton.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)), for: .normal)
            writeButton.tintColor = .systemRed
            showHeard(nil)
            onDictateBegin?()
        case .ended, .cancelled, .failed:
            guard isDictating else { return }
            isDictating = false
            writeButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)), for: .normal)
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

    /// What is heard so far, over the bar — nil: still listening; hidden
    /// when not dictating.
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

    /// Opens out into the field, or folds back: animated.
    func setSearching(_ searching: Bool, animated: Bool = true) {
        guard searching != isSearching else { return }
        isSearching = searching
        let change = {
            self.place()
            self.layoutIfNeeded()
        }
        if animated {
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0, options: [.beginFromCurrentState],
                           animations: change)
        } else {
            change()
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        onSubmit?()
        return false
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        container.frame = bounds
        place()
    }

    /// How wide the right pill is, its two buttons side by side.
    private static let actionsWidth: CGFloat = 116

    private func place() {
        let width = bounds.width, side = Self.height, margin = Self.margin, gap = Self.gap
        if isSearching {
            pill.frame = CGRect(x: margin, y: 0, width: side, height: side)
            let fieldX = pill.frame.maxX + gap
            actions.frame = CGRect(x: fieldX, y: 0, width: width - margin - fieldX, height: side)
        } else {
            actions.frame = CGRect(x: width - margin - Self.actionsWidth, y: 0, width: Self.actionsWidth, height: side)
            pill.frame = CGRect(x: margin, y: 0, width: actions.frame.minX - gap - margin, height: side)
        }
        // The pill's views, or the one left.
        let inner = pill.bounds.insetBy(dx: 4, dy: 4)
        let share = (pill.frame.width - 8) / CGFloat(max(buttons.count, 1))
        for (i, button) in buttons.enumerated() {
            button.frame = CGRect(x: 4 + CGFloat(i) * share, y: inner.minY, width: share, height: inner.height)
            button.alpha = isSearching ? 0 : 1
        }
        placeSelection()
        selection.alpha = isSearching ? 0 : 1
        gathered.frame = pill.bounds
        gathered.alpha = isSearching ? 1 : 0
        // Write and search, each half the right pill; searching, the
        // magnifier at the field's start.
        let half = Self.actionsWidth / 2
        writeButton.frame = CGRect(x: 4, y: 0, width: half - 4, height: side)
        writeButton.alpha = isSearching ? 0 : 1
        searchButton.frame = CGRect(x: half, y: 0, width: half - 4, height: side)
        searchButton.alpha = isSearching ? 0 : 1
        magnifier.frame = CGRect(x: 14, y: 0, width: 24, height: side)
        magnifier.alpha = isSearching ? 1 : 0
        field.frame = CGRect(x: 44, y: 0, width: max(0, actions.bounds.width - 56), height: side)
        field.alpha = isSearching ? 1 : 0
        // What is heard, over the bar, its width the bar's.
        let heardWidth = width - 2 * margin - 36
        let textHeight = ceil(heard.sizeThatFits(CGSize(width: heardWidth, height: .greatestFiniteMagnitude)).height)
        let bubbleHeight = max(52, textHeight + 28)
        bubble.frame = CGRect(x: margin, y: -gap - bubbleHeight, width: width - 2 * margin, height: bubbleHeight)
        heard.frame = CGRect(x: 18, y: 14, width: heardWidth, height: bubbleHeight - 28)
    }

    /// The bubble over the bar is the bar's too, to the touch.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        super.point(inside: point, with: event) || (bubble.alpha > 0 && bubble.frame.contains(point))
    }

    private func placeSelection() {
        guard buttons.indices.contains(selected) else { return }
        selection.frame = buttons[selected].frame
        selection.layer.cornerRadius = selection.frame.height / 2
        selection.layer.cornerCurve = .continuous
    }
}
