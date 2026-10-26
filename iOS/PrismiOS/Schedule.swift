import UIKit
import ReflectCore
import PrismCore

/// A day's other face: its hours, and the time blocks its note's
/// "Timeblocks" bullet has, down them — tapped in empty time, a new one;
/// tapped, one changed; held and dragged, moved, or by its foot, made
/// longer. Its tasks button puts a task on the day: moved out of its note
/// into the day's blocks, at the next free hour.
final class ScheduleController: UIViewController, UIGestureRecognizerDelegate {
    let store: PrismStore
    let day: Day
    let scroll = UIScrollView()
    private let grid = ScheduleGrid()
    /// Now, over the blocks.
    private let nowLine = NowLine()
    private var views: [BlockView] = []
    private let tasksButton = UIButton(type: .system)
    private var ticker: Timer?

    static let hour: CGFloat = 64
    static let gutter: CGFloat = 58
    static let pad: CGFloat = 14
    static let lastMinute = 24 * 60 - 15

    init(day: Day, store: PrismStore) {
        self.day = day
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var path: String { GraphPaths.dailyPath(for: day) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Ink.paper
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .always
        view.addSubview(scroll)
        grid.day = day
        scroll.addSubview(grid)
        nowLine.day = day
        nowLine.isUserInteractionEnabled = false
        grid.addSubview(nowLine)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        grid.addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.3
        hold.delegate = self
        grid.addGestureRecognizer(hold)
        var style = UIButton.Configuration.glass()
        style.image = UIImage(systemName: "checklist", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        style.title = "Tasks"
        style.imagePadding = 6
        style.baseForegroundColor = Ink.text
        style.cornerStyle = .capsule
        tasksButton.configuration = style
        tasksButton.accessibilityHint = "Puts a task on this day"
        tasksButton.addAction(UIAction { [weak self] _ in self?.chooseTask() }, for: .touchUpInside)
        view.addSubview(tasksButton)
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.grid.setNeedsDisplay()
                self?.nowLine.setNeedsDisplay()
            }
        }
    }


    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ticker?.invalidate()
        ticker = nil
    }

    private var scrolledToWork = false

    /// To where the day's work starts — today, to now.
    private func scrollToWork() {
        var first = (blocks.map(\.start).min() ?? 8 * 60) - 30
        if day == .today { first = min(max(first, Self.nowMinutes - 180), Self.nowMinutes - 60) }
        let y = max(-scroll.adjustedContentInset.top, min(Self.y(max(0, first)), scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom))
        scroll.contentOffset.y = y
    }

    static var nowMinutes: Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    static func y(_ minutes: Int) -> CGFloat { pad + CGFloat(minutes) / 60 * hour }
    static func minutes(_ y: CGFloat) -> Double { Double((y - pad) / hour * 60) }
    static func quarter(_ y: CGFloat) -> Int { max(0, min(lastMinute, Int((minutes(y) / 15).rounded(.down)) * 15)) }
    static func snap(_ minutes: Double) -> Int { max(0, min(lastMinute, Int((minutes / 15).rounded()) * 15)) }

    // MARK: The blocks

    private(set) var blocks: [DayBlock] = []

    func notesChanged(_ paths: Set<String>) {
        if paths.isEmpty || paths.contains(path) { reload() }
    }

    func reload() {
        guard isViewLoaded, dragging == nil else { return }
        blocks = DayBlocks.blocks(in: store.text(path))
        views.forEach { $0.removeFromSuperview() }
        views = blocks.map { block in
            let view = BlockView(block: block)
            view.onToggle = { [weak self] row, task in self?.change { DayBlocks.settingTask(row: row, to: task, in: $0) } }
            grid.addSubview(view)
            return view
        }
        view.setNeedsLayout()
    }

    /// The day's note, read, made over, written — if it changed.
    private func change(_ transform: (String) -> String?) {
        let source = store.text(path)
        guard let updated = transform(source), updated != source else { return }
        store.write(updated, path: path)
        blocks = DayBlocks.blocks(in: updated)
        reload()
        // The block being changed, as it now is.
        if let editor = openEditor, let fresh = blocks.first(where: { $0.row == editor.block.row }) { editor.update(fresh) }
    }

    private weak var openEditor: BlockEditorController?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds
        let width = view.bounds.width
        grid.frame = CGRect(x: 0, y: 0, width: width, height: Self.y(24 * 60) + Self.pad)
        scroll.contentSize = CGSize(width: width, height: grid.frame.height + 70)
        nowLine.frame = grid.bounds
        grid.bringSubviewToFront(nowLine)
        // Once laid out: to where the work is.
        if !scrolledToWork, view.bounds.height > 0 {
            scrolledToWork = true
            scrollToWork()
        }
        let size = tasksButton.intrinsicContentSize
        tasksButton.frame = CGRect(x: width - size.width - 16, y: view.bounds.height - view.safeAreaInsets.bottom - size.height - 12,
                                   width: size.width, height: size.height)
        placeBlocks()
    }

    /// Each block's lane among those it overlaps, and how many lanes.
    private func lanes() -> [Int: (lane: Int, of: Int)] {
        var found: [Int: (Int, Int)] = [:]
        var cluster: [Int] = [], ends: [Int] = [], clusterEnd = -1
        func close() {
            for row in cluster { found[row] = (found[row]!.0, ends.count) }
            cluster = []; ends = []
        }
        for block in blocks.sorted(by: { ($0.start, $0.row) < ($1.start, $1.row) }) {
            if block.start >= clusterEnd { close() }
            let lane = ends.firstIndex { $0 <= block.start } ?? ends.count
            if lane == ends.count { ends.append(block.end) } else { ends[lane] = block.end }
            found[block.row] = (lane, 0)
            cluster.append(block.row)
            clusterEnd = max(clusterEnd, block.end)
        }
        close()
        return found
    }

    private func frame(start: Int, end: Int, lane: Int = 0, of lanes: Int = 1) -> CGRect {
        let column = CGRect(x: Self.gutter, y: 0, width: grid.bounds.width - Self.gutter - 10, height: 0)
        let width = column.width / CGFloat(max(1, lanes))
        let top = Self.y(start), bottom = max(Self.y(end), top + 18)
        return CGRect(x: column.minX + CGFloat(lane) * width, y: top + 1, width: width - (lane < lanes - 1 ? 3 : 0), height: bottom - top - 2)
    }

    private func placeBlocks() {
        let lanes = lanes()
        for view in views where view !== dragging?.view {
            let lane = lanes[view.block.row] ?? (0, 1)
            view.frame = frame(start: view.block.start, end: view.block.end, lane: lane.lane, of: lane.of)
        }
    }

    // MARK: Touches

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let point = tap.location(in: grid)
        if let view = views.last(where: { $0.frame.contains(point) }) {
            if view.toggle(at: grid.convert(point, to: view)) { return }
            return edit(view.block)
        }
        guard point.x > Self.gutter else { return }
        let start = Self.quarter(point.y)
        let end = min(start + 60, Self.lastMinute)
        change { DayBlocks.adding(start: start, end: end, title: "", to: $0) }
        if let made = blocks.first(where: { $0.start == start && $0.title.isEmpty }) { edit(made, naming: true) }
    }

    /// Held on a block: moved — or, held by its foot, made longer.
    private var dragging: (view: BlockView, grab: Double, resizing: Bool, start: Int, end: Int)?

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let point = gesture.location(in: grid)
        return views.contains { $0.frame.contains(point) }
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        let point = hold.location(in: grid)
        switch hold.state {
        case .began:
            guard let view = views.last(where: { $0.frame.contains(point) }) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            let resizing = point.y > view.frame.maxY - 18
            dragging = (view, Self.minutes(point.y) - Double(view.block.start), resizing, view.block.start, view.block.end)
            grid.bringSubviewToFront(view)
            UIView.animate(withDuration: 0.15) { view.lifted = true }
        case .changed:
            guard var drag = dragging else { return }
            let block = drag.view.block
            if drag.resizing {
                drag.end = max(block.start + 15, Self.snap(Self.minutes(point.y)))
            } else {
                drag.start = max(0, min(Self.lastMinute - block.duration, Self.snap(Self.minutes(point.y) - drag.grab)))
                drag.end = drag.start + block.duration
            }
            if (drag.start, drag.end) != (dragging!.start, dragging!.end) { UISelectionFeedbackGenerator().selectionChanged() }
            dragging = drag
            drag.view.frame = frame(start: drag.start, end: drag.end)
            drag.view.showTimes(start: drag.start, end: drag.end)
            // Near the screen's ends: the hours scroll along.
            let visible = scroll.convert(point, from: grid).y - scroll.contentOffset.y
            if visible < 80 { scroll.contentOffset.y = max(-scroll.adjustedContentInset.top, scroll.contentOffset.y - 8) }
            if visible > scroll.bounds.height - 140 { scroll.contentOffset.y = min(scroll.contentSize.height - scroll.bounds.height, scroll.contentOffset.y + 8) }
        default:
            guard let drag = dragging else { return }
            dragging = nil
            drag.view.lifted = false
            let block = drag.view.block
            if (drag.start, drag.end) != (block.start, block.end), hold.state == .ended {
                change { DayBlocks.retiming(row: block.row, start: drag.start, end: drag.end, in: $0) }
            } else {
                placeBlocks()
                drag.view.showTimes(start: block.start, end: block.end)
            }
        }
    }

    // MARK: Changing one

    private func edit(_ block: DayBlock, naming: Bool = false) {
        let editor = BlockEditorController(block: block, day: day)
        let row = block.row
        editor.onTitle = { [weak self] title in self?.change { DayBlocks.settingTitle(row: row, to: title, in: $0) } }
        editor.onTimes = { [weak self] start, end in
            self?.change { DayBlocks.retiming(row: row, start: start, end: end, in: $0) }
            editor.dismiss(animated: true)
        }
        editor.onTask = { [weak self] task in self?.change { DayBlocks.settingTask(row: row, to: task, in: $0) } }
        editor.onItemTask = { [weak self] item, task in self?.change { DayBlocks.settingTask(row: item, to: task, in: $0) } }
        editor.onItemText = { [weak self] item, text in
            self?.change { text.isEmpty ? DayBlocks.removing(row: item, from: $0)?.source : DayBlocks.settingTitle(row: item, to: text, in: $0) }
        }
        editor.onAddItem = { [weak self, weak editor] text in
            guard let self else { return }
            change { DayBlocks.addingItem(text, under: row, in: $0) }
            _ = editor
        }
        editor.onDelete = { [weak self, weak editor] in
            editor?.dismiss(animated: true)
            self?.change { DayBlocks.removing(row: row, from: $0)?.source }
        }
        editor.onMoveDay = { [weak self, weak editor] by in
            guard let self else { return }
            editor?.dismiss(animated: true)
            move(row: row, to: day.adding(by))
        }
        let navigation = UINavigationController(rootViewController: editor)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        openEditor = editor
        present(navigation, animated: true)
        if naming { editor.focusTitle() }
    }

    /// A block to another day, at the same time: out of this note, into that one.
    private func move(row: Int, to other: Day) {
        let to = GraphPaths.dailyPath(for: other)
        guard let block = blocks.first(where: { $0.row == row }),
              let (left, subtree) = DayBlocks.removing(row: row, from: store.text(path)) else { return }
        store.write(left, path: path)
        store.write(DayBlocks.inserting(subtree, start: block.start, end: block.end, into: store.text(to)), path: to)
        reload()
    }

    // MARK: A task, put on the day

    private func chooseTask() {
        guard let index = store.index else { return }
        let tasks = index.tasks()
        var blocked: [String: Set<Int>] = [:]
        for path in Set(tasks.filter { $0.day != nil }.map(\.notePath)) {
            blocked[path] = DayBlocks.blockedTasks(in: store.text(path))
        }
        let open = tasks.filter { !(blocked[$0.notePath]?.contains($0.ordinal) ?? false) }
        let picker = TaskPickerController(groups: Tasks.group(open, today: .today))
        picker.onChoose = { [weak self, weak picker] task in
            picker?.dismiss(animated: true)
            self?.place(task)
        }
        let navigation = UINavigationController(rootViewController: picker)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    /// The next free hour — after now, today — the first the day's blocks leave.
    private func freeHour() -> Int {
        var start = day == .today ? (Self.nowMinutes + 14) / 15 * 15 : 9 * 60
        let sorted = blocks.sorted { $0.start < $1.start }
        for block in sorted where block.start < start + 60 && block.end > start { start = max(start, (block.end + 14) / 15 * 15) }
        return min(start, Self.lastMinute - 60)
    }

    /// A task moved out of its note — what is under it with it — into the
    /// day's blocks, an hour long.
    private func place(_ task: NoteTask) {
        let start = freeHour(), end = start + 60
        guard let (left, subtree) = DayBlocks.takingTask(ordinal: task.ordinal, from: store.text(task.notePath)) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if task.notePath == path {
            store.write(DayBlocks.inserting(subtree, start: start, end: end, into: left), path: path)
        } else {
            store.write(left, path: task.notePath)
            store.write(DayBlocks.inserting(subtree, start: start, end: end, into: store.text(path)), path: path)
        }
        reload()
        let y = Self.y(start) - 80
        scroll.setContentOffset(CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top, min(y, scroll.contentSize.height - scroll.bounds.height))), animated: true)
    }

    // MARK: Colours

    /// A block's colour, from what it says: kept wherever it goes.
    static func color(for block: DayBlock) -> UIColor {
        let key = InlineMarkup.plainText(block.title).lowercased()
        let hash = key.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }

    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    static let palette: [UIColor] = [
        dynamic(UIColor(red: 0.24, green: 0.47, blue: 0.85, alpha: 1), UIColor(red: 0.45, green: 0.64, blue: 1, alpha: 1)),
        dynamic(UIColor(red: 0.2, green: 0.6, blue: 0.42, alpha: 1), UIColor(red: 0.38, green: 0.78, blue: 0.56, alpha: 1)),
        dynamic(UIColor(red: 0.85, green: 0.5, blue: 0.15, alpha: 1), UIColor(red: 0.98, green: 0.67, blue: 0.33, alpha: 1)),
        dynamic(UIColor(red: 0.55, green: 0.36, blue: 0.8, alpha: 1), UIColor(red: 0.72, green: 0.56, blue: 0.98, alpha: 1)),
        dynamic(UIColor(red: 0.82, green: 0.3, blue: 0.4, alpha: 1), UIColor(red: 0.98, green: 0.5, blue: 0.58, alpha: 1)),
        dynamic(UIColor(red: 0.15, green: 0.58, blue: 0.64, alpha: 1), UIColor(red: 0.35, green: 0.78, blue: 0.82, alpha: 1)),
    ]
}

/// The hours, ruled, named in the margin; now a red line, today.
private final class ScheduleGrid: UIView {
    var day: Day = .today

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        let twelve = TimeStamp.localeIsTwelveHour
        let font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let now = day == .today ? ScheduleController.nowMinutes : nil
        let hairline = 1 / max(traitCollection.displayScale, 1)
        for hour in 0...24 {
            let y = ScheduleController.y(hour * 60)
            Ink.rule.setFill()
            UIRectFill(CGRect(x: ScheduleController.gutter, y: y, width: bounds.width - ScheduleController.gutter, height: hairline))
            guard hour > 0, hour < 24, now.map({ abs($0 - hour * 60) > 12 }) ?? true else { continue }
            let name = twelve ? "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")" : String(format: "%02d:00", hour)
            let label = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: Ink.faint])
            let size = label.size()
            label.draw(at: CGPoint(x: ScheduleController.gutter - 8 - size.width, y: y - size.height / 2))
        }
    }
}

/// Today, now: a red line across the hours, over the blocks, the time in the margin.
private final class NowLine: UIView {
    var day: Day = .today

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard day == .today else { return }
        let now = ScheduleController.nowMinutes
        let twelve = TimeStamp.localeIsTwelveHour
        let y = ScheduleController.y(now)
        UIColor.systemRed.setFill()
        UIRectFill(CGRect(x: ScheduleController.gutter, y: y - 0.75, width: bounds.width - ScheduleController.gutter, height: 1.5))
        UIBezierPath(ovalIn: CGRect(x: ScheduleController.gutter - 4, y: y - 4, width: 8, height: 8)).fill()
        let label = NSAttributedString(string: TimeStamp.shown(now, twelveHour: twelve).replacingOccurrences(of: " ", with: "\u{2009}"),
                                       attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: UIColor.systemRed])
        let size = label.size()
        label.draw(at: CGPoint(x: ScheduleController.gutter - 8 - size.width, y: y - size.height / 2))
    }
}

/// A block, drawn: its colour, a bar at its left, what it says, its times
/// and how long, its checklist as there is room — each box ticked where it is.
private final class BlockView: UIView {
    let block: DayBlock
    var onToggle: ((Int, Row.Task?) -> Void)?
    private var shownTimes: (Int, Int)?
    /// Boxes drawn, where a tap ticks them.
    private var boxes: [(rect: CGRect, row: Int, task: Row.Task?)] = []

    var lifted = false {
        didSet {
            layer.shadowOpacity = lifted ? 0.25 : 0
            transform = lifted ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
        }
    }

    init(block: DayBlock) {
        self.block = block
        super.init(frame: .zero)
        backgroundColor = .clear
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        isAccessibilityElement = true
        accessibilityLabel = InlineMarkup.plainText(block.title) + ", " + Self.times(block.start, block.end)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func times(_ start: Int, _ end: Int) -> String {
        let twelve = TimeStamp.localeIsTwelveHour
        return TimeStamp.shown(start, twelveHour: twelve) + " – " + TimeStamp.shown(end, twelveHour: twelve)
    }

    /// While dragged: the times it would have.
    func showTimes(start: Int, end: Int) {
        shownTimes = (start, end)
        setNeedsDisplay()
    }

    /// A tap on a box: ticked, or not. Whether it was on one.
    func toggle(at point: CGPoint) -> Bool {
        guard let box = boxes.first(where: { $0.rect.insetBy(dx: -8, dy: -8).contains(point) }) else { return false }
        UISelectionFeedbackGenerator().selectionChanged()
        onToggle?(box.row, box.task)
        return true
    }

    override func draw(_ rect: CGRect) {
        boxes = []
        let color = ScheduleController.color(for: block)
        let done = block.task?.isDone == true
        let shape = UIBezierPath(roundedRect: bounds, cornerRadius: 8)
        Ink.paper.setFill()
        shape.fill()
        color.withAlphaComponent(done ? 0.1 : 0.18).setFill()
        shape.fill()
        shape.addClip()
        color.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 4, height: bounds.height))
        let (start, end) = shownTimes ?? (block.start, block.end)
        let titleFont = Typeface.current.heading(14, weight: .semibold)
        let small = Typeface.current.body(12)
        var x: CGFloat = 12, y: CGFloat = 5
        if let task = block.task {
            let box = CGRect(x: x, y: y + 2, width: 14, height: 14)
            drawBox(box, done: task.isDone, color: color)
            boxes.append((box, block.row, task.isDone ? .open : .done("x")))
            x += 20
        }
        let name = InlineMarkup.plainText(block.title)
        var attributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: name.isEmpty ? Ink.faint : done ? Ink.secondary : Ink.text]
        if done { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        let times = NSAttributedString(string: Self.times(start, end) + " · " + TimeStamp.length(end - start),
                                       attributes: [.font: small, .foregroundColor: Ink.secondary])
        if bounds.height < 40 {
            let line = NSMutableAttributedString(string: name.isEmpty ? "New Block" : name, attributes: attributes)
            line.append(NSAttributedString(string: "  " + TimeStamp.shown(start, twelveHour: TimeStamp.localeIsTwelveHour),
                                           attributes: [.font: small, .foregroundColor: Ink.secondary]))
            line.draw(with: CGRect(x: x, y: y, width: bounds.width - x - 8, height: 18), options: options, context: nil)
            return
        }
        NSAttributedString(string: name.isEmpty ? "New Block" : name, attributes: attributes)
            .draw(with: CGRect(x: x, y: y, width: bounds.width - x - 8, height: 19), options: options, context: nil)
        y += 20
        times.draw(with: CGRect(x: x, y: y, width: bounds.width - x - 8, height: 16), options: options, context: nil)
        y += 20
        x = 12
        for item in block.items {
            guard y + 16 < bounds.height - 2 else { break }
            var itemX = x
            if let task = item.task {
                let box = CGRect(x: itemX, y: y + 1, width: 13, height: 13)
                drawBox(box, done: task.isDone, color: color)
                boxes.append((box, item.row, task.isDone ? .open : .done("x")))
                itemX += 19
            } else {
                Ink.secondary.setFill()
                UIBezierPath(ovalIn: CGRect(x: itemX + 4, y: y + 6, width: 4, height: 4)).fill()
                itemX += 16
            }
            var itemAttributes: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: item.task?.isDone == true ? Ink.secondary : Ink.text]
            if item.task?.isDone == true { itemAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            NSAttributedString(string: InlineMarkup.plainText(item.text), attributes: itemAttributes)
                .draw(with: CGRect(x: itemX, y: y, width: bounds.width - itemX - 8, height: 16), options: options, context: nil)
            y += 19
        }
    }

    private func drawBox(_ box: CGRect, done: Bool, color: UIColor) {
        let path = UIBezierPath(roundedRect: box, cornerRadius: 3.5)
        if done {
            color.setFill()
            path.fill()
            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: box.minX + box.width * 0.24, y: box.midY))
            tick.addLine(to: CGPoint(x: box.minX + box.width * 0.43, y: box.maxY - box.height * 0.26))
            tick.addLine(to: CGPoint(x: box.maxX - box.width * 0.22, y: box.minY + box.height * 0.26))
            tick.lineWidth = 1.6
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            UIColor.white.setStroke()
            tick.stroke()
        } else {
            Ink.paper.withAlphaComponent(0.7).setFill()
            path.fill()
            color.setStroke()
            path.lineWidth = 1.3
            path.stroke()
        }
    }
}

// MARK: - A block's editor

/// A block, to change: what it is for, its times, whether it is a task,
/// its checklist — each item ticked, changed, or emptied away — one added;
/// moved a day either way, or deleted.
final class BlockEditorController: UITableViewController, UITextFieldDelegate {
    private(set) var block: DayBlock
    let day: Day
    var onTitle: ((String) -> Void)?
    var onTimes: ((Int, Int) -> Void)?
    var onTask: ((Row.Task?) -> Void)?
    var onItemTask: ((Int, Row.Task?) -> Void)?
    var onItemText: ((Int, String) -> Void)?
    var onAddItem: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onMoveDay: ((Int) -> Void)?

    private let titleField = UITextField()
    private let adding = UITextField()
    private let startPicker = UIDatePicker()
    private let endPicker = UIDatePicker()

    init(block: DayBlock, day: Day) {
        self.block = block
        self.day = day
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = PlaceNames.dayTitle(day)
        tableView.backgroundColor = Ink.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.commitTitle()
            self?.dismiss(animated: true)
        })
        titleField.placeholder = "What it is for"
        titleField.font = Typeface.current.heading(18, weight: .semibold)
        titleField.text = block.title
        titleField.returnKeyType = .done
        titleField.delegate = self
        adding.placeholder = "Add a checklist item"
        adding.font = Typeface.current.body(16)
        adding.returnKeyType = .done
        adding.delegate = self
        for picker in [startPicker, endPicker] {
            picker.datePickerMode = .time
            picker.preferredDatePickerStyle = .compact
            picker.minuteInterval = 5
            picker.addAction(UIAction { [weak self] _ in self?.timesChanged() }, for: .valueChanged)
        }
        setPickers()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    func focusTitle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.titleField.becomeFirstResponder() }
    }

    func update(_ block: DayBlock) {
        self.block = block
        tableView.reloadData()
    }

    private func date(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private func minutes(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func setPickers() {
        startPicker.date = date(block.start)
        endPicker.date = date(block.end)
    }

    private func timesChanged() {
        let start = minutes(startPicker.date)
        var end = minutes(endPicker.date)
        if end <= start { end = min(start + block.duration, ScheduleController.lastMinute + 15) }
        guard (start, end) != (block.start, block.end) else { return }
        commitTitle()
        onTimes?(start, end)
    }

    private func commitTitle() {
        let text = (titleField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != block.title else { return }
        block.title = text
        onTitle?(text)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === titleField {
            commitTitle()
            textField.resignFirstResponder()
        } else if textField === adding {
            let text = (adding.text ?? "").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                adding.text = ""
                onAddItem?(text)
            }
        } else {
            textField.resignFirstResponder()
        }
        return false
    }

    /// An item's words, written once it is left: emptied, it goes.
    func textFieldDidEndEditing(_ textField: UITextField) {
        if textField === titleField { return commitTitle() }
        guard textField !== adding, let item = block.items.first(where: { $0.row == textField.tag }) else { return }
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != item.text else { return }
        onItemText?(item.row, text)
    }

    // MARK: Rows

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: 2
        case 1: 2
        case 2: block.items.count + 1
        default: 3
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 2 ? "Checklist" : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = Ink.paper
        cell.selectionStyle = .none
        func embed(_ view: UIView, inset: CGFloat = 16) {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: inset),
                view.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                view.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                view.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                view.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            ])
        }
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            embed(titleField)
        case (0, 1):
            var content = cell.defaultContentConfiguration()
            content.text = "A task, to tick off"
            content.textProperties.font = Typeface.current.body(16)
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = block.task != nil
            toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.onTask?(toggle?.isOn == true ? .open : nil) }, for: .valueChanged)
            cell.accessoryView = toggle
        case (1, let row):
            var content = cell.defaultContentConfiguration()
            content.text = row == 0 ? "Starts" : "Ends"
            content.textProperties.font = Typeface.current.body(16)
            cell.contentConfiguration = content
            let picker = row == 0 ? startPicker : endPicker
            picker.sizeToFit()
            cell.accessoryView = picker
        case (2, let row) where row < block.items.count:
            let item = block.items[row]
            let stack = UIStackView()
            stack.spacing = 10
            stack.alignment = .center
            let box = UIButton(type: .system)
            box.setImage(UIImage(systemName: item.task?.isDone == true ? "checkmark.square.fill" : item.task == nil ? "circle.fill" : "square"),
                         for: .normal)
            box.tintColor = item.task == nil ? Ink.faint : Ink.text
            box.isEnabled = item.task != nil
            box.addAction(UIAction { [weak self] _ in self?.onItemTask?(item.row, item.task?.isDone == true ? .open : .done("x")) }, for: .touchUpInside)
            box.setContentHuggingPriority(.required, for: .horizontal)
            let field = UITextField()
            field.text = item.text
            field.font = Typeface.current.body(16)
            field.tag = item.row
            field.returnKeyType = .done
            field.delegate = self
            stack.addArrangedSubview(box)
            stack.addArrangedSubview(field)
            embed(stack)
        case (2, _):
            embed(adding)
        case (3, 0), (3, 1):
            var content = cell.defaultContentConfiguration()
            content.text = indexPath.row == 0 ? "Move to the Day Before" : "Move to the Day After"
            content.image = UIImage(systemName: indexPath.row == 0 ? "chevron.left" : "chevron.right")
            content.textProperties.color = Ink.text
            content.imageProperties.tintColor = Ink.secondary
            cell.contentConfiguration = content
            cell.selectionStyle = .default
        default:
            var content = cell.defaultContentConfiguration()
            content.text = "Delete Block"
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 3 else { return }
        switch indexPath.row {
        case 0: onMoveDay?(-1)
        case 1: onMoveDay?(1)
        default: onDelete?()
        }
    }
}

// MARK: - A task to put on the day

/// The tasks still to do, in their groups: one chosen, put on the day.
final class TaskPickerController: UITableViewController {
    private let groups: [TaskGroup]
    var onChoose: ((NoteTask) -> Void)?

    init(groups: [TaskGroup]) {
        self.groups = groups.filter { !$0.tasks.isEmpty }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Put a Task on the Day"
        tableView.backgroundColor = Ink.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    override func numberOfSections(in tableView: UITableView) -> Int { max(1, groups.count) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        groups.isEmpty ? 1 : groups[section].tasks.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        groups.isEmpty ? nil : groups[section].label
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Ink.paper
        var content = UIListContentConfiguration.subtitleCell()
        if groups.isEmpty {
            content.text = "Nothing to do"
            content.textProperties.color = Ink.secondary
            cell.selectionStyle = .none
        } else {
            let task = groups[indexPath.section].tasks[indexPath.row]
            content.text = InlineMarkup.plainText(task.text)
            content.secondaryText = task.day.map(NoteBlock.dayTitle) ?? task.noteTitle
            content.image = UIImage(systemName: "circle")
            content.imageProperties.tintColor = Ink.secondary
            content.textProperties.font = Typeface.current.body(16)
            content.secondaryTextProperties.color = Ink.secondary
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !groups.isEmpty else { return }
        onChoose?(groups[indexPath.section].tasks[indexPath.row])
    }
}

extension PlaceNames {
    static func dayTitle(_ day: Day) -> String { NoteBlock.dayTitle(day) }
}
