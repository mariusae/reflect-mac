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
final class DayPager: UIViewController, NoteHost, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
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
        pages.view.addGestureRecognizer(pull)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if reveal == 0 { pages.view.frame = view.bounds }
    }

    func notesChanged(_ paths: Set<String>) {}

    /// The week shown, its own note, in place of a day — till a day is.
    private(set) var week: Week?
    private var weekPage: (week: Week, sheet: SheetController)?

    /// A week's note, as a page: before its first day.
    private func page(for week: Week) -> SheetController {
        if let weekPage, weekPage.week == week { return weekPage.sheet }
        weekPage?.sheet.saveAll()
        let sheet = makePage(GraphPaths.weeklyPath(for: week))
        weekPage = (week, sheet)
        return sheet
    }

    /// A week's note shown, under the week and the month, as a day is.
    func show(_ week: Week) {
        guard week != self.week || sheet == nil else { return }
        let forward = (week.monday ?? day) > day
        self.week = week
        pages.setViewControllers([page(for: week)], direction: forward ? .forward : .reverse, animated: isViewLoaded)
        strip?.show(week)
        onShownChange?()
    }

    private func week(of controller: UIViewController) -> Week? {
        guard let sheet = controller as? SheetController, case .note(let path) = sheet.kind else { return nil }
        return GraphPaths.week(fromWeeklyPath: path)
    }

    /// The first day of a week, as the strip begins it.
    private func firstDay(of week: Week) -> Day? {
        week.monday.map { NoteCalendar.week(of: $0)[0] }
    }

    /// The sheet of a day: made once, kept while near the day shown.
    private func page(for day: Day) -> SheetController {
        if let sheet = made[day] { return sheet }
        let sheet = makePage(GraphPaths.dailyPath(for: day))
        made[day] = sheet
        return sheet
    }

    private func makePage(_ path: String) -> SheetController {
        let sheet = makeSheet(.note(path))
        sheet.allowsBacklinkSwipe = false
        sheet.restoresPlace = false
        // Pulled down, the day itself moves: no stretch past its top.
        sheet.scroll.bounces = false
        sheet.scroll.refreshControl = nil
        return sheet
    }

    private func day(of controller: UIViewController) -> Day? {
        guard let sheet = controller as? SheetController, case .note(let path) = sheet.kind else { return nil }
        return GraphPaths.day(fromDailyPath: path)
    }

    /// A day, gone to: turned to, the way it lies from the one shown.
    func show(_ day: Day, animated: Bool = true) {
        guard day != self.day || week != nil || sheet == nil else { return }
        let forward = day > self.day
        self.day = day
        week = nil
        pages.setViewControllers([page(for: day)], direction: forward ? .forward : .reverse, animated: animated && isViewLoaded) { [weak self] _ in
            self?.forgetFar()
        }
        showDayInStrip()
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
        // A week's page, between the day before its first and its first.
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
        showDayInStrip()
        onShownChange?()
    }

    // MARK: The week, and the month, over the day

    private var calendar: CalendarController?
    private var strip: WeekStripView?
    /// The days with notes, marked: for the week over the day.
    var marks: () -> [Day: NoteCalendar.Mark] = { [:] }
    /// A week's number chosen, in the strip or the month: its note.
    var onChooseWeek: ((Week) -> Void)?
    /// How far down the day is: nothing over it at 0, the week at its
    /// height, the month at its. Pulled to, and left where let go.
    private var reveal: CGFloat = 0
    private var revealAtStart: CGFloat = 0
    private lazy var pull: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pulled(_:)))
        pan.delegate = self
        return pan
    }()

    private var weekHeight: CGFloat { WeekStripView.height }
    private var monthHeight: CGFloat { calendar?.preferredHeight(width: view.bounds.width) ?? 420 }

    /// The month shown, at once — from the menu.
    func showCalendar(_ shown: Bool) { settle(at: shown ? monthHeight : 0, animated: true) }

    /// What is over the day made, if it is not: the week, and the month.
    private func prepareOver() {
        let top = view.safeAreaInsets.top
        if strip == nil {
            let strip = WeekStripView(day: day, marks: marks())
            strip.onChoose = { [weak self] day in self?.show(day, animated: false) }
            strip.onChooseWeek = { [weak self] week in self?.show(week) }
            strip.onMonth = { [weak self] in
                guard let self else { return }
                settle(at: monthHeight, animated: true)
            }
            strip.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: weekHeight)
            view.insertSubview(strip, belowSubview: pages.view)
            self.strip = strip
        }
        if calendar == nil, let calendar = makeCalendar(day) {
            calendar.onChoose = { [weak self] day in self?.show(day, animated: false) }
            calendar.onChooseWeek = { [weak self] week in self?.show(week) }
            addChild(calendar)
            view.insertSubview(calendar.view, belowSubview: pages.view)
            calendar.didMove(toParent: self)
            calendar.view.backgroundColor = .clear
            calendar.view.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: calendar.preferredHeight(width: view.bounds.width))
            self.calendar = calendar
        }
        view.backgroundColor = Ink.shelf
        pages.view.backgroundColor = Ink.paper
        pages.view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    /// The day so far down, and what is over it shown as much: the week as
    /// it comes in, the month past it.
    private func place(_ amount: CGFloat) {
        reveal = max(0, amount)
        let top = view.safeAreaInsets.top
        pages.view.frame = CGRect(x: 0, y: reveal > 0 ? top + reveal : 0, width: view.bounds.width,
                                  height: view.bounds.height - (reveal > 0 ? top + reveal : 0))
        pages.view.layer.cornerRadius = min(32, reveal)
        let week = weekHeight, month = monthHeight
        strip?.alpha = reveal <= week ? reveal / week : max(0, 1 - (reveal - week) / max(1, (month - week) * 0.5))
        calendar?.view.alpha = reveal <= week ? 0 : min(1, (reveal - week) / max(1, (month - week) * 0.6))
        if reveal == 0 { view.backgroundColor = Ink.page }
    }

    /// Let go: to the nearest of none, the week, the month — the way it was going.
    private func settle(at target: CGFloat, animated: Bool) {
        if target > 0 { prepareOver() }
        let change = { self.place(target) }
        guard animated else { return change() }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: change)
    }

    @objc private func pulled(_ pan: UIPanGestureRecognizer) {
        let travel = pan.translation(in: view).y
        switch pan.state {
        case .began:
            prepareOver()
            revealAtStart = reveal
        case .changed:
            // The day's page held at its top while the day itself is moved.
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
    /// day moves; else its page scrolls, and pages turn.
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pull, let pan = gesture as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        let atTop = sheet.map { $0.scroll.contentOffset.y <= -$0.scroll.adjustedContentInset.top + 1 } ?? true
        return atTop && (velocity.y > 0 || reveal > 0)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gesture === pull
    }

    /// The day shown changed: the strip on it.
    private func showDayInStrip() {
        if let week { strip?.show(week) } else { strip?.show(day) }
    }
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
    var onChooseWeek: ((Week) -> Void)?
    var onMonth: (() -> Void)?

    private var shown: Day
    private var days: [Day]
    private let marks: [Day: NoteCalendar.Mark]
    private let title = UILabel()
    private let month = UIButton(type: .system)
    /// The week's days, drawn on a layer of their own: slid across, a week along.
    private let row = StripRow()
    /// The weekdays' letters, and W: the same each week, kept still.
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

    /// The week whose note shows under it: its number filled, no day.
    private var chosenWeek: Week?

    func show(_ week: Week) {
        chosenWeek = week
        if let monday = week.monday, !days.contains(monday) { days = NoteCalendar.week(of: monday) }
        showTitle()
    }

    /// The day shown under it now: its week, it filled.
    func show(_ day: Day) {
        chosenWeek = nil
        shown = day
        if !days.contains(day) { days = NoteCalendar.week(of: day) }
        showTitle()
    }

    /// The week shown, as a week: its number, at the strip's start.
    private var week: Week? { NoteCalendar.week(ofRow: days.map(Optional.some)) }

    private func showTitle() {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        title.text = days[3].date.map(formatter.string(from:))
        setNeedsDisplay()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
        let forward = gesture.direction == .left
        // The week as it was, slid away the way the finger went; the next in after it.
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

    /// The week's own cell, before its days: its number, its note.
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

    /// The strip drawn: its letters — still — or its numbers, which slide.
    private func drawRow(_ rect: CGRect, letters: Bool) {
        let today = Day.today
        let symbols = NoteCalendar.weekdaySymbols()
        let label = Card.label(size: 15)
        // The week's number, its note's: in the accent of weeks, under "W".
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
                // The ring alone: a tick in it would be over the number.
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

/// Where the strip's days are drawn: its own layer, to slide across.
private final class StripRow: UIView {
    var drawing: ((CGRect) -> Void)?
    override func draw(_ rect: CGRect) { drawing?(rect) }
}
