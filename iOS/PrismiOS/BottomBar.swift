import UIKit
import PrismCore

/// The bar along the bottom, as a quiet browser's: one glass panel. Over,
/// a field with the name of what is shown in it — as a browser's address —
/// tapped, to search; under, the lenses in a row — Daily, the inbox, the
/// tasks, the pinned — the one shown marked, and + to write in today, held
/// to speak. Searching, the panel is the field alone, an ✕ beside it; read
/// down into a note, it gathers to a small pill of its name.
final class BottomBar: UIView, UITextFieldDelegate {
    /// A lens chosen — the one shown chosen again: back to its start.
    var onLens: ((Lens) -> Void)?
    var onWrite: (() -> Void)?
    /// The + held: speaking begun; let go, ended — `cancelled` when slid away.
    var onDictateBegin: (() -> Void)?
    var onDictateEnd: ((_ cancelled: Bool) -> Void)?
    /// The field tapped: searching.
    var onSearch: (() -> Void)?
    var onLeaveSearch: (() -> Void)?
    var onQuery: ((String) -> Void)?
    var onSubmit: (() -> Void)?

    /// The panel: its field over its row of lenses.
    static let height: CGFloat = 96
    /// From the screen's foot.
    static let margin: CGFloat = 24
    /// From the screen's sides.
    static let side: CGFloat = 20
    static let gap: CGFloat = 8
    private static let fieldHeight: CGFloat = 38
    private static let inset: CGFloat = 8
    private static let radius: CGFloat = 28
    private static let searchHeight: CGFloat = fieldHeight + 2 * inset
    /// Gathered: the pill this tall, this much lower.
    static let smallHeight: CGFloat = 32
    static let smallDrop: CGFloat = 10

    /// The lenses in the row, in order: search is the field's.
    static let lenses: [Lens] = [.daily, .inbox, .tasks, .pinned]

    private let panel: UIVisualEffectView = {
        let view = UIVisualEffectView(effect: UIGlassEffect())
        view.cornerConfiguration = .uniformCorners(radius: .fixed(BottomBar.radius))
        return view
    }()
    /// The field: a shade on the glass, the magnifier and its words in it.
    private let well = UIView()
    private let magnifier = UIImageView()
    private let placeholder = UILabel()
    private let wellButton = UIButton(type: .custom)
    /// Gathered small: the name of what is shown.
    private let smallTitle = ShortLabel()
    private var lensButtons: [Lens: UIButton] = [:]
    private let writeButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
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
    /// The lens shown: its mark filled.
    var lens: Lens = .daily { didSet { if lens != oldValue { styleLenses() } } }

    private static func mark(_ name: String, size: CGFloat = 19, weight: UIImage.SymbolWeight = .regular) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// A lens's mark, filled when it is the one shown.
    private static func symbol(_ lens: Lens, chosen: Bool) -> String {
        switch lens {
        case .daily: chosen ? "sun.max.fill" : "sun.max"
        case .inbox: chosen ? "tray.fill" : "tray"
        case .tasks: chosen ? "checklist.checked" : "checklist"
        case .pinned: chosen ? "pin.fill" : "pin"
        case .search: "magnifyingglass"
        }
    }

    init() {
        super.init(frame: .zero)
        addSubview(panel)
        let content = panel.contentView

        well.backgroundColor = Ink.text.withAlphaComponent(0.06)
        well.layer.cornerCurve = .continuous
        content.addSubview(well)
        magnifier.image = Self.mark("magnifyingglass", size: 15)
        magnifier.tintColor = Ink.secondary
        magnifier.contentMode = .center
        well.addSubview(magnifier)
        placeholder.text = "Search"
        placeholder.font = Typeface.current.body(17)
        placeholder.textColor = Ink.secondary
        well.addSubview(placeholder)
        wellButton.addAction(UIAction { [weak self] _ in self?.onSearch?() }, for: .touchUpInside)
        wellButton.accessibilityLabel = "Search"
        wellButton.accessibilityHint = "The name of what is shown; tapped, search"
        well.addSubview(wellButton)
        smallTitle.font = Typeface.current.heading(15, weight: .semibold)
        smallTitle.textColor = Ink.text
        smallTitle.textAlignment = .center
        // Its words kept in its middle as it grows and shrinks, not redrawn at once at the end's size.
        smallTitle.contentMode = .center
        smallTitle.lineBreakMode = .byTruncatingTail
        smallTitle.alpha = 0
        well.addSubview(smallTitle)

        field.placeholder = "Search notes and days"
        field.borderStyle = .none
        field.backgroundColor = .clear
        field.clearButtonMode = .whileEditing
        field.font = Typeface.current.body(17)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .search
        field.delegate = self
        field.alpha = 0
        field.addAction(UIAction { [weak self] _ in self?.onQuery?(self?.field.text ?? "") }, for: .editingChanged)
        well.addSubview(field)

        for lens in Self.lenses {
            let button = UIButton(type: .system)
            button.accessibilityLabel = lens.title
            button.addAction(UIAction { [weak self] _ in
                UISelectionFeedbackGenerator().selectionChanged()
                self?.onLens?(lens)
            }, for: .touchUpInside)
            content.addSubview(button)
            lensButtons[lens] = button
        }
        styleLenses()
        writeButton.setImage(Self.mark("plus", size: 21), for: .normal)
        writeButton.tintColor = Ink.text
        writeButton.accessibilityLabel = "Write in Today"
        writeButton.addAction(UIAction { [weak self] _ in self?.onWrite?() }, for: .touchUpInside)
        let speak = UILongPressGestureRecognizer(target: self, action: #selector(heldPlus(_:)))
        speak.minimumPressDuration = 0.35
        writeButton.addGestureRecognizer(speak)
        content.addSubview(writeButton)
        closeButton.setImage(Self.mark("xmark", size: 17), for: .normal)
        closeButton.tintColor = Ink.text
        closeButton.accessibilityLabel = "Close Search"
        closeButton.addAction(UIAction { [weak self] _ in self?.onLeaveSearch?() }, for: .touchUpInside)
        closeButton.alpha = 0
        content.addSubview(closeButton)

        // Gathered small, the pill tapped: out again.
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

    private func styleLenses() {
        for (lens, button) in lensButtons {
            let chosen = lens == self.lens
            button.setImage(Self.mark(Self.symbol(lens, chosen: chosen), weight: chosen ? .semibold : .regular), for: .normal)
            button.tintColor = chosen ? Ink.text : Ink.secondary
            button.accessibilityTraits = chosen ? [.button, .selected] : .button
        }
    }

    /// The name of what is shown: the small pill's, while gathered.
    func setTitle(_ names: [String]) {
        smallTitle.names = names
        setNeedsLayout()
    }

    private weak var smallTap: UITapGestureRecognizer?

    @objc private func tappedSmall() {
        guard isSmall else { return }
        setSmall(false)
    }

    // MARK: Gathered small

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

    private var rowMarks: [UIView] { Self.lenses.compactMap { lensButtons[$0] } + [writeButton] }

    private func place() {
        let width = bounds.width, height = bounds.height, inset = Self.inset
        smallTap?.isEnabled = isSmall
        if isSmall {
            let words = ceil(((smallTitle.names.first ?? "") as NSString).size(withAttributes: [.font: smallTitle.font as Any]).width)
            let w = min(max(words + 40, 120), width - 2 * Self.side)
            panel.frame = CGRect(x: ((width - w) / 2).rounded(), y: height - Self.smallHeight + Self.smallDrop, width: w, height: Self.smallHeight)
            panel.cornerConfiguration = .capsule()
            well.frame = panel.bounds
            well.backgroundColor = .clear
            well.layer.cornerRadius = Self.smallHeight / 2
            smallTitle.frame = well.bounds.insetBy(dx: 14, dy: 0)
            smallTitle.alpha = 1
            wellButton.isUserInteractionEnabled = false
            for view in [magnifier, placeholder, field, closeButton] as [UIView] { view.alpha = 0 }
            // The lenses drawn in with the glass, evenly, as they fade — not left where they were.
            let marks = rowMarks
            let slot = w / CGFloat(marks.count)
            for (i, mark) in marks.enumerated() {
                mark.frame = CGRect(x: CGFloat(i) * slot, y: Self.smallHeight - 8, width: slot, height: Self.smallHeight)
                mark.alpha = 0
            }
            placeBubble(width: width)
            return
        }
        panel.cornerConfiguration = .uniformCorners(radius: .fixed(Self.radius))
        well.backgroundColor = Ink.text.withAlphaComponent(0.06)
        wellButton.isUserInteractionEnabled = !isSearching
        let panelHeight = isSearching ? Self.searchHeight : Self.height
        panel.frame = CGRect(x: Self.side, y: height - panelHeight, width: width - 2 * Self.side, height: panelHeight)
        let inner = panel.bounds.width
        let closeSide: CGFloat = 40
        well.frame = CGRect(x: inset, y: inset, width: inner - 2 * inset - (isSearching ? closeSide : 0), height: Self.fieldHeight)
        well.layer.cornerRadius = Self.fieldHeight / 2
        closeButton.frame = CGRect(x: inner - inset - closeSide, y: inset, width: closeSide, height: Self.fieldHeight)
        closeButton.alpha = isSearching ? 1 : 0
        let fieldBounds = well.bounds
        // The name of what is shown, in the field, as an address is — its
        // magnifier only while searching, or with no name to show.
        let titled = !(smallTitle.names.first ?? "").isEmpty
        magnifier.frame = CGRect(x: 10, y: 0, width: 24, height: fieldBounds.height)
        magnifier.alpha = isSearching || !titled ? 1 : 0
        placeholder.frame = CGRect(x: 38, y: 0, width: max(0, fieldBounds.width - 46), height: fieldBounds.height)
        placeholder.alpha = isSearching || titled ? 0 : 1
        smallTitle.frame = fieldBounds.insetBy(dx: 16, dy: 0)
        smallTitle.alpha = !isSearching && titled ? 1 : 0
        wellButton.frame = fieldBounds
        field.frame = CGRect(x: 38, y: 0, width: max(0, fieldBounds.width - 46), height: fieldBounds.height)
        field.alpha = isSearching ? 1 : 0
        // The lenses, evenly along the row under the field; + last.
        let rowY = inset + Self.fieldHeight, rowHeight = Self.height - rowY - 2
        let marks = rowMarks
        let slot = (inner - 2 * inset) / CGFloat(marks.count)
        for (i, mark) in marks.enumerated() {
            mark.frame = CGRect(x: inset + CGFloat(i) * slot, y: rowY, width: slot, height: rowHeight)
            mark.alpha = isSearching ? 0 : 1
        }
        placeBubble(width: width)
    }

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

    func width(within room: CGFloat) -> CGFloat {
        names.lazy.map(measure).first { $0 <= room } ?? room
    }
}
