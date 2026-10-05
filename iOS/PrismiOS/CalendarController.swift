import UIKit
import ReflectCore
import PrismCore

/// A month of days: a dot under each day with a note; for a note with
/// tasks or a checklist, how far along, as a ring about its number. A day
/// tapped is gone to; a swipe across, or the arrows, go a month along.
final class CalendarController: UIViewController {
    var onChoose: ((Day) -> Void)?
    private let marks: [Day: NoteCalendar.Mark]
    private let grid: CalendarGrid
    private let monthTitle = UILabel()
    private let earlier = UIButton(type: .system)
    private let later = UIButton(type: .system)

    init(month: NoteCalendar.Month, marks: [Day: NoteCalendar.Mark]) {
        self.marks = marks
        grid = CalendarGrid(month: month, marks: marks)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.card
        monthTitle.font = .systemFont(ofSize: 20, weight: .bold)
        monthTitle.textColor = Ink.text
        view.addSubview(monthTitle)
        for (button, symbol, step) in [(earlier, "chevron.left", -1), (later, "chevron.right", 1)] {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                            for: .normal)
            button.tintColor = Ink.secondary
            button.accessibilityLabel = step < 0 ? "Previous Month" : "Next Month"
            button.addAction(UIAction { [weak self] _ in self?.move(step) }, for: .touchUpInside)
            view.addSubview(button)
        }
        grid.onChoose = { [weak self] day in
            UISelectionFeedbackGenerator().selectionChanged()
            self?.onChoose?(day)
        }
        view.addSubview(grid)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        showTitle()
    }

    @objc private func swiped(_ gesture: UISwipeGestureRecognizer) { move(gesture.direction == .left ? 1 : -1) }

    private func move(_ step: Int) {
        let snapshot = grid.snapshotView(afterScreenUpdates: false)
        grid.month = grid.month.adding(step)
        showTitle()
        // The month slides over, the way it went.
        guard let snapshot else { return }
        snapshot.frame = grid.frame
        view.addSubview(snapshot)
        let shift = grid.bounds.width * CGFloat(step)
        grid.transform = CGAffineTransform(translationX: shift, y: 0)
        UIView.animate(withDuration: 0.28, delay: 0, options: .curveEaseOut) {
            snapshot.transform = CGAffineTransform(translationX: -shift, y: 0)
            snapshot.alpha = 0
            self.grid.transform = .identity
        } completion: { _ in snapshot.removeFromSuperview() }
    }

    private func showTitle() {
        monthTitle.text = grid.month.title()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset: CGFloat = 20
        let width = view.bounds.width - 2 * inset
        monthTitle.frame = CGRect(x: inset + 6, y: 28, width: width - 100, height: 28)
        later.frame = CGRect(x: view.bounds.width - inset - 44, y: 20, width: 44, height: 44)
        earlier.frame = later.frame.offsetBy(dx: -44, dy: 0)
        grid.frame = CGRect(x: inset, y: 76, width: width, height: grid.height(width: width))
    }

    /// As tall as a month's six weeks want: the sheet sized to it.
    func preferredHeight(width: CGFloat) -> CGFloat { 76 + grid.height(width: width - 40) + 24 }
}

/// The days of a month, drawn.
private final class CalendarGrid: UIView {
    var month: NoteCalendar.Month { didSet { setNeedsDisplay() } }
    var onChoose: ((Day) -> Void)?
    private let marks: [Day: NoteCalendar.Mark]
    private static let weekdayRow: CGFloat = 26

    init(month: NoteCalendar.Month, marks: [Day: NoteCalendar.Mark]) {
        self.month = month
        self.marks = marks
        super.init(frame: .zero)
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var cell: CGFloat { bounds.width / 7 }

    /// Six weeks' room, whatever the month: the sheet stays still.
    func height(width: CGFloat) -> CGFloat { Self.weekdayRow + 6 * min(width / 7, 52) }

    private func rect(week: Int, weekday: Int) -> CGRect {
        let row = min(cell, 52)
        return CGRect(x: CGFloat(weekday) * cell, y: Self.weekdayRow + CGFloat(week) * row, width: cell, height: row)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        for (w, week) in NoteCalendar.weeks(of: month).enumerated() {
            for (d, day) in week.enumerated() where rect(week: w, weekday: d).contains(point) {
                if let day { onChoose?(day) }
                return
            }
        }
    }

    override func draw(_ rect: CGRect) {
        let weekdayFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
        for (i, symbol) in NoteCalendar.weekdaySymbols().enumerated() {
            let text = NSAttributedString(string: symbol, attributes: [.font: weekdayFont, .foregroundColor: Ink.secondary])
            let size = text.size()
            text.draw(at: CGPoint(x: CGFloat(i) * cell + (cell - size.width) / 2, y: 2))
        }
        let today = Day.today
        for (w, week) in NoteCalendar.weeks(of: month).enumerated() {
            for (d, day) in week.enumerated() {
                guard let day else { continue }
                drawDay(day, in: self.rect(week: w, weekday: d), today: today)
            }
        }
    }

    private func drawDay(_ day: Day, in rect: CGRect, today: Day) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let mark = marks[day]
        if let progress = mark?.progress {
            let side: CGFloat = 36
            ProgressRing.draw(progress, in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side),
                              lineWidth: 2.4, tick: false)
        }
        let isToday = day == today
        let color: UIColor = isToday ? Ink.accent : mark != nil ? Ink.text : Ink.faint
        let text = NSAttributedString(string: "\(day.day)", attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: isToday || mark != nil ? .semibold : .regular),
            .foregroundColor: color,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded()))
        if mark != nil, mark?.progress == nil {
            (isToday ? Ink.accent : Ink.secondary).setFill()
            UIBezierPath(ovalIn: CGRect(x: center.x - 2.5, y: center.y + 11, width: 5, height: 5)).fill()
        }
    }
}
