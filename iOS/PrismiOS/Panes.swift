import UIKit
import ReflectCore
import PrismCore

/// What a place is called at the top of its pane: a day as it is to today
/// — Today, Yesterday, a weekday this week, else its date — its whole date
/// under; a week by its number, its days under; a note by its title.
@MainActor
enum PlaceNames {
    static func title(_ path: String, store: PrismStore) -> (title: String, detail: String?) {
        if let day = GraphPaths.day(fromDailyPath: path), let date = day.date {
            let today = Day.today
            let title: String
            switch day {
            case today: title = "Today"
            case today.adding(-1): title = "Yesterday"
            case today.adding(1): title = "Tomorrow"
            default:
                let near = (today.adding(-6)...today.adding(6)).contains(day)
                title = Formats.date(near ? "EEEE" : day.year == today.year ? "MMMMd" : "MMMMdyyyy").string(from: date)
            }
            return (title, Formats.date(day.year == today.year ? "EEEEMMMMd" : "EEEEMMMMdyyyy").string(from: date))
        }
        if let week = GraphPaths.week(fromWeeklyPath: path) {
            let range = week.monday.flatMap { first in
                week.sunday.flatMap { last in first.date.flatMap { a in last.date.map { b in Formats.interval("MMMd").string(from: a, to: b) } } }
            }
            return ("Week \(week.week)", range)
        }
        return (SliceBlock.name(path, store: store), nil)
    }
}

// MARK: - The pane's controls

extension Notification.Name {
    /// Read down into a page: the floating controls out of the way — or, read back up, in again.
    static let prismChromeHidden = Notification.Name("PrismChromeHidden")
}

/// Over every pane, floating on glass, the same in the same places: at the
/// left, back — and forward, when there is a way forward; at the right, a
/// day's two faces, how many link to what is shown, and ⋯. What is shown is
/// named in the bar at the foot, not here. Read down into the page, they go;
/// read back up, they come again. Back held: the way back, to go to any of it.
final class PaneBar: UIView {
    /// The room the controls take over the page, under the clock.
    static let height: CGFloat = 52
    private static let capsule: CGFloat = 44

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onLinked: (() -> Void)?
    var onFace: ((DayFace) -> Void)?
    /// The ⋯, asked for each time it opens.
    var menu: (() -> UIMenu)?
    /// Back held: where it would go back to.
    var backMenu: (() -> UIMenu?)?

    private static func glass() -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIGlassEffect())
        view.cornerConfiguration = .capsule()
        return view
    }
    private let leading = PaneBar.glass()
    private let trailing = PaneBar.glass()
    private let back = UIButton(type: .system)
    private let forward = UIButton(type: .system)
    private let faces = UISegmentedControl(items: [
        UIImage(systemName: "text.alignleft") as Any, UIImage(systemName: "calendar.day.timeline.left") as Any,
    ])
    private let linked = UIButton(type: .system)
    private let more = UIButton(type: .system)
    private(set) var isTucked = false

    var showsBack = false { didSet { setNeedsLayout() } }
    var canGoForward = false { didSet { setNeedsLayout() } }
    /// A day's face, when it has two: nil, none to choose.
    var face: DayFace? {
        didSet {
            if let face { faces.selectedSegmentIndex = face == .outline ? 0 : 1 }
            setNeedsLayout()
        }
    }
    /// How many notes link to what is shown: nil, not said.
    var linkedCount: Int? {
        didSet {
            var style = linked.configuration
            style?.attributedTitle = AttributedString("\(linkedCount ?? 0)", attributes: AttributeContainer([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            ]))
            linked.configuration = style
            linked.accessibilityValue = linkedCount == 1 ? "1 note" : "\(linkedCount ?? 0) notes"
            setNeedsLayout()
        }
    }

    private static func mark(_ name: String, size: CGFloat = 18) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .regular))
    }

    init() {
        super.init(frame: .zero)
        back.setImage(Self.mark("chevron.left", size: 18), for: .normal)
        back.accessibilityLabel = "Back"
        back.addAction(UIAction { [weak self] _ in self?.onBack?() }, for: .touchUpInside)
        back.addInteraction(UIContextMenuInteraction(delegate: self))
        forward.setImage(Self.mark("chevron.right", size: 18), for: .normal)
        forward.accessibilityLabel = "Forward"
        forward.addAction(UIAction { [weak self] _ in self?.onForward?() }, for: .touchUpInside)
        faces.selectedSegmentIndex = 0
        faces.accessibilityLabel = "Outline or Schedule"
        faces.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            onFace?(faces.selectedSegmentIndex == 0 ? .outline : .schedule)
        }, for: .valueChanged)
        var linksStyle = UIButton.Configuration.plain()
        linksStyle.image = Self.mark("arrow.turn.up.left", size: 15)
        linksStyle.imagePadding = 4
        linksStyle.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 4)
        linked.configuration = linksStyle
        linked.accessibilityLabel = "Linked From"
        linked.addAction(UIAction { [weak self] _ in self?.onLinked?() }, for: .touchUpInside)
        more.setImage(Self.mark("ellipsis"), for: .normal)
        more.accessibilityLabel = "More"
        more.showsMenuAsPrimaryAction = true
        more.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in
            done(self?.menu?().children ?? [])
        }])
        for view in [back, forward, linked, more] as [UIView] { view.tintColor = Ink.text }
        addSubview(leading)
        addSubview(trailing)
        for view in [back, forward] as [UIView] { leading.contentView.addSubview(view) }
        for view in [faces, linked, more] as [UIView] { trailing.contentView.addSubview(view) }
        NotificationCenter.default.addObserver(self, selector: #selector(chromeHidden(_:)), name: .prismChromeHidden, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What is shown, said aloud: the bar at the foot shows it.
    func show(title text: String, detail words: String?) {
        accessibilityLabel = [text, words].compactMap { $0 }.joined(separator: ", ")
    }

    /// Its row's top: under the clock.
    var top: CGFloat = 0 { didSet { if top != oldValue { setNeedsLayout() } } }
    /// Where a page starts: under the clock — the controls float over its top.
    var contentTop: CGFloat { top }

    @objc private func chromeHidden(_ note: Notification) {
        setTucked(note.object as? Bool ?? false)
    }

    /// Out of the way, read down into the page; back, read up.
    func setTucked(_ tucked: Bool, animated: Bool = true) {
        guard tucked != isTucked else { return }
        isTucked = tucked
        let change = {
            for capsule in [self.leading, self.trailing] {
                capsule.alpha = tucked ? 0 : 1
                capsule.transform = tucked ? CGAffineTransform(translationX: 0, y: -12).scaledBy(x: 0.92, y: 0.92) : .identity
            }
        }
        guard animated else { return change() }
        UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = Self.capsule
        let y = top + (Self.height - side) / 2
        let transforms = [leading.transform, trailing.transform]
        leading.transform = .identity
        trailing.transform = .identity
        defer {
            leading.transform = transforms[0]
            trailing.transform = transforms[1]
        }
        // At the left: back, and forward after it.
        var x: CGFloat = 0
        back.isHidden = !showsBack
        if showsBack {
            back.frame = CGRect(x: x, y: 0, width: side, height: side)
            x = back.frame.maxX
        }
        forward.isHidden = !canGoForward
        if canGoForward {
            forward.frame = CGRect(x: x - (showsBack ? 6 : 0), y: 0, width: side, height: side)
            x = forward.frame.maxX
        }
        leading.isHidden = x == 0
        leading.frame = CGRect(x: 16, y: y, width: x, height: side)
        // At the right: the faces, how many link here, ⋯ — in that order.
        var width: CGFloat = 4
        faces.isHidden = face == nil
        if !faces.isHidden {
            faces.frame = CGRect(x: width + 2, y: (side - 32) / 2, width: 84, height: 32)
            width = faces.frame.maxX + 2
        }
        linked.isHidden = linkedCount == nil || linkedCount == 0
        if !linked.isHidden {
            let w = linked.intrinsicContentSize.width
            linked.frame = CGRect(x: width, y: 0, width: w, height: side)
            width = linked.frame.maxX
        }
        more.frame = CGRect(x: width, y: 0, width: 40, height: side)
        width = more.frame.maxX + 2
        trailing.frame = CGRect(x: bounds.width - 16 - width, y: y, width: width, height: side)
    }

    /// Only the controls are the bar's, to the touch: the page under the rest.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard !isTucked else { return false }
        return (!leading.isHidden && leading.frame.insetBy(dx: -4, dy: -4).contains(point)) || trailing.frame.insetBy(dx: -4, dy: -4).contains(point)
    }
}

extension PaneBar: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = backMenu?() else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }
}

// MARK: - A note's pane

/// A note, as a pane shows it — or a day, as its outline or its hours —
/// with its own way back and forward, as a browser's tab has: a link
/// followed goes on in the pane; back goes back, and from where it began,
/// out of the pane.
final class NoteController: UIViewController {
    let store: PrismStore
    private(set) var history: PaneHistory
    let bar = PaneBar()
    /// What shows the place: a note's sheet, or a day's hours.
    private(set) var page: UIViewController?
    /// Makes what shows a place, links followed from it brought back here.
    private let makePage: (PanePlace, @escaping (PanePlace, Int?) -> Void) -> UIViewController
    /// The ⋯'s menu for a place.
    var menu: ((PanePlace) -> UIMenu)?
    /// Back from where it began: out of the pane — nil, nowhere to go.
    var onLeave: (() -> Void)?
    /// Where it is changed: the bar, and what is kept, again.
    var onChange: (() -> Void)?

    init(store: PrismStore, history: PaneHistory, makePage: @escaping (PanePlace, @escaping (PanePlace, Int?) -> Void) -> UIViewController) {
        self.store = store
        self.history = history
        self.makePage = makePage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var place: PanePlace { history.current }
    var sheet: SheetController? { page as? SheetController }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        view.addSubview(bar)
        bar.onBack = { [weak self] in self?.back() }
        bar.onForward = { [weak self] in self?.goForward() }
        bar.onLinked = { [weak self] in self?.sheet?.scrollToLinked() }
        bar.onFace = { [weak self] face in
            guard let self else { return }
            var place = history.current
            place.face = face
            history.replace(place)
            show()
        }
        bar.menu = { [weak self] in
            guard let self else { return UIMenu() }
            return menu?(history.current) ?? UIMenu()
        }
        bar.backMenu = { [weak self] in self?.backMenu() }
        show()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        bar.top = top
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + PaneBar.height)
        // From under the clock: the controls float over its top.
        page?.view.frame = CGRect(x: 0, y: bar.contentTop, width: view.bounds.width, height: view.bounds.height - bar.contentTop)
        view.bringSubviewToFront(bar)
    }

    /// Somewhere new, in this pane: where it was kept behind it.
    func go(_ place: PanePlace, row: Int? = nil) {
        guard place != history.current else {
            if let row { sheet?.mark(unfoldedRow: row) }
            return
        }
        sheet?.saveAll()
        history.go(place)
        show(row: row)
    }

    /// Back: in the pane, or out of it.
    func back() {
        guard history.canGoBack else { return onLeave?() ?? () }
        sheet?.saveAll()
        history.goBack()
        show()
    }

    func goForward() {
        guard history.canGoForward else { return }
        sheet?.saveAll()
        history.goForward()
        show()
    }

    /// The way back, held: each place, the nearest first.
    private func backMenu() -> UIMenu? {
        guard history.canGoBack else { return nil }
        let places = Array(history.back.enumerated().reversed())
        return UIMenu(children: places.prefix(12).map { offset, place in
            UIAction(title: PlaceNames.title(place.path, store: store).title) { [weak self] _ in
                guard let self else { return }
                sheet?.saveAll()
                for _ in 0..<(history.back.count - offset) { history.goBack() }
                show()
            }
        })
    }

    /// The place shown, its page made afresh.
    private func show(row: Int? = nil) {
        let place = history.current
        if let old = page {
            (old as? SheetController)?.saveAll()
            (old as? SheetController)?.settle()
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        let made = makePage(place) { [weak self] place, row in self?.go(place, row: row) }
        addChild(made)
        made.additionalSafeAreaInsets.top = PaneBar.height
        view.insertSubview(made.view, belowSubview: bar)
        made.didMove(toParent: self)
        page = made
        if let sheet = made as? SheetController {
            sheet.onLinkedCount = { [weak self] count in self?.bar.linkedCount = count }
            if let row { sheet.mark(unfoldedRow: row) }
        }
        let names = PlaceNames.title(place.path, store: store)
        bar.show(title: names.title, detail: names.detail)
        bar.showsBack = history.canGoBack || onLeave != nil
        bar.canGoForward = history.canGoForward
        bar.face = GraphPaths.day(fromDailyPath: place.path) != nil ? place.face : nil
        bar.linkedCount = nil
        view.setNeedsLayout()
        onChange?()
    }

    /// Its whole way back and forward, set — where it is, the same.
    func setHistory(_ history: PaneHistory) {
        self.history = history
        bar.showsBack = history.canGoBack || onLeave != nil
        bar.canGoForward = history.canGoForward
        onChange?()
    }

    /// The bar's name again: the note renamed, or its title typed.
    func refreshTitle() {
        let names = PlaceNames.title(history.current.path, store: store)
        bar.show(title: names.title, detail: names.detail)
    }

    /// A note gone — deleted — out of the way back; shown, back past it.
    func forget(_ path: String) {
        history.forget(path)
        if history.current.path == path {
            if history.canGoBack { history.goBack(); show() } else { onLeave?() }
        }
    }
}
