import UIKit
import ReflectCore
import PrismCore

/// A view that shows one note at a time — the days, a page each; the inbox
/// and the pinned, a list of them over the one chosen — each note a sheet of
/// its own, read and written as any note is.
@MainActor
protocol NoteHost: UIViewController {
    /// What it is, among a column's sheets: what is kept, to open again.
    var rootKind: SheetKind { get }
    /// The note shown.
    var sheet: SheetController? { get }
    /// Every note sheet it holds — the one shown, and those beside it.
    var sheets: [SheetController] { get }
    /// Notes changed: what it lists, again.
    func notesChanged(_ paths: Set<String>)
    /// Told when the note shown changes: the bar, as it is.
    var onShownChange: (() -> Void)? { get set }
}

// MARK: - The days

/// The days, one at a time, as a day planner has them: today headed large,
/// its date over it; swiped across, the day before or after; pulled down at
/// its top, the month over it, to go to any day.
final class DayPager: UIViewController, NoteHost, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    let rootKind = SheetKind.timeline
    var onShownChange: (() -> Void)?
    /// A day's sheet, made as the column makes its sheets.
    private let makeSheet: (SheetKind) -> SheetController
    /// The month, made for a day: nil without a graph.
    private let makeCalendar: (Day) -> CalendarController?

    private let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 0])
    private(set) var day: Day
    /// The days' sheets made, kept a while: those near, to swipe to.
    private var made: [Day: SheetController] = [:]

    init(day: Day = .today, makeSheet: @escaping (SheetKind) -> SheetController, makeCalendar: @escaping (Day) -> CalendarController?) {
        self.day = day
        self.makeSheet = makeSheet
        self.makeCalendar = makeCalendar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var sheet: SheetController? { pages.viewControllers?.first as? SheetController }
    var sheets: [SheetController] { Array(made.values) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        pages.dataSource = self
        pages.delegate = self
        addChild(pages)
        view.addSubview(pages.view)
        pages.didMove(toParent: self)
        pages.setViewControllers([page(for: day)], direction: .forward, animated: false)
        // The page cards as it is pulled down from the month: its corners round.
        pages.view.layer.cornerCurve = .continuous
        pages.view.clipsToBounds = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if over == .none { pages.view.frame = view.bounds }
    }

    func notesChanged(_ paths: Set<String>) {}

    /// The sheet of a day: made once, kept while near the day shown.
    private func page(for day: Day) -> SheetController {
        if let sheet = made[day] { return sheet }
        let sheet = makeSheet(.note(GraphPaths.dailyPath(for: day)))
        sheet.allowsBacklinkSwipe = false
        sheet.onPullDown = { [weak self] in self?.pulledDown() }
        made[day] = sheet
        return sheet
    }

    private func day(of controller: UIViewController) -> Day? {
        guard let sheet = controller as? SheetController, case .note(let path) = sheet.kind else { return nil }
        return GraphPaths.day(fromDailyPath: path)
    }

    /// A day, gone to: turned to, the way it lies from the one shown.
    func show(_ day: Day, animated: Bool = true) {
        guard day != self.day || sheet == nil else { return }
        let forward = day > self.day
        self.day = day
        pages.setViewControllers([page(for: day)], direction: forward ? .forward : .reverse, animated: animated && isViewLoaded) { [weak self] _ in
            self?.forgetFar()
        }
        onShownChange?()
    }

    /// Days far from the one shown: let go, written first.
    private func forgetFar() {
        for (other, sheet) in made where abs(Calendar.current.dateComponents([.day], from: other.date ?? Date(), to: day.date ?? Date()).day ?? 0) > 2 {
            sheet.saveAll()
            made[other] = nil
        }
    }

    func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        day(of: viewController).map { page(for: $0.adding(-1)) }
    }

    func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        day(of: viewController).map { page(for: $0.adding(1)) }
    }

    func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let shown = controller.viewControllers?.first, let day = day(of: shown) else { return }
        for previous in previousViewControllers { (previous as? SheetController)?.saveAll() }
        self.day = day
        UISelectionFeedbackGenerator().selectionChanged()
        forgetFar()
        onShownChange?()
    }

    // MARK: The week, and the month, over the day

    /// What shows over the day, pulled down to: nothing; the week; the month.
    private enum Over { case none, week, month }
    private var over = Over.none
    private var calendar: CalendarController?
    private var strip: WeekStripView?
    private var closer: UIControl?
    /// The days with notes, marked: for the week over the day.
    var marks: () -> [Day: NoteCalendar.Mark] = { [:] }

    /// Pulled down once, the week over the day; again, the month; let go of
    /// either way up, or tapped, the day again.
    func pulledDown() {
        switch over {
        case .none: show(.week)
        case .week: show(.month)
        case .month: break
        }
    }

    func showCalendar(_ shown: Bool) { show(shown ? .month : .none) }

    private func show(_ next: Over) {
        guard next != over else { return }
        let top = view.safeAreaInsets.top
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // What was over the day, gone.
        let oldStrip = strip, oldCalendar = calendar
        strip = nil
        calendar = nil
        var height: CGFloat = 0
        switch next {
        case .none:
            break
        case .week:
            let strip = WeekStripView(day: day, marks: marks())
            strip.onChoose = { [weak self] day in
                self?.show(day, animated: false)
                self?.show(.none)
            }
            strip.onMonth = { [weak self] in self?.show(.month) }
            height = WeekStripView.height
            strip.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: height)
            strip.alpha = 0
            view.insertSubview(strip, belowSubview: pages.view)
            self.strip = strip
        case .month:
            guard let calendar = makeCalendar(day) else { return }
            calendar.onChoose = { [weak self] day in
                self?.show(day, animated: false)
                self?.show(.none)
            }
            addChild(calendar)
            view.insertSubview(calendar.view, belowSubview: pages.view)
            calendar.didMove(toParent: self)
            calendar.view.backgroundColor = .clear
            height = calendar.preferredHeight(width: view.bounds.width)
            calendar.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: height)
            calendar.view.alpha = 0
            self.calendar = calendar
        }
        over = next
        // The day, a card under what is over it: tapped, or swiped up, the
        // day again; swiped down, the month.
        if next == .none {
            closer?.removeFromSuperview()
            closer = nil
        } else if closer == nil {
            let closer = UIControl(frame: pages.view.bounds)
            closer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            closer.addAction(UIAction { [weak self] _ in self?.show(.none) }, for: .touchUpInside)
            let up = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp))
            up.direction = .up
            closer.addGestureRecognizer(up)
            let down = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
            down.direction = .down
            closer.addGestureRecognizer(down)
            pages.view.addSubview(closer)
            self.closer = closer
            view.backgroundColor = Ink.shelf
            pages.view.backgroundColor = Ink.paper
            pages.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
            self.pages.view.frame = next == .none ? self.view.bounds
                : CGRect(x: 0, y: top + height, width: self.view.bounds.width, height: self.view.bounds.height - top - height)
            self.pages.view.layer.cornerRadius = next == .none ? 0 : 32
            self.strip?.alpha = 1
            self.calendar?.view.alpha = 1
            oldStrip?.alpha = 0
            oldCalendar?.view.alpha = 0
        } completion: { _ in
            oldStrip?.removeFromSuperview()
            if let oldCalendar {
                oldCalendar.willMove(toParent: nil)
                oldCalendar.view.removeFromSuperview()
                oldCalendar.removeFromParent()
            }
            if self.over == .none { self.view.backgroundColor = Ink.page }
        }
    }

    @objc private func swipedUp() { show(.none) }
    @objc private func swipedDown() { pulledDown() }
}

// MARK: - A list of notes, over the one chosen

/// The inbox, or the pinned notes: each in a line or two at the top — its
/// cover, its name, its first words, how long since — and under them, the one
/// chosen, whole, to read and write. Read down into it, the list goes; pulled
/// down at its top, the list comes back.
final class NoteListController: UIViewController, NoteHost {
    let rootKind: SheetKind
    var onShownChange: (() -> Void)?
    private let store: PrismStore
    private let makeSheet: (SheetKind) -> SheetController

    private let list = UIScrollView()
    private var rows: [NoteSummaryRow] = []
    private let rule = UIView()
    private let empty = UILabel()
    private var paths: [String] = []
    private var selected: String?
    private(set) var sheet: SheetController?
    var sheets: [SheetController] { sheet.map { [$0] } ?? [] }
    /// Whether the list shows over the note.
    private var listShown = true

    init(kind: SheetKind, store: PrismStore, makeSheet: @escaping (SheetKind) -> SheetController) {
        rootKind = kind
        self.store = store
        self.makeSheet = makeSheet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        list.alwaysBounceVertical = true
        list.showsVerticalScrollIndicator = false
        list.contentInsetAdjustmentBehavior = .never
        view.addSubview(list)
        rule.backgroundColor = Ink.rule
        view.addSubview(rule)
        empty.text = rootKind == .inbox ? "Nothing to deal with" : "Pin a note from its ⋯ menu"
        empty.font = Typeface.current.body(17)
        empty.textColor = Ink.secondary
        empty.textAlignment = .center
        view.addSubview(empty)
        reload()
    }

    func notesChanged(_ paths: Set<String>) { reload() }

    /// What it lists, as the index now has it: the one chosen kept, if still
    /// there; else the first.
    private func reload() {
        guard isViewLoaded, let index = store.index else { return }
        let now = (rootKind == .inbox ? index.inbox : index.pinned).map(\.path)
        if now != paths {
            paths = now
            rows.forEach { $0.removeFromSuperview() }
            rows = paths.map { path in
                let row = NoteSummaryRow(path: path, store: store)
                row.addAction(UIAction { [weak self] _ in self?.choose(path) }, for: .touchUpInside)
                list.addSubview(row)
                return row
            }
        } else {
            rows.forEach { $0.refresh() }
        }
        if selected == nil || !paths.contains(selected!) { choose(paths.first, animated: false) }
        empty.isHidden = !paths.isEmpty
        markSelected()
        view.setNeedsLayout()
    }

    /// A note chosen from the list: shown under it, the one before written.
    private func choose(_ path: String?, animated: Bool = true) {
        guard path != selected || sheet == nil else { return }
        selected = path
        if let old = sheet {
            old.saveAll()
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
            sheet = nil
        }
        if let path {
            let shown = makeSheet(.note(path))
            // Read down into it, the list goes; pulled down at its top, it comes back.
            let chrome = shown.onChromeHidden
            shown.onChromeHidden = { [weak self] hidden in
                chrome?(hidden)
                if hidden { self?.showList(false) }
            }
            shown.onPullDown = { [weak self] in self?.showList(true) }
            addChild(shown)
            view.insertSubview(shown.view, belowSubview: rule)
            shown.didMove(toParent: self)
            sheet = shown
            if animated { UISelectionFeedbackGenerator().selectionChanged() }
        }
        markSelected()
        view.setNeedsLayout()
        onShownChange?()
    }

    private func markSelected() {
        for (row, path) in zip(rows, paths) { row.isChosen = path == selected }
    }

    /// The list over the note, or gone, the note the whole height.
    func showList(_ shown: Bool) {
        guard shown != listShown else { return }
        listShown = shown
        UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.layout()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layout()
    }

    private func layout() {
        let width = view.bounds.width, top = view.safeAreaInsets.top
        let rowsHeight = CGFloat(rows.count) * NoteSummaryRow.height
        var y: CGFloat = 0
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: width, height: NoteSummaryRow.height)
            y += NoteSummaryRow.height
        }
        list.contentSize = CGSize(width: width, height: rowsHeight + 8)
        let listHeight = listShown && !paths.isEmpty ? min(rowsHeight + 8, (view.bounds.height - top) * 0.38) : 0
        list.frame = CGRect(x: 0, y: top, width: width, height: listHeight)
        list.alpha = listShown ? 1 : 0
        rule.frame = CGRect(x: 0, y: top + listHeight, width: width, height: listHeight > 0 ? 1 / max(view.traitCollection.displayScale, 1) : 0)
        sheet?.view.frame = CGRect(x: 0, y: listHeight > 0 ? top + listHeight : 0, width: width,
                                   height: view.bounds.height - (listHeight > 0 ? top + listHeight : 0))
        empty.frame = CGRect(x: 20, y: top + 60, width: width - 40, height: 30)
        sheet?.view.layoutIfNeeded()
    }
}

// MARK: - A note in a line or two

/// A note, short: its cover — or a note's mark — small and square, its name,
/// its first words, and how long since it changed. As a list shows notes to
/// choose among.
final class NoteSummaryRow: UIControl {
    static let height: CGFloat = 66

    let path: String
    private let store: PrismStore
    private let picture = UIImageView()
    private let name = UILabel()
    private let words = UILabel()
    private let age = UILabel()

    var isChosen = false { didSet { backgroundColor = isChosen ? Ink.hover : .clear } }

    init(path: String, store: PrismStore) {
        self.path = path
        self.store = store
        super.init(frame: .zero)
        picture.contentMode = .scaleAspectFill
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 6
        picture.layer.cornerCurve = .continuous
        picture.tintColor = Ink.secondary
        name.font = Typeface.current.heading(16, weight: .semibold)
        name.textColor = Ink.text
        words.font = Typeface.current.body(14)
        words.textColor = Ink.secondary
        for view in [picture, name, words, age] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        refresh()
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// As the note now is.
    func refresh() {
        let text = store.text(path)
        name.text = SliceBlock.name(path, store: store)
        words.text = Self.firstWords(of: text)
        age.attributedText = NSAttributedString(string: (Card.meta(for: path, store: store) ?? "").uppercased(),
                                                attributes: Card.label(size: 15))
        if let cover = NoteCover.source(in: text).flatMap({ PhoneImages.thumbnail($0, side: 44) }) {
            picture.image = cover
            picture.contentMode = .scaleAspectFill
            picture.backgroundColor = .clear
        } else {
            picture.image = UIImage(systemName: "doc.text", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .regular))
            picture.contentMode = .center
            picture.backgroundColor = Ink.text.withAlphaComponent(0.05)
        }
        accessibilityLabel = [name.text, words.text].compactMap { $0 }.joined(separator: ", ")
        setNeedsLayout()
    }

    /// What it says first: its first row with words in it, not its title.
    private static func firstWords(of text: String) -> String {
        let rows = OutlineMarkdown.parse(text).rows
        let shown = rows.lazy.map { InlineMarkup.plainText($0.text).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let entryTitle = rows.first.map { InlineMarkup.plainText($0.text) }
        let first = { if case .heading = rows.first?.kind { return true } else { return false } }() ? shown.dropFirst().first : shown.first
        return first ?? (entryTitle ?? "")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side: CGFloat = 44, x: CGFloat = 20
        picture.frame = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side)
        let ageSize = age.intrinsicContentSize
        age.frame = CGRect(x: bounds.width - 20 - ageSize.width, y: 15, width: ageSize.width, height: ageSize.height)
        let textX = picture.frame.maxX + 14
        name.frame = CGRect(x: textX, y: 12, width: age.frame.minX - 10 - textX, height: 21)
        words.frame = CGRect(x: textX, y: 34, width: bounds.width - 20 - textX, height: 19)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? Ink.rule : isChosen ? Ink.hover : .clear }
    }
}

// MARK: - The week, as a strip

/// A week's seven days in a row: the day shown filled, today in the accent,
/// those with notes marked — a ring for how far their to-dos are along, else
/// a dot. Swiped across, a week along; a day tapped, gone to; the calendar's
/// mark, the month.
final class WeekStripView: UIView {
    static let height: CGFloat = 108
    var onChoose: ((Day) -> Void)?
    var onMonth: (() -> Void)?

    private let shown: Day
    private var days: [Day]
    private let marks: [Day: NoteCalendar.Mark]
    private let title = UILabel()
    private let month = UIButton(type: .system)

    init(day: Day, marks: [Day: NoteCalendar.Mark]) {
        shown = day
        days = NoteCalendar.week(of: day)
        self.marks = marks
        super.init(frame: .zero)
        backgroundColor = .clear
        title.font = Typeface.current.heading(17, weight: .bold)
        title.textColor = Ink.text
        addSubview(title)
        month.setImage(UIImage(systemName: "calendar", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)),
                       for: .normal)
        month.tintColor = Ink.text
        month.accessibilityLabel = "The Month"
        month.addAction(UIAction { [weak self] _ in self?.onMonth?() }, for: .touchUpInside)
        addSubview(month)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
        showTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func showTitle() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        title.text = days[3].date.map(formatter.string(from:))
        setNeedsDisplay()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let step = gesture.direction == .left ? 7 : -7
        days = days.map { $0.adding(step) }
        UISelectionFeedbackGenerator().selectionChanged()
        showTitle()
    }

    private func cell(_ i: Int) -> CGRect {
        let inset: CGFloat = 16, width = (bounds.width - 2 * inset) / 7
        return CGRect(x: inset + CGFloat(i) * width, y: 40, width: width, height: 52)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let i = days.indices.first(where: { cell($0).contains(point) }) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onChoose?(days[i])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 24, y: 6, width: bounds.width - 100, height: 26)
        month.frame = CGRect(x: bounds.width - 60, y: 0, width: 44, height: 38)
    }

    override func draw(_ rect: CGRect) {
        let today = Day.today
        let symbols = NoteCalendar.weekdaySymbols()
        let label = Card.label(size: 15)
        for (i, day) in days.enumerated() {
            let cell = cell(i)
            let letter = NSAttributedString(string: symbols[i].uppercased(), attributes: label)
            letter.draw(at: CGPoint(x: (cell.midX - letter.size().width / 2).rounded(), y: cell.minY))
            let center = CGPoint(x: cell.midX, y: cell.minY + 32)
            let mark = marks[day]
            let chosen = day == shown
            if chosen {
                Ink.text.setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)).fill()
            } else if let progress = mark?.progress {
                ProgressRing.image(progress, side: 30).draw(in: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30))
            }
            let color: UIColor = chosen ? Ink.paper : day == today ? Ink.accent : mark != nil ? Ink.text : Ink.faint
            let number = NSAttributedString(string: "\(day.day)", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: chosen || day == today || mark != nil ? .semibold : .regular),
                .foregroundColor: color,
            ])
            let size = number.size()
            number.draw(at: CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded()))
            if mark != nil, mark?.progress == nil, !chosen {
                (day == today ? Ink.accent : Ink.secondary).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - 2, y: center.y + 11, width: 4, height: 4)).fill()
            }
        }
    }
}
