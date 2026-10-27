import UIKit
import ReflectCore
import PrismCore

// The iPad's own: wide, a sidebar of the lens's list on glass at the left,
// the note the rest of the height — the Mac's, by touch. Narrow, as the
// phone is.

/// Daily, in the sidebar: the month, its days marked, and the days written
/// in, newest first — tapped, the day shown beside.
final class DaySidebarController: UIViewController {
    let bar = PaneBar()
    private let store: PrismStore
    var onDay: ((Day) -> Void)?
    var onWeek: ((Week) -> Void)?
    var menu: (() -> UIMenu)?

    private let list = UIScrollView()
    private var calendar: CalendarController?
    private let daysLabel = UILabel()
    private var rows: [NoteSummaryRow] = []
    private var paths: [String] = []
    /// The day shown beside: its row marked.
    var chosen: String? { didSet { markChosen() } }

    init(store: PrismStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        list.alwaysBounceVertical = true
        list.contentInsetAdjustmentBehavior = .never
        view.addSubview(list)
        view.addSubview(bar)
        bar.menu = { [weak self] in self?.menu?() ?? UIMenu() }
        bar.show(title: Lens.daily.title, detail: nil)
        daysLabel.attributedText = NSAttributedString(string: "DAYS", attributes: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .kern: 1.2, .foregroundColor: Ink.secondary,
        ])
        list.addSubview(daysLabel)
        reload()
    }

    func notesChanged(_ paths: Set<String>) { reload() }

    private func reload() {
        guard isViewLoaded, let graph = store.graph, let index = store.index else { return }
        // The month, its marks as they are now.
        calendar?.willMove(toParent: nil)
        calendar?.view.removeFromSuperview()
        calendar?.removeFromParent()
        let shown = chosen.flatMap(GraphPaths.day(fromDailyPath:)) ?? .today
        let month = CalendarController(month: NoteCalendar.Month(shown), marks: NoteCalendar.marks(graph: graph, index: index),
                                       weeks: NoteCalendar.weeksWithNotes(index: index))
        month.onChoose = { [weak self] day in self?.onDay?(day) }
        month.onChooseWeek = { [weak self] week in self?.onWeek?(week) }
        addChild(month)
        list.addSubview(month.view)
        month.didMove(toParent: self)
        month.view.backgroundColor = .clear
        calendar = month

        var days = Set(graph.dailyNoteFiles().keys)
        days.insert(.today)
        let now = days.sorted(by: >).prefix(40).map { GraphPaths.dailyPath(for: $0) }
        if now != paths {
            paths = now
            rows.forEach { $0.removeFromSuperview() }
            rows = paths.map { path in
                let row = NoteSummaryRow(path: path, store: store, done: false)
                row.addAction(UIAction { [weak self] _ in
                    guard let day = GraphPaths.day(fromDailyPath: path) else { return }
                    self?.onDay?(day)
                }, for: .touchUpInside)
                list.addSubview(row)
                return row
            }
        } else {
            rows.forEach { $0.refresh() }
        }
        markChosen()
        view.setNeedsLayout()
    }

    private func markChosen() {
        for row in rows { row.isChosen = row.path == chosen }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        bar.top = top
        bar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: top + PaneBar.height)
        view.bringSubviewToFront(bar)
        let width = view.bounds.width
        list.frame = CGRect(x: 0, y: top, width: width, height: view.bounds.height - top)
        list.contentInset.top = PaneBar.height
        list.verticalScrollIndicatorInsets.top = PaneBar.height
        var y: CGFloat = 0
        if let calendar {
            let height = calendar.preferredHeight(width: width)
            calendar.view.frame = CGRect(x: 0, y: y - 16, width: width, height: height)
            y += height - 16
        }
        daysLabel.frame = CGRect(x: 20, y: y + 4, width: width - 40, height: 18)
        y += 30
        for row in rows {
            row.frame = CGRect(x: 0, y: y, width: width, height: NoteSummaryRow.height)
            y += NoteSummaryRow.height
        }
        list.contentSize = CGSize(width: width, height: y + view.safeAreaInsets.bottom + 40)
    }
}

/// By the window's left edge, wide: the sidebar out, or put away.
final class SidebarButton: UIView {
    var onTap: (() -> Void)?
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let button = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.cornerConfiguration = .capsule()
        addSubview(glass)
        button.setImage(UIImage(systemName: "sidebar.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)),
                        for: .normal)
        button.tintColor = Ink.text
        button.accessibilityLabel = "Show or Hide the Sidebar"
        button.isPointerInteractionEnabled = true
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        glass.contentView.addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// On the sidebar's own glass: none of its own.
    var onGlass = false { didSet { glass.effect = onGlass ? nil : UIGlassEffect() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        button.frame = glass.contentView.bounds
    }
}
