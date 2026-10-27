import UIKit
import ReflectCore
import PrismCore

/// Daily: the days, one at a time, as a day planner has them — swiped
/// across, the day before or after; pulled down under the bar, the week,
/// and the month past it, to go to any day. Each day has two faces, chosen
/// in the bar: its note, or its hours with its time blocks down them.
final class DayPager: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    private let store: PrismStore
    /// What shows a place — a day's note, its hours, a week's note — links
    /// followed from it opened where they go.
    private let makePage: (PanePlace, @escaping (PanePlace, Int?) -> Void) -> UIViewController
    /// A link followed from a day: opened beside, or over it.
    var onOpen: ((PanePlace, Int?) -> Void)?
    /// The month, made for a day: nil without a graph.
    var makeCalendar: ((Day) -> CalendarController?)?
    var menu: ((PanePlace) -> UIMenu)?
    /// The day shown changed: the bottom bar's name, and what is kept.
    var onChange: (() -> Void)?

    let bar = PaneBar()
    private let linkedFan = LinkedFan()
    private let pages = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                             options: [.interPageSpacing: 0])
    private(set) var day: Day
    private(set) var face: DayFace
    /// The days' pages made, kept a while: those near, to swipe to.
    private var made: [String: UIViewController] = [:]

    init(store: PrismStore, day: Day = .today, face: DayFace = .outline,
         makePage: @escaping (PanePlace, @escaping (PanePlace, Int?) -> Void) -> UIViewController) {
        self.store = store
        self.day = day
        self.face = face
        self.makePage = makePage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The page shown, as a note's sheet — not a day's hours.
    var sheet: SheetController? { pages.viewControllers?.first as? SheetController }
    var schedule: ScheduleController? { pages.viewControllers?.first as? ScheduleController }
    var shownPages: [UIViewController] { Array(made.values) + (weekPage.map { [$0.page] } ?? []) }

    /// Where it is: the day, or the week, and its face.
    var place: PanePlace {
        if let week { return PanePlace(path: GraphPaths.weeklyPath(for: week)) }
        return PanePlace(path: GraphPaths.dailyPath(for: day), face: face)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.page
        pages.dataSource = self
        pages.delegate = self
        addChild(pages)
        view.addSubview(pages.view)
        pages.didMove(toParent: self)
        // The controls float over the day's top: it starts under them, and scrolls up under them.
        pages.additionalSafeAreaInsets.top = PaneBar.height
        pages.setViewControllers([page(for: day)], direction: .forward, animated: false)
        pages.view.layer.cornerCurve = .continuous
        pages.view.clipsToBounds = true
        pages.view.addGestureRecognizer(pull)
        view.addSubview(bar)
        bar.onFace = { [weak self] face in self?.setFace(face) }
        bar.onLinked = { [weak self] in self?.sheet?.scrollToLinked() }
        bar.onLinkedHeld = { [weak self] state, point in
            guard let self else { return }
            linkedFan.held(state, at: point, bar: bar, in: view, store: store, paths: sheet?.linkedPaths ?? [],
                           open: { [weak self] path in self?.onOpen?(PanePlace(path: path), nil) },
                           showAll: { [weak self] in self?.sheet?.scrollToLinked() })
        }
        bar.menu = { [weak self] in
            guard let self else { return UIMenu() }
            return menu?(place) ?? UIMenu()
        }
        showName()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        bar.top = top
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + PaneBar.height)
        view.bringSubviewToFront(bar)
        place(reveal)
    }

    func notesChanged(_ paths: Set<String>) {
        showName()
        strip?.marks = marks()
    }

    /// The bar, as the day shown is: its name, its face, how many link to it.
    private func showName() {
        let names = PlaceNames.title(place.path, store: store)
        bar.show(title: names.title, detail: names.detail)
        bar.face = week == nil ? face : nil
        bar.linkedCount = sheet?.linkedCount
        onChange?()
    }

    // MARK: Faces

    /// The note, or the hours: the same day turned to its other face.
    func setFace(_ face: DayFace) {
        guard face != self.face else { return }
        sheet?.saveAll()
        self.face = face
        guard week == nil else { return }
        pages.setViewControllers([page(for: day)], direction: .forward, animated: false)
        showName()
    }

    // MARK: Pages

    private var week: Week?
    private var weekPage: (week: Week, page: UIViewController)?

    private func page(for week: Week) -> UIViewController {
        if let weekPage, weekPage.week == week { return weekPage.page }
        (weekPage?.page as? SheetController)?.saveAll()
        let page = makeDayPage(PanePlace(path: GraphPaths.weeklyPath(for: week)))
        weekPage = (week, page)
        return page
    }

    /// A week's note, as a page, under the week and the month, as a day is.
    func show(_ week: Week) {
        guard week != self.week || pages.viewControllers?.isEmpty != false else { return }
        let forward = (week.monday ?? day) > day
        self.week = week
        pages.setViewControllers([page(for: week)], direction: forward ? .forward : .reverse, animated: isViewLoaded)
        strip?.show(week)
        showName()
    }

    private func week(of controller: UIViewController) -> Week? {
        weekPage.flatMap { $0.page === controller ? $0.week : nil }
    }

    private func firstDay(of week: Week) -> Day? {
        week.monday.map { NoteCalendar.week(of: $0)[0] }
    }

    private func key(_ day: Day) -> String { "\(day)/\(face.rawValue)" }

    private func page(for day: Day) -> UIViewController {
        if let page = made[key(day)] { return page }
        let page = makeDayPage(PanePlace(path: GraphPaths.dailyPath(for: day), face: face))
        made[key(day)] = page
        return page
    }

    private func makeDayPage(_ place: PanePlace) -> UIViewController {
        let page = makePage(place) { [weak self] place, row in self?.onOpen?(place, row) }
        if let sheet = page as? SheetController {
            sheet.restoresPlace = false
            sheet.pullsToSync = false
            // Pulled down, the day itself moves: no stretch past its top.
            sheet.scroll.bounces = false
            sheet.onLinkedCount = { [weak self, weak sheet] count in
                guard let self, sheet === self.sheet else { return }
                bar.linkedCount = count
            }
        }
        return page
    }

    private func day(of controller: UIViewController) -> Day? {
        made.first { $0.value === controller }.flatMap { Day(String($0.key.prefix(10))) }
    }

    /// A day, gone to: turned to, the way it lies from the one shown.
    func show(_ day: Day, animated: Bool = true) {
        guard day != self.day || week != nil || pages.viewControllers?.isEmpty != false else { return }
        let forward = day > self.day
        self.day = day
        week = nil
        pages.setViewControllers([page(for: day)], direction: forward ? .forward : .reverse, animated: animated && isViewLoaded) { [weak self] _ in
            self?.forgetFar()
        }
        strip?.show(day)
        showName()
    }

    private func forgetFar() {
        for (key, page) in made {
            guard let other = Day(String(key.prefix(10))) else { continue }
            let far = abs(Calendar.current.dateComponents([.day], from: other.date ?? Date(), to: day.date ?? Date()).day ?? 0) > 2
            if far || !key.hasSuffix(face.rawValue) {
                (page as? SheetController)?.saveAll()
                made[key] = nil
            }
        }
    }

    func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        if let week = week(of: viewController) { return firstDay(of: week).map { page(for: $0.adding(-1)) } }
        return day(of: viewController).map { page(for: $0.adding(-1)) }
    }

    func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        if let week = week(of: viewController) { return firstDay(of: week).map { page(for: $0) } }
        return day(of: viewController).map { page(for: $0.adding(1)) }
    }

    func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let shown = controller.viewControllers?.first, let day = day(of: shown) else { return }
        for previous in previousViewControllers { (previous as? SheetController)?.saveAll() }
        self.day = day
        week = nil
        UISelectionFeedbackGenerator().selectionChanged()
        forgetFar()
        strip?.show(day)
        showName()
    }

    // MARK: The week, and the month, under the bar

    private var calendar: CalendarController?
    private var strip: WeekStripView?
    /// The days with notes, marked: for the week over the day.
    var marks: () -> [Day: NoteCalendar.Mark] = { [:] }
    /// A week's number chosen, in the strip or the month: its note.
    var onChooseWeek: ((Week) -> Void)?
    private var reveal: CGFloat = 0
    private var revealAtStart: CGFloat = 0
    private lazy var pull: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        pan.delegate = self
        return pan
    }()

    /// Over the day, under the bar's controls — which float there still — the week, then the month.
    private var lead: CGFloat { PaneBar.height }
    private var weekHeight: CGFloat { lead + WeekStripView.height }
    private var monthHeight: CGFloat { lead + (calendar?.preferredHeight(width: view.bounds.width) ?? 420) }

    /// The month shown, at once — from the menu.
    func showCalendar(_ shown: Bool) { settle(at: shown ? monthHeight : 0, animated: true) }

    private func prepareOver() {
        let top = bar.contentTop + lead
        if strip == nil {
            let strip = WeekStripView(day: day, marks: marks())
            strip.onChoose = { [weak self] day in self?.show(day, animated: false) }
            strip.onChooseWeek = { [weak self] week in self?.show(week) }
            strip.onMonth = { [weak self] in
                guard let self else { return }
                settle(at: monthHeight, animated: true)
            }
            view.insertSubview(strip, belowSubview: pages.view)
            self.strip = strip
        }
        strip?.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: WeekStripView.height)
        if calendar == nil, let calendar = makeCalendar?(day) {
            calendar.onChoose = { [weak self] day in self?.show(day, animated: false) }
            calendar.onChooseWeek = { [weak self] week in self?.show(week) }
            addChild(calendar)
            view.insertSubview(calendar.view, belowSubview: pages.view)
            calendar.didMove(toParent: self)
            calendar.view.backgroundColor = .clear
            self.calendar = calendar
        }
        calendar?.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: monthHeight - lead)
        view.backgroundColor = Ink.shelf
        pages.view.backgroundColor = Ink.paper
        pages.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    /// The day so far down under the bar, and what is over it shown as much.
    private func place(_ amount: CGFloat) {
        reveal = max(0, amount)
        let top = bar.contentTop
        pages.view.frame = CGRect(x: 0, y: top + reveal, width: view.bounds.width, height: max(0, view.bounds.height - top - reveal))
        pages.view.layer.cornerRadius = min(28, reveal)
        let week = weekHeight, month = monthHeight
        strip?.alpha = reveal <= week ? max(0, reveal - lead) / (week - lead) : max(0, 1 - (reveal - week) / max(1, (month - week) * 0.5))
        calendar?.view.alpha = reveal <= week ? 0 : min(1, (reveal - week) / max(1, (month - week) * 0.6))
        if reveal == 0 { view.backgroundColor = Ink.page }
    }

    private func settle(at target: CGFloat, animated: Bool) {
        if target > 0 { prepareOver() }
        let change = { self.place(target) }
        guard animated else { return change() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: change)
    }

    /// Whether what is over the day — the week, the month — is out.
    var isRevealed: Bool { reveal > 0 }

    @objc private func pulled(_ pan: UIPanGestureRecognizer) {
        let travel = pan.translation(in: view).y
        switch pan.state {
        case .began:
            prepareOver()
            revealAtStart = reveal
        case .changed:
            if let scroll = sheet?.scroll { scroll.contentOffset.y = -scroll.adjustedContentInset.top }
            place(min(monthHeight + 40, revealAtStart + travel))
        default:
            let velocity = pan.velocity(in: view).y
            let stops: [CGFloat] = [0, weekHeight, monthHeight]
            let aimed = reveal + velocity * 0.15
            let target = stops.min { abs($0 - aimed) < abs($1 - aimed) } ?? 0
            settle(at: target, animated: true)
        }
    }

    /// Pulled down at the day's top — or, the calendar out, up or down — the
    /// day moves; else its page scrolls, and pages turn. Not on its hours,
    /// which are dragged for their blocks.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pull, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        let scroll = sheet?.scroll ?? schedule?.scroll
        let atTop = scroll.map { $0.contentOffset.y <= -$0.adjustedContentInset.top + 1 } ?? true
        return atTop && (velocity.y > 0 || reveal > 0)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === pull
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
    var onChooseWeek: ((Week) -> Void)?
    var onMonth: (() -> Void)?

    private var shown: Day
    private var days: [Day]
    var marks: [Day: NoteCalendar.Mark] { didSet { setNeedsDisplay() } }
    private let title = UILabel()
    private let month = UIButton(type: .system)
    private let row = StripRow()
    private let letters = StripRow()

    init(day: Day, marks: [Day: NoteCalendar.Mark]) {
        shown = day
        days = NoteCalendar.week(of: day)
        self.marks = marks
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        row.backgroundColor = .clear
        row.isUserInteractionEnabled = false
        addSubview(row)
        letters.backgroundColor = .clear
        letters.isUserInteractionEnabled = false
        addSubview(letters)
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

    private var chosenWeek: Week?

    func show(_ week: Week) {
        chosenWeek = week
        if let monday = week.monday, !days.contains(monday) { days = NoteCalendar.week(of: monday) }
        showTitle()
    }

    func show(_ day: Day) {
        chosenWeek = nil
        shown = day
        if !days.contains(day) { days = NoteCalendar.week(of: day) }
        showTitle()
    }

    private var week: Week? { NoteCalendar.week(ofRow: days.map(Optional.some)) }

    private func showTitle() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        title.text = days[3].date.map(formatter.string(from:))
        setNeedsDisplay()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let forward = gesture.direction == .left
        let old = row.snapshotView(afterScreenUpdates: false)
        let oldTitle = title.snapshotView(afterScreenUpdates: false)
        if let old { old.frame = row.frame; insertSubview(old, aboveSubview: row) }
        if let oldTitle { oldTitle.frame = title.frame; addSubview(oldTitle) }
        days = days.map { $0.adding(forward ? 7 : -7) }
        UISelectionFeedbackGenerator().selectionChanged()
        showTitle()
        row.layoutIfNeeded()
        let shift = (bounds.width - 52) * (forward ? 1 : -1)
        row.transform = CGAffineTransform(translationX: shift, y: 0)
        title.alpha = 0
        UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.row.transform = .identity
            old?.transform = CGAffineTransform(translationX: -shift, y: 0)
            old?.alpha = 0
            self.title.alpha = 1
            oldTitle?.alpha = 0
        } completion: { _ in
            old?.removeFromSuperview()
            oldTitle?.removeFromSuperview()
        }
    }

    private static let weekColumn: CGFloat = 40

    private func cell(_ i: Int) -> CGRect {
        let inset: CGFloat = 12, start = inset + Self.weekColumn, width = (bounds.width - start - inset) / 7
        return CGRect(x: start + CGFloat(i) * width, y: 40, width: width, height: 52)
    }

    private var weekCell: CGRect { CGRect(x: 12, y: 40, width: Self.weekColumn, height: 52) }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if weekCell.contains(point), let week {
            UISelectionFeedbackGenerator().selectionChanged()
            onChooseWeek?(week)
            return
        }
        guard let i = days.indices.first(where: { cell($0).contains(point) }) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        onChoose?(days[i])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 24, y: 6, width: bounds.width - 100, height: 26)
        month.frame = CGRect(x: bounds.width - 60, y: 0, width: 44, height: 38)
        if row.transform == .identity { row.frame = bounds }
        letters.frame = bounds
        row.drawing = { [weak self] rect in self?.drawRow(rect, letters: false) }
        letters.drawing = { [weak self] rect in self?.drawRow(rect, letters: true) }
    }

    override func setNeedsDisplay() {
        super.setNeedsDisplay()
        row.setNeedsDisplay()
        letters.setNeedsDisplay()
    }

    private func drawRow(_ rect: CGRect, letters: Bool) {
        let today = Day.today
        let symbols = NoteCalendar.weekdaySymbols()
        let label = Card.label(size: 15)
        if letters {
            let letter = NSAttributedString(string: "W", attributes: label)
            letter.draw(at: CGPoint(x: (weekCell.midX - letter.size().width / 2).rounded(), y: weekCell.minY))
        } else if let week {
            let cell = weekCell
            let chosen = week == chosenWeek
            let center = CGPoint(x: cell.midX, y: cell.minY + 32)
            if chosen {
                Ink.week.setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)).fill()
            }
            let number = NSAttributedString(string: "\(week.week)", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), .foregroundColor: chosen ? Ink.paper : Ink.week,
            ])
            let size = number.size()
            number.draw(at: CGPoint(x: (cell.midX - size.width / 2).rounded(), y: (cell.minY + 32 - size.height / 2).rounded()))
        }
        for (i, day) in days.enumerated() {
            let cell = cell(i)
            let letter = NSAttributedString(string: symbols[i].uppercased(), attributes: label)
            if letters {
                letter.draw(at: CGPoint(x: (cell.midX - letter.size().width / 2).rounded(), y: cell.minY))
                continue
            }
            let center = CGPoint(x: cell.midX, y: cell.minY + 32)
            let mark = marks[day]
            let chosen = day == shown && chosenWeek == nil
            if chosen {
                Ink.text.setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32)).fill()
            } else if let progress = mark?.progress {
                ProgressRing.image(progress, side: 30, tick: false).draw(in: CGRect(x: center.x - 15, y: center.y - 15, width: 30, height: 30))
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

private final class StripRow: UIView {
    var drawing: ((CGRect) -> Void)?
    override func draw(_ rect: CGRect) { drawing?(rect) }
}
